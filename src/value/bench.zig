//! 自定义基础类型基准测试入口（S7 整数）
//!
//! 对比自定义 Int 运算 vs Zig 原生运算的性能差距。
//! zig build bench-value 运行。

const std = @import("std");
const value_mod = @import("mod.zig");
const Int = value_mod.Int;
const Float = value_mod.Float;

const Iterations = 1_000_000;
const DivIterations = 100_000;

fn benchNativeI64Add(io: std.Io) i96 {
    var acc: i64 = 0;
    var i: i64 = 0;
    const start = std.Io.Clock.awake.now(io);
    while (i < Iterations) : (i += 1) {
        acc +%= i;
    }
    const end = std.Io.Clock.awake.now(io);
    std.mem.doNotOptimizeAway(acc);
    return start.durationTo(end).nanoseconds;
}

fn benchCustomI64Add(io: std.Io) i96 {
    var acc = Int.fromNative(.i64, @as(i64, 0));
    var i: i64 = 0;
    const start = std.Io.Clock.awake.now(io);
    while (i < Iterations) : (i += 1) {
        const r = acc.add(Int.fromNative(.i64, @as(i64, i)));
        acc = r.result;
    }
    const end = std.Io.Clock.awake.now(io);
    std.mem.doNotOptimizeAway(acc);
    return start.durationTo(end).nanoseconds;
}

fn benchNativeI64Mul(io: std.Io) i96 {
    var acc: i64 = 1;
    var i: i64 = 1;
    const start = std.Io.Clock.awake.now(io);
    while (i < Iterations) : (i += 1) {
        acc *%= i;
    }
    const end = std.Io.Clock.awake.now(io);
    std.mem.doNotOptimizeAway(acc);
    return start.durationTo(end).nanoseconds;
}

fn benchCustomI64Mul(io: std.Io) i96 {
    var acc = Int.fromNative(.i64, @as(i64, 1));
    var i: i64 = 1;
    const start = std.Io.Clock.awake.now(io);
    while (i < Iterations) : (i += 1) {
        const r = acc.multiply(Int.fromNative(.i64, @as(i64, i)));
        acc = r.result;
    }
    const end = std.Io.Clock.awake.now(io);
    std.mem.doNotOptimizeAway(acc);
    return start.durationTo(end).nanoseconds;
}

fn benchNativeI64Div(io: std.Io) i96 {
    var acc: i64 = 0;
    var i: i64 = 1;
    const start = std.Io.Clock.awake.now(io);
    while (i < DivIterations) : (i += 1) {
        acc = @divTrunc(@as(i64, 1 << 60), i);
    }
    const end = std.Io.Clock.awake.now(io);
    std.mem.doNotOptimizeAway(acc);
    return start.durationTo(end).nanoseconds;
}

fn benchCustomI64Div(io: std.Io) i96 {
    var acc = Int.fromNative(.i64, @as(i64, 0));
    var i: i64 = 1;
    const numerator = Int.fromNative(.i64, @as(i64, 1 << 60));
    const start = std.Io.Clock.awake.now(io);
    while (i < DivIterations) : (i += 1) {
        acc = numerator.divideTruncating(Int.fromNative(.i64, @as(i64, i))) catch unreachable;
    }
    const end = std.Io.Clock.awake.now(io);
    std.mem.doNotOptimizeAway(acc);
    return start.durationTo(end).nanoseconds;
}

fn benchNativeI128Add(io: std.Io) i96 {
    var acc: i128 = 0;
    var i: i128 = 0;
    const start = std.Io.Clock.awake.now(io);
    while (i < Iterations) : (i += 1) {
        acc +%= i;
    }
    const end = std.Io.Clock.awake.now(io);
    std.mem.doNotOptimizeAway(acc);
    return start.durationTo(end).nanoseconds;
}

fn benchCustomI128Add(io: std.Io) i96 {
    var acc = Int.fromNative(.i128, @as(i128, 0));
    var i: i128 = 0;
    const start = std.Io.Clock.awake.now(io);
    while (i < Iterations) : (i += 1) {
        const r = acc.add(Int.fromNative(.i128, @as(i128, i)));
        acc = r.result;
    }
    const end = std.Io.Clock.awake.now(io);
    std.mem.doNotOptimizeAway(acc);
    return start.durationTo(end).nanoseconds;
}

fn benchNativeI128Mul(io: std.Io) i96 {
    var acc: i128 = 1;
    var i: i128 = 1;
    const start = std.Io.Clock.awake.now(io);
    while (i < Iterations) : (i += 1) {
        acc *%= i;
    }
    const end = std.Io.Clock.awake.now(io);
    std.mem.doNotOptimizeAway(acc);
    return start.durationTo(end).nanoseconds;
}

fn benchCustomI128Mul(io: std.Io) i96 {
    var acc = Int.fromNative(.i128, @as(i128, 1));
    var i: i128 = 1;
    const start = std.Io.Clock.awake.now(io);
    while (i < Iterations) : (i += 1) {
        const r = acc.multiply(Int.fromNative(.i128, @as(i128, i)));
        acc = r.result;
    }
    const end = std.Io.Clock.awake.now(io);
    std.mem.doNotOptimizeAway(acc);
    return start.durationTo(end).nanoseconds;
}

fn benchNativeI128Div(io: std.Io) i96 {
    var acc: i128 = 0;
    var i: i128 = 1;
    const start = std.Io.Clock.awake.now(io);
    while (i < DivIterations) : (i += 1) {
        acc = @divTrunc(@as(i128, 1 << 120), i);
    }
    const end = std.Io.Clock.awake.now(io);
    std.mem.doNotOptimizeAway(acc);
    return start.durationTo(end).nanoseconds;
}

fn benchCustomI128Div(io: std.Io) i96 {
    var acc = Int.fromNative(.i128, @as(i128, 0));
    var i: i128 = 1;
    const numerator = Int.fromNative(.i128, @as(i128, 1 << 120));
    const start = std.Io.Clock.awake.now(io);
    while (i < DivIterations) : (i += 1) {
        acc = numerator.divideTruncating(Int.fromNative(.i128, @as(i128, i))) catch unreachable;
    }
    const end = std.Io.Clock.awake.now(io);
    std.mem.doNotOptimizeAway(acc);
    return start.durationTo(end).nanoseconds;
}

// —— 浮点基准（S13）——

fn benchNativeF32Add(io: std.Io) i96 {
    var acc: f32 = 0.0;
    var i: u32 = 0;
    const start = std.Io.Clock.awake.now(io);
    while (i < Iterations) : (i += 1) {
        acc += @as(f32, @floatFromInt(i));
    }
    const end = std.Io.Clock.awake.now(io);
    std.mem.doNotOptimizeAway(acc);
    return start.durationTo(end).nanoseconds;
}

fn benchCustomF32Add(io: std.Io) i96 {
    var acc = Float.fromNative(.f32, @as(f32, 0.0));
    var i: u32 = 0;
    const start = std.Io.Clock.awake.now(io);
    while (i < Iterations) : (i += 1) {
        acc = acc.add(Float.fromNative(.f32, @as(f32, @floatFromInt(i))));
    }
    const end = std.Io.Clock.awake.now(io);
    std.mem.doNotOptimizeAway(acc);
    return start.durationTo(end).nanoseconds;
}

fn benchNativeF32Mul(io: std.Io) i96 {
    var acc: f32 = 1.0;
    var i: u32 = 1;
    const start = std.Io.Clock.awake.now(io);
    while (i < Iterations) : (i += 1) {
        acc *= @as(f32, @floatFromInt(i));
    }
    const end = std.Io.Clock.awake.now(io);
    std.mem.doNotOptimizeAway(acc);
    return start.durationTo(end).nanoseconds;
}

fn benchCustomF32Mul(io: std.Io) i96 {
    var acc = Float.fromNative(.f32, @as(f32, 1.0));
    var i: u32 = 1;
    const start = std.Io.Clock.awake.now(io);
    while (i < Iterations) : (i += 1) {
        acc = acc.multiply(Float.fromNative(.f32, @as(f32, @floatFromInt(i))));
    }
    const end = std.Io.Clock.awake.now(io);
    std.mem.doNotOptimizeAway(acc);
    return start.durationTo(end).nanoseconds;
}

fn benchNativeF32Div(io: std.Io) i96 {
    var acc: f32 = 0.0;
    var i: u32 = 1;
    const start = std.Io.Clock.awake.now(io);
    while (i < DivIterations) : (i += 1) {
        acc = 1e30 / @as(f32, @floatFromInt(i));
    }
    const end = std.Io.Clock.awake.now(io);
    std.mem.doNotOptimizeAway(acc);
    return start.durationTo(end).nanoseconds;
}

fn benchCustomF32Div(io: std.Io) i96 {
    var acc = Float.fromNative(.f32, @as(f32, 0.0));
    var i: u32 = 1;
    const numerator = Float.fromNative(.f32, @as(f32, 1e30));
    const start = std.Io.Clock.awake.now(io);
    while (i < DivIterations) : (i += 1) {
        acc = numerator.divide(Float.fromNative(.f32, @as(f32, @floatFromInt(i))));
    }
    const end = std.Io.Clock.awake.now(io);
    std.mem.doNotOptimizeAway(acc);
    return start.durationTo(end).nanoseconds;
}

fn benchNativeF64Add(io: std.Io) i96 {
    var acc: f64 = 0.0;
    var i: u32 = 0;
    const start = std.Io.Clock.awake.now(io);
    while (i < Iterations) : (i += 1) {
        acc += @as(f64, @floatFromInt(i));
    }
    const end = std.Io.Clock.awake.now(io);
    std.mem.doNotOptimizeAway(acc);
    return start.durationTo(end).nanoseconds;
}

fn benchCustomF64Add(io: std.Io) i96 {
    var acc = Float.fromNative(.f64, @as(f64, 0.0));
    var i: u32 = 0;
    const start = std.Io.Clock.awake.now(io);
    while (i < Iterations) : (i += 1) {
        acc = acc.add(Float.fromNative(.f64, @as(f64, @floatFromInt(i))));
    }
    const end = std.Io.Clock.awake.now(io);
    std.mem.doNotOptimizeAway(acc);
    return start.durationTo(end).nanoseconds;
}

fn benchNativeF64Mul(io: std.Io) i96 {
    var acc: f64 = 1.0;
    var i: u32 = 1;
    const start = std.Io.Clock.awake.now(io);
    while (i < Iterations) : (i += 1) {
        acc *= @as(f64, @floatFromInt(i));
    }
    const end = std.Io.Clock.awake.now(io);
    std.mem.doNotOptimizeAway(acc);
    return start.durationTo(end).nanoseconds;
}

fn benchCustomF64Mul(io: std.Io) i96 {
    var acc = Float.fromNative(.f64, @as(f64, 1.0));
    var i: u32 = 1;
    const start = std.Io.Clock.awake.now(io);
    while (i < Iterations) : (i += 1) {
        acc = acc.multiply(Float.fromNative(.f64, @as(f64, @floatFromInt(i))));
    }
    const end = std.Io.Clock.awake.now(io);
    std.mem.doNotOptimizeAway(acc);
    return start.durationTo(end).nanoseconds;
}

fn benchNativeF64Div(io: std.Io) i96 {
    var acc: f64 = 0.0;
    var i: u32 = 1;
    const start = std.Io.Clock.awake.now(io);
    while (i < DivIterations) : (i += 1) {
        acc = 1e300 / @as(f64, @floatFromInt(i));
    }
    const end = std.Io.Clock.awake.now(io);
    std.mem.doNotOptimizeAway(acc);
    return start.durationTo(end).nanoseconds;
}

fn benchCustomF64Div(io: std.Io) i96 {
    var acc = Float.fromNative(.f64, @as(f64, 0.0));
    var i: u32 = 1;
    const numerator = Float.fromNative(.f64, @as(f64, 1e300));
    const start = std.Io.Clock.awake.now(io);
    while (i < DivIterations) : (i += 1) {
        acc = numerator.divide(Float.fromNative(.f64, @as(f64, @floatFromInt(i))));
    }
    const end = std.Io.Clock.awake.now(io);
    std.mem.doNotOptimizeAway(acc);
    return start.durationTo(end).nanoseconds;
}

fn printResult(w: anytype, label: []const u8, total_ns: i96, iterations: u64) !void {
    const ns_per_op: f64 = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(iterations));
    const ops_per_sec: f64 = 1_000_000_000.0 / ns_per_op;
    try w.interface.print("{s:<30} {d:>10.2} ns/op   {d:>10.2} M ops/s\n", .{ label, ns_per_op, ops_per_sec / 1_000_000.0 });
    w.flush() catch {};
}

fn slowdown(custom: i96, native: i96) f64 {
    return @as(f64, @floatFromInt(custom)) / @as(f64, @floatFromInt(native));
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &buf);

    try w.interface.print("=== Custom Int vs Native Int Benchmark ===\n", .{});
    try w.interface.print("Iterations: add/mul = {d}, div = {d}\n\n", .{ Iterations, DivIterations });
    w.flush() catch {};

    // i64 add
    const n_add_i64 = benchNativeI64Add(io);
    const c_add_i64 = benchCustomI64Add(io);
    try printResult(&w, "i64 add (native)", n_add_i64, Iterations);
    try printResult(&w, "i64 add (custom)", c_add_i64, Iterations);
    try w.interface.print("  slowdown: {d:.2}x\n\n", .{slowdown(c_add_i64, n_add_i64)});
    w.flush() catch {};

    // i64 mul
    const n_mul_i64 = benchNativeI64Mul(io);
    const c_mul_i64 = benchCustomI64Mul(io);
    try printResult(&w, "i64 mul (native)", n_mul_i64, Iterations);
    try printResult(&w, "i64 mul (custom)", c_mul_i64, Iterations);
    try w.interface.print("  slowdown: {d:.2}x\n\n", .{slowdown(c_mul_i64, n_mul_i64)});
    w.flush() catch {};

    // i64 div
    const n_div_i64 = benchNativeI64Div(io);
    const c_div_i64 = benchCustomI64Div(io);
    try printResult(&w, "i64 div (native)", n_div_i64, DivIterations);
    try printResult(&w, "i64 div (custom)", c_div_i64, DivIterations);
    try w.interface.print("  slowdown: {d:.2}x\n\n", .{slowdown(c_div_i64, n_div_i64)});
    w.flush() catch {};

    // i128 add
    const n_add_i128 = benchNativeI128Add(io);
    const c_add_i128 = benchCustomI128Add(io);
    try printResult(&w, "i128 add (native)", n_add_i128, Iterations);
    try printResult(&w, "i128 add (custom)", c_add_i128, Iterations);
    try w.interface.print("  slowdown: {d:.2}x\n\n", .{slowdown(c_add_i128, n_add_i128)});
    w.flush() catch {};

    // i128 mul
    const n_mul_i128 = benchNativeI128Mul(io);
    const c_mul_i128 = benchCustomI128Mul(io);
    try printResult(&w, "i128 mul (native)", n_mul_i128, Iterations);
    try printResult(&w, "i128 mul (custom)", c_mul_i128, Iterations);
    try w.interface.print("  slowdown: {d:.2}x\n\n", .{slowdown(c_mul_i128, n_mul_i128)});
    w.flush() catch {};

    // i128 div
    const n_div_i128 = benchNativeI128Div(io);
    const c_div_i128 = benchCustomI128Div(io);
    try printResult(&w, "i128 div (native)", n_div_i128, DivIterations);
    try printResult(&w, "i128 div (custom)", c_div_i128, DivIterations);
    try w.interface.print("  slowdown: {d:.2}x\n\n", .{slowdown(c_div_i128, n_div_i128)});
    w.flush() catch {};

    try w.interface.print("=== Custom Float vs Native Float Benchmark ===\n", .{});
    w.flush() catch {};

    // f32 add
    const n_add_f32 = benchNativeF32Add(io);
    const c_add_f32 = benchCustomF32Add(io);
    try printResult(&w, "f32 add (native)", n_add_f32, Iterations);
    try printResult(&w, "f32 add (custom)", c_add_f32, Iterations);
    try w.interface.print("  slowdown: {d:.2}x\n\n", .{slowdown(c_add_f32, n_add_f32)});
    w.flush() catch {};

    // f32 mul
    const n_mul_f32 = benchNativeF32Mul(io);
    const c_mul_f32 = benchCustomF32Mul(io);
    try printResult(&w, "f32 mul (native)", n_mul_f32, Iterations);
    try printResult(&w, "f32 mul (custom)", c_mul_f32, Iterations);
    try w.interface.print("  slowdown: {d:.2}x\n\n", .{slowdown(c_mul_f32, n_mul_f32)});
    w.flush() catch {};

    // f32 div
    const n_div_f32 = benchNativeF32Div(io);
    const c_div_f32 = benchCustomF32Div(io);
    try printResult(&w, "f32 div (native)", n_div_f32, DivIterations);
    try printResult(&w, "f32 div (custom)", c_div_f32, DivIterations);
    try w.interface.print("  slowdown: {d:.2}x\n\n", .{slowdown(c_div_f32, n_div_f32)});
    w.flush() catch {};

    // f64 add
    const n_add_f64 = benchNativeF64Add(io);
    const c_add_f64 = benchCustomF64Add(io);
    try printResult(&w, "f64 add (native)", n_add_f64, Iterations);
    try printResult(&w, "f64 add (custom)", c_add_f64, Iterations);
    try w.interface.print("  slowdown: {d:.2}x\n\n", .{slowdown(c_add_f64, n_add_f64)});
    w.flush() catch {};

    // f64 mul
    const n_mul_f64 = benchNativeF64Mul(io);
    const c_mul_f64 = benchCustomF64Mul(io);
    try printResult(&w, "f64 mul (native)", n_mul_f64, Iterations);
    try printResult(&w, "f64 mul (custom)", c_mul_f64, Iterations);
    try w.interface.print("  slowdown: {d:.2}x\n\n", .{slowdown(c_mul_f64, n_mul_f64)});
    w.flush() catch {};

    // f64 div
    const n_div_f64 = benchNativeF64Div(io);
    const c_div_f64 = benchCustomF64Div(io);
    try printResult(&w, "f64 div (native)", n_div_f64, DivIterations);
    try printResult(&w, "f64 div (custom)", c_div_f64, DivIterations);
    try w.interface.print("  slowdown: {d:.2}x\n\n", .{slowdown(c_div_f64, n_div_f64)});
    w.flush() catch {};

    try w.interface.print("=== Done ===\n", .{});
    w.flush() catch {};
}
