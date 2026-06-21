//! VM bench 驱动：编译并在字节码 VM 上端到端跑基准（含 main + println）。
//! 用途：拿 VM vs 树遍历器的真实提速数字（docs/bytecode-vm-plan.md 门禁值）。
//! 注：M1/M2 VM 不跑 type_check，故内嵌的源用类型后缀锁定 i64（与树遍历器等价工作量）。
//! 计时由外层 shell（time / hyperfine）负责；本程序只负责跑通并打印结果。
//! argv[1] 选基准："lookup"（默认，410780000）或 "record"（666666666666000000）。

const std = @import("std");
const compiler = @import("compiler"); // root = src/vm/compiler.zig（再导出 VM/lexer/parser）

/// lookup 基准（类型后缀版）：与 bench/lookup/src/Main.glue 同构，字面量加 i64 后缀。
const LOOKUP_SRC =
    \\fun compute(seed: i64): i64 {
    \\    val a: i64 = seed + 1i64
    \\    val b: i64 = seed + 2i64
    \\    val c: i64 = seed + 3i64
    \\    val d: i64 = seed + 4i64
    \\    var acc: i64 = 0i64
    \\    var i: i64 = 0i64
    \\    while i < 1000i64 {
    \\        val t: i64 = (a + b + c + d + i) % 1024i64
    \\        acc = (acc + t) % 1048576i64
    \\        i = i + 1i64
    \\    }
    \\    acc
    \\}
    \\fun main() {
    \\    var total: i64 = 0i64
    \\    var k: i64 = 0i64
    \\    while k < 5000i64 {
    \\        total = (total + compute(k)) % 1073741824i64
    \\        k = k + 1i64
    \\    }
    \\    println(total)
    \\}
;

/// record 基准（类型后缀版）：与 bench/record/src/Main.glue 同构（M2a：ADT 构造/字段/match）。
const RECORD_SRC =
    \\type Point = Point(x: i64, y: i64)
    \\fun dist2(p: Point): i64 {
    \\    match p {
    \\        Point(x, y) => x * x + y * y
    \\    }
    \\}
    \\fun main() {
    \\    var sum: i64 = 0i64
    \\    var i: i64 = 0i64
    \\    while i < 1000000i64 {
    \\        val p = Point(i, i + 1i64)
    \\        sum = sum + dist2(p) + p.x - p.y
    \\        i = i + 1i64
    \\    }
    \\    println(sum)
    \\}
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // argv[1] 选基准（默认 lookup）。
    const argv = try std.process.Args.toSlice(init.minimal.args, init.arena.allocator());
    const which: []const u8 = if (argv.len >= 2) argv[1] else "lookup";
    const src = if (std.mem.eql(u8, which, "record")) RECORD_SRC else LOOKUP_SRC;

    // 编译：源 → tokens → module → Program。
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var lex = compiler.lexer.Lexer.init(aa, src);
    const toks = try lex.tokenize();
    var p = compiler.parser.Parser.init(aa, toks);
    var module = try p.parseModule("bench");

    var mc = compiler.ModuleCompiler.init(allocator);
    defer mc.deinit();
    defer mc.program.deinit();
    try mc.compileModule(&module);

    const entry = mc.lookupFn("main") orelse return error.NoMain;

    // 执行 main（arity 0）：末尾 println 结果。
    var vm = compiler.VM.initWithIo(allocator, io);
    defer vm.deinit();
    const result = try vm.call(&mc.program, entry, &.{});
    result.release(allocator);
}
