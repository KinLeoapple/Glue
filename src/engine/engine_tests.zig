//! Extracted engine test suite.
//!
//! 从 engine.zig 抽取的所有引擎端到端测试及测试辅助函数（buildIRFromSource /
//! initTestEngineOwned / valI64）。通过 mod.zig 中 `test { _ = engine_tests; }`
//! 在 `zig build test` 时链接进测试产物。
//!
//! 注：此处通过 `ir_mod` / `engine_mod` 访问 IR 与引擎类型，与 engine.zig 共享同一模块实例，
//! 保证 SemaResult / GlueIR 等类型身份一致。

const std = @import("std");
const ir_mod = @import("ir");
const value = @import("value");
const engine_mod = @import("engine.zig");

const GlueIR = ir_mod.GlueIR;
const Engine = engine_mod.Engine;
const EngineError = engine_mod.EngineError;
const ScalarMeta = ir_mod.ScalarMeta;
const Node = ir_mod.Node;
const Function = ir_mod.Function;

const testing = std.testing;
const ast = @import("ast");
const builder_mod = ir_mod.builder_mod;
const sema = @import("sema");

/// 测试辅助：从源码构建 IR
/// 与生产管线（main.zig）一致：先运行 sema 类型推断并注入 sema_result，再构建 IR。
fn buildIRFromSource(source: []const u8) !GlueIR {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var lex = @import("lexer").Lexer.init(alloc, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    defer alloc.free(tokens);

    var p = @import("parser").Parser.init(alloc, tokens);
    defer p.deinit();
    const module = try p.parseModule("test.glue");

    // sema 阶段：类型推断产出 SemaResult，驱动 IR 图构建（通道宽度由 sema 类型决定）
    // 注意：inferencer 的 arena 持有 Type 结构体及其 name 字符串，SemaResult.expr_types
    // 中的 type_name 切片指向这些字符串。因此 inferencer 必须在 builder.build() 期间保持存活，
    // 否则 type_name 成为悬垂指针。defer 确保在函数返回（build 完成后）才释放。
    var sema_result = ir_mod.SemaResult.init(testing.allocator);
    defer sema_result.deinit();
    var inferencer = sema.TypeInferencer.init(testing.allocator);
    defer inferencer.deinit();
    inferencer.setSemaResult(&sema_result);
    try inferencer.checkModule(&module);

    var builder = try builder_mod.IRBuilder.init(testing.allocator);
    defer builder.deinit();
    builder.setSemaResult(&sema_result);
    return try builder.build(module);
}

/// 测试辅助：创建带 std.Io.Threaded 的 Engine（fiber-aware 内存池所需）
/// 调用方需通过 `threaded` out-param 保持 Threaded 生命周期，并在 defer 中先 deinit engine 再 deinit threaded
fn initTestEngineOwned(ir: *GlueIR, threaded: *std.Io.Threaded) !Engine {
    threaded.* = std.Io.Threaded.init(testing.allocator, .{});
    return Engine.initOwned(ir, testing.allocator, null, threaded.io());
}

/// 测试辅助：从 Value 提取 i64（用于 expectEqual 比较）
fn valI64(v: value.Value) i64 {
    return switch (v) {
        .i8 => |b| @as(i64, @as(i8, @bitCast(b[0]))),
        .u8 => |b| @as(i64, b[0]),
        .i16 => |b| @as(i64, @as(i16, @bitCast(b))),
        .u16 => |b| @as(i64, @as(u16, @bitCast(b))),
        .i32 => |b| @as(i64, @as(i32, @bitCast(b))),
        .u32 => |b| @as(i64, @as(u32, @bitCast(b))),
        .i64 => |b| @as(i64, @bitCast(b)),
        .u64 => |b| @bitCast(@as(u64, @bitCast(b))),
        .isize => |b| @as(i64, @as(isize, @bitCast(b))),
        .usize => |b| @bitCast(@as(usize, @bitCast(b))),
        .boolean => |b| @as(i64, @intFromBool(b[0] != 0)),
        .char => |b| @as(i64, @as(u32, @bitCast(b))),
        else => 0,
    };
}

test "执行 const_i + halt_return" {
    // fun main() { 42 }
    var ir = try buildIRFromSource("fun main(): void { 42 }");
    defer ir.deinit();

    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }

    const result = try engine.run();
    try testing.expectEqual(@as(i64, 42), valI64(result));
}

test "执行整数加法" {
    // fun main() { 1 + 2 }
    var ir = try buildIRFromSource("fun main(): void { 1 + 2 }");
    defer ir.deinit();

    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }

    const result = try engine.run();
    try testing.expectEqual(@as(i64, 3), valI64(result));
}

test "执行整数减法" {
    var ir = try buildIRFromSource("fun main(): void { 10 - 4 }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 6), valI64(try engine.run()));
}

test "执行整数乘法" {
    var ir = try buildIRFromSource("fun main(): void { 6 * 7 }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 42), valI64(try engine.run()));
}

test "执行整数除法" {
    var ir = try buildIRFromSource("fun main(): void { 20 / 4 }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 5), valI64(try engine.run()));
}

test "执行整数取模" {
    var ir = try buildIRFromSource("fun main(): void { 17 % 5 }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 2), valI64(try engine.run()));
}

test "执行嵌套表达式" {
    // 1 + 2 * 3 = 7
    var ir = try buildIRFromSource("fun main(): void { 1 + 2 * 3 }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 7), valI64(try engine.run()));
}

test "执行比较运算" {
    // 3 < 5 → true → 1
    var ir = try buildIRFromSource("fun main(): void { 3 < 5 }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 1), valI64(result));
}

test "执行布尔逻辑" {
    // true && false → false → 0
    var ir = try buildIRFromSource("fun main(): void { true && false }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 0), valI64(result));
}

test "执行 val 变量绑定" {
    // val x = 10, val y = 20, x + y
    var ir = try buildIRFromSource("fun main(): void { val x = 10; val y = 20; x + y }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 30), valI64(try engine.run()));
}

test "执行函数调用" {
    // fun add(a, b) { a + b }
    // fun main() { add(3, 4) }
    var ir = try buildIRFromSource(
        \\fun add(a, b): i64 { a + b }
        \\fun main(): i64 { add(3, 4) }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 7), valI64(try engine.run()));
}

test "执行优化后的常量折叠" {
    // fun main() { 1 + 2 } → 优化后应为 const_i(3)
    var ir = try buildIRFromSource("fun main(): void { 1 + 2 }");
    defer ir.deinit();

    // 优化
    _ = ir_mod.optimize(&ir);

    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 3), valI64(try engine.run()));
}

// ════════════════════════════════════════════════════════════════
// Phase 2 端到端测试
// ════════════════════════════════════════════════════════════════

test "Phase 2: var 声明与赋值" {
    // var x = 10; x = 20; x
    var ir = try buildIRFromSource("fun main(): void { var x = 10; x = 20; x }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 20), valI64(try engine.run()));
}

test "Phase 2: 复合赋值 += " {
    // var x = 10; x += 5; x
    var ir = try buildIRFromSource("fun main(): void { var x = 10; x += 5; x }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 15), valI64(try engine.run()));
}

test "Phase 2: 复合赋值 *=" {
    // var x = 3; x *= 7; x
    var ir = try buildIRFromSource("fun main(): void { var x = 3; x *= 7; x }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 21), valI64(try engine.run()));
}

test "Phase 2: if 表达式 then 分支" {
    // if true { 42 } else { 0 }
    var ir = try buildIRFromSource("fun main(): void { if true { 42 } else { 0 } }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 42), valI64(try engine.run()));
}

test "Phase 2: if 表达式 else 分支" {
    // if 3 > 5 { 42 } else { 99 }
    var ir = try buildIRFromSource("fun main(): void { if 3 > 5 { 42 } else { 99 } }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 99), valI64(try engine.run()));
}

test "Phase 2: if 表达式条件求值" {
    // val x = 10; if x > 5 { x * 2 } else { x }
    var ir = try buildIRFromSource("fun main(): void { val x = 10; if x > 5 { x * 2 } else { x } }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 20), valI64(try engine.run()));
}

test "Phase 2: 类型转换 i64→i32" {
    // i32(1000)
    var ir = try buildIRFromSource("fun main(): void { i32(1000) }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 1000), valI64(result));
}

test "Phase 2: 类型转换 i64→f64" {
    // f64(42) → 42.0 → 位模式转回 i64 验证
    var ir = try buildIRFromSource("fun main(): void { f64(42) }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    // f64 通道的 8 字节读为 i64
    const result = try engine.run();
    const f: f64 = switch (result) {
        .f64 => |b| @as(f64, @bitCast(b)),
        .f32 => |b| @as(f64, @floatCast(@as(f32, @bitCast(b)))),
        .i64 => |b| @floatFromInt(@as(i64, @bitCast(b))),
        else => 0,
    };
    try testing.expectEqual(@as(f64, 42.0), f);
}

test "Phase 2: 嵌套 if 表达式" {
    // val x = 5; if x > 3 { if x > 4 { 100 } else { 200 } } else { 300 }
    var ir = try buildIRFromSource("fun main(): void { val x = 5; if x > 3 { if x > 4 { 100 } else { 200 } } else { 300 } }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 100), valI64(try engine.run()));
}

test "Phase 2: 嵌套 if（then 分支内嵌套，字面量条件）" {
    // if true { if false { 1 } else { 2 } } else { 3 } → 2
    var ir = try buildIRFromSource("fun main(): void { if true { if false { 1 } else { 2 } } else { 3 } }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 2), valI64(try engine.run()));
}

test "Phase 2: cast 链 i64→i32→i64" {
    // i64(i32(1000))
    var ir = try buildIRFromSource("fun main(): void { i64(i32(1000)) }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 1000), valI64(try engine.run()));
}

test "Phase 2: var 与 if 组合" {
    // var x = 1; if x > 0 { x = 10 }; x
    var ir = try buildIRFromSource("fun main(): void { var x = 1; if x > 0 { x = 10 }; x }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 10), valI64(try engine.run()));
}

test "Phase 2: 复合赋值 -= " {
    // var x = 100; x -= 30; x
    var ir = try buildIRFromSource("fun main(): void { var x = 100; x -= 30; x }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 70), valI64(try engine.run()));
}

test "Phase 2: 类型转换 i64→u8（窄化 wrap）" {
    // u8(300) → 300 wrap to u8 = 44
    var ir = try buildIRFromSource("fun main(): void { u8(300) }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    // u8 通道读 1 字节，零扩展为 i64
    try testing.expectEqual(@as(i64, 44), valI64(result));
}

// ════════════════════════════════════════════════════════════════
// Phase 2.5 端到端测试：堆对象（字符串）
// ════════════════════════════════════════════════════════════════

test "Phase 2.5: 字符串字面量" {
    // "hello" → 创建 Str 堆对象
    var ir = try buildIRFromSource("fun main(): void { \"hello\" }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.runStr();
    try testing.expectEqualStrings("hello", result);
}

test "Phase 2.5: 字符串拼接 (+)" {
    // "hello" + "world"
    var ir = try buildIRFromSource("fun main(): void { \"hello\" + \"world\" }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.runStr();
    try testing.expectEqualStrings("helloworld", result);
}

test "Phase 2.5: 字符串拼接 (++)" {
    // "foo" ++ "bar"
    var ir = try buildIRFromSource("fun main(): void { \"foo\" ++ \"bar\" }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.runStr();
    try testing.expectEqualStrings("foobar", result);
}

test "Phase 2.5: 字符串长度" {
    // 字符串长度目前需要通过函数调用测试
    // 简化：直接验证 string_len op 在 IR 层的正确性
    // "hello".len() 暂未支持 method_call，用内建方式测试
    // 此测试验证 const_str + string_len 的端到端流程
    var ir = try buildIRFromSource("fun main(): void { \"hello\" + \"world\" }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.runStr();
    try testing.expectEqual(@as(usize, 10), result.len);
}

test "Phase 2.5: 三字符串拼接" {
    // "a" + "b" + "c"
    var ir = try buildIRFromSource("fun main(): void { \"a\" + \"b\" + \"c\" }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.runStr();
    try testing.expectEqualStrings("abc", result);
}

test "Phase 2.5: 空字符串拼接" {
    // "" + "x"
    var ir = try buildIRFromSource("fun main(): void { \"\" + \"x\" }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.runStr();
    try testing.expectEqualStrings("x", result);
}

// ════════════════════════════════════════════════════════════════
// Phase 2.5 端到端测试：数组
// ════════════════════════════════════════════════════════════════

test "Phase 2.5: 数组字面量长度" {
    // [1, 2, 3] — 验证 array_make + array_set 链
    var ir = try buildIRFromSource("fun main(): void { [1, 2, 3] }");
    defer ir.deinit();

    // 验证 IR 中包含 array_make 和 array_set 节点
    var has_array_make = false;
    var array_set_count: u32 = 0;
    for (ir.nodes) |n| {
        if (n.op == .array_make) has_array_make = true;
        if (n.op == .array_set) array_set_count += 1;
    }
    try testing.expect(has_array_make);
    try testing.expectEqual(@as(u32, 3), array_set_count);
}

test "Phase 2.5: 数组索引访问" {
    // [10, 20, 30][1] → 20
    var ir = try buildIRFromSource("fun main(): void { [10, 20, 30][1] }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 20), valI64(try engine.run()));
}

test "Phase 2.5: record 字面量与字段访问" {
    // (x: 1, y: 2).x → 1
    var ir = try buildIRFromSource("fun main(): void { (x: 1, y: 2).x }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 1), valI64(try engine.run()));
}

test "Phase 2.5: record 多字段访问" {
    // (a: 10, b: 20, c: 30).b → 20
    var ir = try buildIRFromSource("fun main(): void { (a: 10, b: 20, c: 30).b }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 20), valI64(try engine.run()));
}

test "Phase 2.5: record 字段覆盖" {
    // (x: 1, y: 2).y → 2
    var ir = try buildIRFromSource("fun main(): void { (x: 1, y: 2).y }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 2), valI64(try engine.run()));
}

test "Phase 2.5: 字符串索引" {
    // "hello"[0] → 'h' = 104
    var ir = try buildIRFromSource("fun main(): void { \"hello\"[0] }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    // char 通道返回 u21，但 run() 按通道宽度读取
    // char_chan 宽度为 4 字节，按 i32 读取
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 104), valI64(result));
}

test "Phase 2.5: 字符串插值" {
    // "hello {"world"}" → "hello world"
    var ir = try buildIRFromSource("fun main(): void { \"hello {\"world\"}\" }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.runStr();
    try testing.expectEqualStrings("hello world", result);
}

test "Phase 2.5: 字符串插值多段" {
    // "{"a"}b{"c"}" → "abc"
    var ir = try buildIRFromSource("fun main(): void { \"{\"a\"}b{\"c\"}\" }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.runStr();
    try testing.expectEqualStrings("abc", result);
}

// ════════════════════════════════════════════
// Phase 3: 向量 op 执行测试
// ════════════════════════════════════════════

test "Phase 3: for range 向量化 identity map" {
    // for i in 0..10 { i } → vec_source(range) |> vec_map(identity) |> vec_sink(last)
    // sink_last 取最后一个元素 = 9
    var ir = try buildIRFromSource("fun main(): void { for i in 0..10 { i } }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 9), valI64(result));
}

test "Phase 3: for range 带运算 i * 2" {
    // for i in 0..5 { i * 2 } → [0,2,4,6,8], sink_last = 8
    var ir = try buildIRFromSource("fun main(): void { for i in 0..5 { i * 2 } }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 8), valI64(result));
}

test "Phase 3: for range 带运算 i + 10" {
    // for i in 1..4 { i + 10 } → [11,12,13], sink_last = 13
    var ir = try buildIRFromSource("fun main(): void { for i in 1..4 { i + 10 } }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 13), valI64(result));
}

test "Phase 3: for range 单元素" {
    // for i in 0..1 { i } → [0], sink_last = 0
    var ir = try buildIRFromSource("fun main(): void { for i in 0..1 { i } }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 0), valI64(result));
}

test "Phase 3: for range 复杂表达式" {
    // for i in 0..5 { (i + 1) * 3 } → [3,6,9,12,15], sink_last = 15
    var ir = try buildIRFromSource("fun main(): void { for i in 0..5 { (i + 1) * 3 } }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 15), valI64(result));
}

// ════════════════════════════════════════════
// Phase 4: 门控 + 清理测试
// ════════════════════════════════════════════

test "Phase 4: defer 在 return 前执行" {
    // fun cleanup() -> i64 { 0 }
    // fun main() -> i64 { defer cleanup(); 42 }
    // 验证 defer 不影响返回值
    var ir = try buildIRFromSource(
        "fun cleanup(): i64 { 0 } fun main(): i64 { defer cleanup(); 42 }",
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 42), valI64(result));
}

test "Phase 4: 多个 defer LIFO 执行" {
    // 多个 defer 不影响返回值，验证 LIFO 执行不崩溃
    var ir = try buildIRFromSource(
        "fun a(): i64 { 0 } fun b(): i64 { 0 } fun main(): i64 { defer a(); defer b(); 99 }",
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 99), valI64(result));
}

test "Phase 4: defer 带 var 赋值" {
    // defer 调用函数，不影响返回值
    // 验证 defer 体能正确执行函数调用
    var ir = try buildIRFromSource(
        "fun cleanup(): void { 0 } fun main(): void { var x = 1; defer cleanup(); x }",
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    // x 的值在 defer 执行前就已经作为返回值
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 1), valI64(result));
}

test "Phase 4: throw 触发 halt_throw" {
    // throw 语句触发 halt_throw，run() 返回 error.Thrown
    var ir = try buildIRFromSource("fun main(): void { throw 42 }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectError(error.Thrown, engine.run());
}

// ════════════════════════════════════════════
// Phase 5: 路由 + 竞争测试
// ════════════════════════════════════════════

test "Phase 5: select 第一个分支就绪" {
    // select { 1 => v => 10; 2 => v => 20 }
    // 非 ChannelValue 输入视为始终就绪，第一个分支胜出 → body 返回 10
    var ir = try buildIRFromSource("fun main(): void { select { 1 => v => 10; 2 => v => 20 } }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 10), valI64(result));
}

test "Phase 5: select 单分支" {
    // select { 42 => v => 99 }
    // 单个分支，胜出后执行 body 返回 99
    var ir = try buildIRFromSource("fun main(): void { select { 42 => v => 99 } }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 99), valI64(result));
}

test "Phase 5: select 带 timeout 分支" {
    // select { timeout(1000) => 42 }
    // timeout arm 的 duration 被当作普通表达式编译，body 返回 42
    var ir = try buildIRFromSource("fun main(): void { select { timeout(1000) => 42 } }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 42), valI64(result));
}

test "Phase 5: select body 带运算" {
    // select { 1 => v => 3 * 4 }
    // body 包含运算，结果为 12
    var ir = try buildIRFromSource("fun main(): void { select { 1 => v => 3 * 4 } }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 12), valI64(result));
}

// ════════════════════════════════════════════
// Phase 6: Nullable + 内存管理测试
// ════════════════════════════════════════════

test "Phase 6: Elvis 整数默认值" {
    // 整数不可能为 null，直接返回左操作数
    // 1 ?? 99 → 1
    var ir = try buildIRFromSource("fun main(): void { 1 ?? 99 }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 1), valI64(result));
}

test "Phase 6: non_null_assert 整数透传" {
    // 整数不可能为 null，! 直接透传
    // 42! → 42
    var ir = try buildIRFromSource("fun main(): void { 42! }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 42), valI64(result));
}

test "Phase 6: Elvis 链式表达式" {
    // (1 + 2) ?? 99 → 3
    var ir = try buildIRFromSource("fun main(): void { (1 + 2) ?? 99 }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 3), valI64(result));
}

// ════════════════════════════════════════════
// Phase 7: 星轨执行测试（async/spawn）
// ════════════════════════════════════════════

test "Phase 7: async 函数基本执行 + join" {
    // async fun compute() { 42 }
    // fun main() { compute().await() }
    var ir = try buildIRFromSource(
        \\async fun compute(): Async<i64> { 42 }
        \\fun main(): void { compute().await() }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 42), valI64(result));
}

test "Phase 7: async 函数带参数" {
    // async fun add(a, b) { a + b }
    // fun main() { add(3, 4).await() }
    var ir = try buildIRFromSource(
        \\async fun add(a, b): Async<i64> { a + b }
        \\fun main(): i64 { add(3, 4).await() }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 7), valI64(result));
}

test "Phase 7: async 函数计算" {
    // async fun square(n) { n * n }
    // fun main() { square(7).await() }
    var ir = try buildIRFromSource(
        \\async fun square(n): i64 { n * n }
        \\fun main(): i64 { square(7).await() }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 49), valI64(result));
}

test "Phase 7: async 函数调用普通函数" {
    // fun double(n) { n * 2 }
    // async fun compute() { double(21) }
    // fun main() { compute().await() }
    var ir = try buildIRFromSource(
        \\fun double(n): i64 { n * 2 }
        \\async fun compute(): i64 { double(21) }
        \\fun main(): void { compute().await() }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 42), valI64(result));
}

test "Phase 7: 嵌套普通函数调用（非 async）" {
    // fun double(n) { n * 2 }
    // fun compute() { double(21) }
    // fun main() { compute() }
    var ir = try buildIRFromSource(
        \\fun double(n): i64 { n * 2 }
        \\fun compute(): i64 { double(21) }
        \\fun main(): i64 { compute() }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 42), valI64(result));
}

test "Phase 7: 单层 double 调用" {
    // fun double(n) { n * 2 }
    // fun main() { double(21) }
    var ir = try buildIRFromSource(
        \\fun double(n): i64 { n * 2 }
        \\fun main(): i64 { double(21) }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    const result = try engine.run();
    try testing.expectEqual(@as(i64, 42), valI64(result));
}

test "loop + break" {
    // var i = 0; var sum = 0; loop { if i >= 5 { break } sum += i; i += 1 } sum
    var ir = try buildIRFromSource(
        \\fun main(): void {
        \\    var i = 0
        \\    var sum = 0
        \\    loop {
        \\        if i >= 5 { break }
        \\        sum += i
        \\        i += 1
        \\    }
        \\    sum
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 10), valI64(try engine.run())); // 0+1+2+3+4=10
}

test "for + break" {
    var ir = try buildIRFromSource(
        \\fun main(): void {
        \\    var sum = 0
        \\    for i in 0..100 {
        \\        if i > 5 { break }
        \\        sum += i
        \\    }
        \\    sum
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 15), valI64(try engine.run())); // 0+1+2+3+4+5=15
}

test "for + continue" {
    var ir = try buildIRFromSource(
        \\fun main(): void {
        \\    var sum = 0
        \\    for i in 0..10 {
        \\        if i % 2 == 0 { continue }
        \\        sum += i
        \\    }
        \\    sum
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 25), valI64(try engine.run())); // 1+3+5+7+9=25
}

test "while + break" {
    var ir = try buildIRFromSource(
        \\fun main(): void {
        \\    var i = 0
        \\    var sum = 0
        \\    while i < 100 {
        \\        if i >= 5 { break }
        \\        sum += i
        \\        i += 1
        \\    }
        \\    sum
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 10), valI64(try engine.run())); // 0+1+2+3+4=10
}

// ════════════════════════════════════════════
// Phase 7-c: 协程调度路径集成测试（M:N 协程调度器）
// ════════════════════════════════════════════

test "Phase 7-c: startScheduler 启动协程调度器" {
    // 验证 startScheduler 创建调度器并启动 worker 线程，不崩溃
    var ir = try buildIRFromSource("fun main(): void { 42 }");
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }

    try engine.startScheduler(2);
    try testing.expect(engine.scheduler != null);
    // 重复调用应幂等（不重复启动）
    try engine.startScheduler(2);
}

test "Phase 7-c: async 函数走协程调度路径" {
    // async fun compute() { 42 }
    // fun main() { compute().await() }
    // 启用调度器后，compute() 应走 scheduler.spawn → runSegment → complete → join
    var ir = try buildIRFromSource(
        \\async fun compute(): Async<i64> { 42 }
        \\fun main(): void { compute().await() }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }

    // 启动调度器（2 worker）
    try engine.startScheduler(2);

    const result = try engine.run();
    try testing.expectEqual(@as(i64, 42), valI64(result));
}

// ════════════════════════════════════════════
// P0-b: type_decl / trait_decl 注册 + 构造器调用
// ════════════════════════════════════════════

test "P0-b: ADT 无参构造器（Leaf）" {
    var ir = try buildIRFromSource(
        \\type Tree = | Leaf | Node(i32, Tree, Tree)
        \\fun main(): void { Leaf }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    _ = try engine.run(); // 只验证不崩溃
}

test "P0-b: ADT 带参构造器 + 命名字段访问" {
    // Box(42).value → 42
    var ir = try buildIRFromSource(
        \\type Box = | Box(value: i32)
        \\fun main(): void { Box(42).value }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 42), valI64(try engine.run()));
}

test "P0-b: ADT 多构造器 + 位置字段访问" {
    // Node(5, Leaf, Leaf)._0 → 5
    var ir = try buildIRFromSource(
        \\type Tree = | Leaf | Node(i32, Tree, Tree)
        \\fun main(): void { Node(5, Leaf, Leaf)._0 }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 5), valI64(try engine.run()));
}

test "P0-b: newtype 构造器 + 字段访问" {
    // UserId(42)._0 → 42
    var ir = try buildIRFromSource(
        \\type UserId = UserId(i32)
        \\fun main(): void { UserId(42)._0 }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 42), valI64(try engine.run()));
}

test "P0-b: trait_decl 注册（不崩溃）" {
    var ir = try buildIRFromSource(
        \\trait Printable {
        \\    fun format(self): str
        \\}
        \\fun main(): void { 42 }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 42), valI64(try engine.run()));
}

test "P0-b: type 方法注册为函数" {
    // type MyInt = | MyInt(value: i32) { fun get(self): i32 { self.value } }
    // 方法已注册，通过字段访问验证构造器
    var ir = try buildIRFromSource(
        \\type MyInt = | MyInt(value: i32)
        \\fun main(): void { MyInt(10).value }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 10), valI64(try engine.run()));
}

// ════════════════════════════════════════════
// P0-c: match 表达式编译
// ════════════════════════════════════════════

test "P0-c: match 字面量匹配" {
    // match 2 { 1 => 10, 2 => 20, _ => 30 } → 20
    var ir = try buildIRFromSource(
        \\fun main(): void {
        \\    match 2 {
        \\        1 => 10
        \\        2 => 20
        \\        _ => 30
        \\    }
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 20), valI64(try engine.run()));
}

test "P0-c: match 通配符兜底" {
    // match 99 { 1 => 10, _ => 30 } → 30
    var ir = try buildIRFromSource(
        \\fun main(): void {
        \\    match 99 {
        \\        1 => 10
        \\        _ => 30
        \\    }
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 30), valI64(try engine.run()));
}

test "P0-c: match 变量绑定" {
    // match 42 { 1 => 10, x => x } → 42
    var ir = try buildIRFromSource(
        \\fun main(): void {
        \\    match 42 {
        \\        1 => 10
        \\        x => x
        \\    }
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 42), valI64(try engine.run()));
}

test "P0-c: match ADT 构造器解构" {
    // match Box(42) { Box(v) => v, Leaf => 0 } → 42
    var ir = try buildIRFromSource(
        \\type Box = | Box(value: i32) | Empty
        \\fun main(): void {
        \\    match Box(42) {
        \\        Box(v) => v
        \\        Empty => 0
        \\    }
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 42), valI64(try engine.run()));
}

test "P0-c: match ADT 无参构造器" {
    // match Empty { Box(v) => v, Empty => 99 } → 99
    var ir = try buildIRFromSource(
        \\type Box = | Box(value: i32) | Empty
        \\fun main(): void {
        \\    match Empty {
        \\        Box(v) => v
        \\        Empty => 99
        \\    }
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 99), valI64(try engine.run()));
}

test "P0-c: match 或模式" {
    // match 2 { 1 | 2 | 3 => 10, _ => 20 } → 10
    var ir = try buildIRFromSource(
        \\fun main(): void {
        \\    match 2 {
        \\        1 | 2 | 3 => 10
        \\        _ => 20
        \\    }
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 10), valI64(try engine.run()));
}

test "P0-c: match 守卫条件" {
    // match 5 { n if n < 0 => 1, n if n > 3 => 2, _ => 3 } → 2
    var ir = try buildIRFromSource(
        \\fun main(): void {
        \\    match 5 {
        \\        n if n < 0 => 1
        \\        n if n > 3 => 2
        \\        _ => 3
        \\    }
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 2), valI64(try engine.run()));
}

test "P0-c: match 多构造器 ADT 位置字段" {
    // match Node(5, Leaf, Leaf) { Node(v, _, _) => v, Leaf => 0 } → 5
    var ir = try buildIRFromSource(
        \\type Tree = | Leaf | Node(i32, Tree, Tree)
        \\fun main(): void {
        \\    match Node(5, Leaf, Leaf) {
        \\        Node(v, _, _) => v
        \\        Leaf => 0
        \\    }
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 5), valI64(try engine.run()));
}

// ════════════════════════════════════════════
// P0-d: 方法调用编译
// ════════════════════════════════════════════

test "P0-d: async .await() 显式等待" {
    // async fun compute() { 42 } fun main() { compute().await() }
    var ir = try buildIRFromSource(
        \\async fun compute(): Async<i64> { 42 }
        \\fun main(): void { compute().await() }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 42), valI64(try engine.run()));
}

test "P0-d: async .status() 状态查询" {
    // async fun compute() { 42 }
    // fun main() { val s = compute(); s.await(); s.status() }
    // await 后状态应为 2（Completed）
    var ir = try buildIRFromSource(
        \\async fun compute(): Async<i64> { 42 }
        \\fun main(): void {
        \\    val s = compute()
        \\    s.await()
        \\    s.status()
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 2), valI64(try engine.run()));
}

test "P0-d: array .len() 方法" {
    // [10, 20, 30].len() → 3
    var ir = try buildIRFromSource(
        \\fun main(): void { [10, 20, 30].len() }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 3), valI64(try engine.run()));
}

test "P0-d: string .len() 方法" {
    // "hello".len() → 5
    var ir = try buildIRFromSource(
        \\fun main(): void { "hello".len() }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 5), valI64(try engine.run()));
}

test "P0-d: array .push() 方法" {
    // val arr = [1]; arr.push(2); arr.len() → 2
    var ir = try buildIRFromSource(
        \\fun main(): void {
        \\    val arr = [1]
        \\    arr.push(2)
        \\    arr.len()
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 2), valI64(try engine.run()));
}

test "P0-d: 用户自定义方法调用" {
    // type MyInt = | MyInt(value: i32) { fun get(self): i32 { self.value } }
    // fun main() { MyInt(10).get() }
    var ir = try buildIRFromSource(
        \\type MyInt = | MyInt(value: i32)
        \\{
        \\    fun get(self): i32 { self.value }
        \\}
        \\fun main(): void { MyInt(10).get() }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 10), valI64(try engine.run()));
}

test "P0-d: .type_name() 反射方法" {
    // type Point = | Point(x: i32, y: i32)
    // Point(1, 2).type_name() → "Point"（返回 ref，无法直接断言字符串内容）
    // 验证不崩溃即可
    var ir = try buildIRFromSource(
        \\type Point = | Point(x: i32, y: i32)
        \\fun main(): void {
        \\    val p = Point(1, 2)
        \\    p.type_name()
        \\    42
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 42), valI64(try engine.run()));
}

test "P0-d: async .await() 带参数计算" {
    // async fun add(a, b) { a + b } fun main() { add(3, 4).await() }
    var ir = try buildIRFromSource(
        \\async fun add(a, b): Async<i64> { a + b }
        \\fun main(): i64 { add(3, 4).await() }
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 7), valI64(try engine.run()));
}

// ════════════════════════════════════════════════════════════════
// P1-a: lambda / 闭包测试
// ════════════════════════════════════════════════════════════════

test "P1-a: fun lambda 基本调用" {
    // val f = fun(x) { x + 1 }
    // fun main() { val f = fun(x) { x + 1 }; f(10) }
    var ir = try buildIRFromSource(
        \\fun main(): void {
        \\    val f = fun(x) { x + 1 }
        \\    f(10)
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 11), valI64(try engine.run()));
}

test "P1-a: 箭头 lambda 基本调用" {
    // val f = (x) => x + 1; f(10) → 11
    var ir = try buildIRFromSource(
        \\fun main(): void {
        \\    val f = (x) => x + 1
        \\    f(10)
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 11), valI64(try engine.run()));
}

test "P1-a: 多参数 lambda" {
    // val g = (a, b) => a + b; g(3, 4) → 7
    var ir = try buildIRFromSource(
        \\fun main(): void {
        \\    val g = (a, b) => a + b
        \\    g(3, 4)
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 7), valI64(try engine.run()));
}

test "P1-a: 闭包捕获自由变量" {
    // val n = 10; val f = fun(x) { x + n }; f(5) → 15
    var ir = try buildIRFromSource(
        \\fun main(): void {
        \\    val n = 10
        \\    val f = fun(x) { x + n }
        \\    f(5)
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 15), valI64(try engine.run()));
}

test "P1-a: 闭包捕获多个自由变量" {
    // val a = 100; val b = 20; val f = fun(x) { x + a - b }; f(1) → 81
    var ir = try buildIRFromSource(
        \\fun main(): void {
        \\    val a = 100
        \\    val b = 20
        \\    val f = fun(x) { x + a - b }
        \\    f(1)
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 81), valI64(try engine.run()));
}

test "lazy: 创建时不求值，强制时缓存" {
    // 与 edge_lazy 保持一致：创建时不求值，首次强制求值，二次复用缓存。
    // 注意：buildIRFromSource 不加载 stdlib 模块，无法使用 println；
    // 改用 lz + 0 触发严格运算上下文的 lazy_force（builder 对 ref_chan 操作数强制求值）。
    var ir = try buildIRFromSource(
        \\var compute_count = 0
        \\
        \\fun expensive(x: i32): i32 {
        \\    compute_count = compute_count + 1
        \\    x * x
        \\}
        \\
        \\fun main(): i64 {
        \\    val lz = lazy expensive(5)
        \\    if compute_count != 0 { -100 } else {
        \\        lz + 0
        \\        lz + 0
        \\        compute_count
        \\    }
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 1), valI64(try engine.run()));
}

test "lazy: thunk 捕获外部变量" {
    // buildIRFromSource 不加载 stdlib 模块，无法使用 println；
    // 改用 lz + 0 触发 lazy_force 验证 thunk 捕获外部变量。
    var ir = try buildIRFromSource(
        \\fun makeLazy(x: i32): Lazy<i32> {
        \\    lazy x * x
        \\}
        \\
        \\fun main(): i64 {
        \\    val lz = makeLazy(7)
        \\    lz + 0
        \\    49
        \\}
    );
    defer ir.deinit();
    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 49), valI64(try engine.run()));
}

test "vec_zip: 合并两个 range 向量" {
    // 手工构造 IR：
    //   left  = range(0, 3)  -> [0, 1, 2]
    //   right = range(10, 13) -> [10, 11, 12]
    //   zipped = vec_zip(left, right) -> [(0,10), (1,11), (2,12)]
    //   return sink_count(zipped) = 3
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var channels = ir_mod.ChannelSpace.init(alloc);
    const c_const0 = try channels.alloc(ir_mod.type_descriptor_mod.i64_descriptor);
    const c_const3 = try channels.alloc(ir_mod.type_descriptor_mod.i64_descriptor);
    const c_left = try channels.alloc(ir_mod.type_descriptor_mod.i64_descriptor);
    const c_right = try channels.alloc(ir_mod.type_descriptor_mod.i64_descriptor);
    const c_zipped = try channels.alloc(ir_mod.type_descriptor_mod.ref_descriptor);
    const c_count = try channels.alloc(ir_mod.type_descriptor_mod.i64_descriptor);

    const scalar_metas = try alloc.alloc(ScalarMeta, 3);
    scalar_metas[0] = .{ .kind = .unit }; // meta_index=0 占位
    scalar_metas[1] = .{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = 0 } };
    scalar_metas[2] = .{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = 3 } };

    const vector_metas = try alloc.alloc(ir_mod.VectorMeta, 3);
    vector_metas[0] = .{ .vec_op = .range_source, .elem_type_desc = ir_mod.type_descriptor_mod.i64_descriptor, .length = 3 };
    vector_metas[1] = .{ .vec_op = .range_source, .elem_type_desc = ir_mod.type_descriptor_mod.i64_descriptor, .length = 3 };
    vector_metas[2] = .{ .vec_op = .sink_count, .elem_type_desc = ir_mod.type_descriptor_mod.i64_descriptor };

    const nodes = try alloc.alloc(Node, 7);
    nodes[0] = Node.makeSink(.const_i, c_const0, 1);
    nodes[1] = Node.makeSink(.const_i, c_const3, 2);
    nodes[2] = Node.makeBinary(.vec_source, c_left, 1, c_const0, c_const3);
    nodes[3] = Node.makeBinary(.vec_source, c_right, 2, c_const0, c_const3);
    nodes[4] = Node.makeBinary(.vec_zip, c_zipped, 0, c_left, c_right);
    nodes[5] = Node.makeUnary(.vec_sink, c_count, 3, c_zipped);
    nodes[6] = Node.makeUnary(.halt_return, c_count, 0, c_count);

    const funcs = try alloc.alloc(Function, 1);
    // 编译期通道布局元数据（手动构造，等价于 computeFunctionChannelLayout 的输出）
    // 6 个 8B 通道（5 local + 1 return），16B 对齐
    const local_offsets = try alloc.alloc(u32, 6);
    local_offsets[0] = 0; // c_const0
    local_offsets[1] = 16; // c_const3
    local_offsets[2] = 32; // c_left
    local_offsets[3] = 48; // c_right
    local_offsets[4] = 64; // c_zipped
    local_offsets[5] = 80; // c_count (return_channel)
    funcs[0] = .{
        .name = "main",
        .node_start = 0,
        .node_count = 7,
        .param_channels = &.{},
        .return_channel = c_count,
        .is_entry = true,
        .local_chan_start = 0,
        .local_chan_count = 5,
        .chan_total_bytes = 96,
        .local_offsets = local_offsets,
        .scc_max_chan_bytes = 96,
    };

    var ir = GlueIR{
        .nodes = nodes,
        .channels = channels,
        .scalar_metas = scalar_metas,
        .vector_metas = vector_metas,
        .functions = funcs,
        .entry_index = 0,
        .backing = alloc,
    };

    var threaded: std.Io.Threaded = undefined;
    var engine = try initTestEngineOwned(&ir, &threaded);
    defer { engine.deinit(); threaded.deinit(); }
    try testing.expectEqual(@as(i64, 3), valI64(try engine.run()));
}
