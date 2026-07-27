//! IRBuilder 端到端测试用例
//!
//! 从 builder.zig 物理拆分。使用 AstHelper 构造 AST，验证 IRBuilder.build() 产出的 GlueIR。
//! 覆盖 Phase 1（标量/控制流）、Phase 2（向量 op）、Phase 3（门控/路由/竞争/清理）、Phase 5（星轨扩展）。

const std = @import("std");
const ast = @import("ast");
const builder_mod = @import("builder.zig");
const op_table = @import("op_table.zig");
const AstHelper = @import("ast_helper.zig").AstHelper;

const testing = std.testing;
const IRBuilder = builder_mod.IRBuilder;
const NodeOp = builder_mod.NodeOp;
const ChanType = builder_mod.ChanType;
const FloatKind = builder_mod.FloatKind;
const GateKind = builder_mod.GateKind;
const HaltKind = builder_mod.HaltKind;
const VecOp = builder_mod.VecOp;

// ── 端到端测试用例 ──

test "e2e: 简单算术 fun main() -> i64 { 1 + 2 }" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() -> i64 { 1 + 2 }
    const body = ah.block(&.{}, ah.binary(.add, ah.intLit("1"), ah.intLit("2")));
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 验证：1 个函数、4 个节点（const_i, const_i, int_add, halt_return）
    try testing.expectEqual(@as(usize, 1), ir.functions.len);
    try testing.expectEqual(@as(usize, 4), ir.nodes.len);

    // 节点序列验证
    try testing.expectEqual(NodeOp.const_i, ir.nodes[0].op);
    try testing.expectEqual(NodeOp.const_i, ir.nodes[1].op);
    try testing.expectEqual(NodeOp.int_add, ir.nodes[2].op);
    try testing.expectEqual(NodeOp.halt_return, ir.nodes[3].op);

    // int_add 的输入应连接到两个 const_i 的输出
    try testing.expectEqual(ir.nodes[0].output, ir.nodes[2].inputs[0]);
    try testing.expectEqual(ir.nodes[1].output, ir.nodes[2].inputs[1]);

    // 常量值验证
    try testing.expectEqual(@as(i128, 1), ir.scalar_metas[1].const_val.?.int_val);
    try testing.expectEqual(@as(i128, 2), ir.scalar_metas[2].const_val.?.int_val);

    // 入口函数
    try testing.expectEqual(@as(u16, 0), ir.entry_index);
    try testing.expect(ir.functions[0].is_entry);
    try testing.expectEqualStrings("main", ir.functions[0].name);
}

test "e2e: 变量绑定与使用 fun main() -> i64 { val x = 10; x }" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() -> i64 { val x = 10; x }
    const stmts = [_]*ast.Stmt{
        ah.valDecl("x", ah.intLit("10")),
    };
    const body = ah.block(&stmts, ah.ident("x"));
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 节点序列：const_i(10), halt_return
    try testing.expectEqual(@as(usize, 2), ir.nodes.len);
    try testing.expectEqual(NodeOp.const_i, ir.nodes[0].op);
    try testing.expectEqual(NodeOp.halt_return, ir.nodes[1].op);

    // halt_return 的输入应指向 const_i 的输出（变量 x 绑定到 const_i 通道）
    try testing.expectEqual(ir.nodes[0].output, ir.nodes[1].inputs[0]);

    // 常量值
    try testing.expectEqual(@as(i128, 10), ir.scalar_metas[1].const_val.?.int_val);
}

test "e2e: if 表达式 fun main() -> i64 { if true { 1 } else { 2 } }" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() -> i64 { if true { 1 } else { 2 } }
    const body = ah.block(&.{}, ah.ifExpr(
        ah.boolLit(true),
        ah.intLit("1"),
        ah.intLit("2"),
    ));
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 节点序列：const_bool, cast, const_i(2)[else], const_i(1)[then], route_dispatch, halt_return
    try testing.expectEqual(@as(usize, 6), ir.nodes.len);
    try testing.expectEqual(NodeOp.const_bool, ir.nodes[0].op);
    try testing.expectEqual(NodeOp.cast, ir.nodes[1].op);
    try testing.expectEqual(NodeOp.const_i, ir.nodes[2].op); // else 分支
    try testing.expectEqual(NodeOp.const_i, ir.nodes[3].op); // then 分支
    try testing.expectEqual(NodeOp.route_dispatch, ir.nodes[4].op);
    try testing.expectEqual(NodeOp.halt_return, ir.nodes[5].op);

    // route_dispatch 输入：[winner_chan]
    try testing.expectEqual(ir.nodes[1].output, ir.nodes[4].inputs[0]); // winner
}

test "e2e: 函数定义与调用 add(1, 2)" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST:
    //   fun add(a: i64, b: i64) -> i64 { a + b }
    //   fun main() -> i64 { add(1, 2) }
    const add_body = ah.block(&.{}, ah.binary(.add, ah.ident("a"), ah.ident("b")));
    const add_params = [_]ast.Param{
        ah.param("a", "i64"),
        ah.param("b", "i64"),
    };
    const add_decl = ah.funDecl("add", &add_params, ah.namedType("i64"), add_body, false);

    const main_args = [_]*ast.Expr{ ah.intLit("1"), ah.intLit("2") };
    const main_body = ah.block(&.{}, ah.call("add", &main_args));
    const main_decl = ah.funDecl("main", &.{}, ah.namedType("i64"), main_body, true);

    const decls = [_]ast.Decl{ add_decl, main_decl };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 2 个函数
    try testing.expectEqual(@as(usize, 2), ir.functions.len);
    try testing.expectEqualStrings("add", ir.functions[0].name);
    try testing.expectEqualStrings("main", ir.functions[1].name);
    try testing.expect(ir.functions[1].is_entry);

    // add 函数节点：const_i(1)? 不——参数是 identifier
    // add 节点序列：int_add(a, b), halt_return
    const add_fn_nodes = ir.funcNodes(0);
    try testing.expectEqual(@as(usize, 2), add_fn_nodes.len);
    try testing.expectEqual(NodeOp.int_add, add_fn_nodes[0].op);
    try testing.expectEqual(NodeOp.halt_return, add_fn_nodes[1].op);

    // main 函数节点：const_i(1), const_i(2), call, halt_return
    const main_fn_nodes = ir.funcNodes(1);
    try testing.expectEqual(@as(usize, 4), main_fn_nodes.len);
    try testing.expectEqual(NodeOp.const_i, main_fn_nodes[0].op);
    try testing.expectEqual(NodeOp.const_i, main_fn_nodes[1].op);
    try testing.expectEqual(NodeOp.call, main_fn_nodes[2].op);
    try testing.expectEqual(NodeOp.halt_return, main_fn_nodes[3].op);

    // call 节点输入连接
    try testing.expectEqual(@as(u8, 2), main_fn_nodes[2].input_count);
    try testing.expectEqual(main_fn_nodes[0].output, main_fn_nodes[2].inputs[0]); // arg 1
    try testing.expectEqual(main_fn_nodes[1].output, main_fn_nodes[2].inputs[1]); // arg 2

    // call 元数据
    try testing.expectEqual(@as(u16, 0), ir.call_metas[0].func_index);
    try testing.expectEqual(@as(u8, 2), ir.call_metas[0].arg_count);
}

test "e2e: var 声明与赋值 fun main() -> i64 { var x = 1; x = 2; x }" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() -> i64 { var x = 1; x = 2; x }
    const stmts = [_]*ast.Stmt{
        ah.varDecl("x", ah.intLit("1")),
        ah.assignment("x", ah.intLit("2")),
    };
    const body = ah.block(&stmts, ah.ident("x"));
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 节点序列：const_i(1), load(x_cell), const_i(2), store(x_cell), halt_return
    try testing.expectEqual(@as(usize, 5), ir.nodes.len);
    try testing.expectEqual(NodeOp.const_i, ir.nodes[0].op);
    try testing.expectEqual(NodeOp.load, ir.nodes[1].op);
    try testing.expectEqual(NodeOp.const_i, ir.nodes[2].op);
    try testing.expectEqual(NodeOp.store, ir.nodes[3].op);
    try testing.expectEqual(NodeOp.halt_return, ir.nodes[4].op);

    // load 和 store 应指向同一个 cell 通道
    try testing.expectEqual(ir.nodes[1].output, ir.nodes[3].output);

    // var 声明的通道应标记为 cell
    const cell_chan = ir.nodes[1].output;
    try testing.expect(ir.channels.get(cell_chan).is_cell);
}

test "e2e: 类型推导（后缀 + 浮点）" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() -> f32 { 1.5f32 + 2.5f32 }
    const body = ah.block(&.{}, ah.binary(
        .add,
        ah.floatLitSuf("1.5", "f32"),
        ah.floatLitSuf("2.5", "f32"),
    ));
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("f32"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 节点序列：const_f, const_f, float_add, halt_return
    try testing.expectEqual(@as(usize, 4), ir.nodes.len);
    try testing.expectEqual(NodeOp.const_f, ir.nodes[0].op);
    try testing.expectEqual(NodeOp.const_f, ir.nodes[1].op);
    try testing.expectEqual(NodeOp.float_add, ir.nodes[2].op);
    try testing.expectEqual(NodeOp.halt_return, ir.nodes[3].op);

    // 通道类型应为 f32
    try testing.expectEqual(ChanType.f32_chan, ir.channels.get(ir.nodes[0].output).chan_type);
    try testing.expectEqual(ChanType.f32_chan, ir.channels.get(ir.nodes[2].output).chan_type);

    // 元数据中 float_kind 应为 f32
    try testing.expectEqual(FloatKind.f32, ir.scalar_metas[1].float_kind);
    try testing.expectEqual(FloatKind.f32, ir.scalar_metas[2].float_kind);
    try testing.expectEqual(FloatKind.f32, ir.scalar_metas[3].float_kind);
}

test "e2e: 比较运算与 bool 逻辑" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() -> bool { 1 < 2 }
    const body = ah.block(&.{}, ah.binary(.lt, ah.intLit("1"), ah.intLit("2")));
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("bool"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 节点序列：const_i, const_i, cmp_lt, halt_return
    try testing.expectEqual(@as(usize, 4), ir.nodes.len);
    try testing.expectEqual(NodeOp.cmp_lt, ir.nodes[2].op);

    // 比较结果类型应为 mask
    try testing.expectEqual(ChanType.mask_chan, ir.channels.get(ir.nodes[2].output).chan_type);
}

test "e2e: 一元运算 fun main() -> i64 { -5 }" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() -> i64 { -5 }
    const body = ah.block(&.{}, ah.unary(.neg, ah.intLit("5")));
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 节点序列：const_i(5), int_neg, halt_return
    try testing.expectEqual(@as(usize, 3), ir.nodes.len);
    try testing.expectEqual(NodeOp.const_i, ir.nodes[0].op);
    try testing.expectEqual(NodeOp.int_neg, ir.nodes[1].op);
    try testing.expectEqual(NodeOp.halt_return, ir.nodes[2].op);

    // neg 的输入应连接到 const_i 的输出
    try testing.expectEqual(ir.nodes[0].output, ir.nodes[1].inputs[0]);
}

test "e2e: IR printer 输出验证" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() -> i64 { 1 + 2 }
    const body = ah.block(&.{}, ah.binary(.add, ah.intLit("1"), ah.intLit("2")));
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 打印 IR
    const output = try @import("printer.zig").irToString(testing.allocator, &ir);
    defer testing.allocator.free(output);

    // 验证输出包含关键内容
    try testing.expect(std.mem.indexOf(u8, output, "Glue IR") != null);
    try testing.expect(std.mem.indexOf(u8, output, "const_i") != null);
    try testing.expect(std.mem.indexOf(u8, output, "int_add") != null);
    try testing.expect(std.mem.indexOf(u8, output, "halt_return") != null);
    try testing.expect(std.mem.indexOf(u8, output, "main") != null);
    try testing.expect(std.mem.indexOf(u8, output, "[entry]") != null);
}

// ════════════════════════════════════════════════════════════════
// Phase 2 端到端测试：向量 op
// ════════════════════════════════════════════════════════════════

test "e2e: for 循环 range 向量化 fun main() { for i in 0..10 { i } }" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: for i in 0..10 { i }
    const for_stmt = ah.stmt(.{ .for_stmt = .{
        .name = "i",
        .iterable = ah.binary(.range, ah.intLit("0"), ah.intLit("10")),
        .body = ah.ident("i"),
    } });
    const body = ah.block(&.{for_stmt}, null);
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 节点序列：const_i(0), const_i(10), vec_source, vec_map, vec_sink, halt_return
    try testing.expectEqual(@as(usize, 6), ir.nodes.len);
    try testing.expectEqual(NodeOp.const_i, ir.nodes[0].op);
    try testing.expectEqual(NodeOp.const_i, ir.nodes[1].op);
    try testing.expectEqual(NodeOp.vec_source, ir.nodes[2].op);
    try testing.expectEqual(NodeOp.vec_map, ir.nodes[3].op);
    try testing.expectEqual(NodeOp.vec_sink, ir.nodes[4].op);

    // vec_source 的输入是 start 和 end 通道
    try testing.expectEqual(@as(u8, 2), ir.nodes[2].input_count);
    try testing.expectEqual(ir.nodes[0].output, ir.nodes[2].inputs[0]); // start
    try testing.expectEqual(ir.nodes[1].output, ir.nodes[2].inputs[1]); // end

    // vec_map 的输入是 vec_source 的输出
    try testing.expectEqual(ir.nodes[2].output, ir.nodes[3].inputs[0]);

    // vec_sink 的输入是 vec_map 的输出
    try testing.expectEqual(ir.nodes[3].output, ir.nodes[4].inputs[0]);

    // 向量元数据验证（vec_source + vec_map + vec_sink = 3 个）
    try testing.expectEqual(@as(usize, 3), ir.vector_metas.len);

    // vmeta[0]: vec_source (range_source)
    try testing.expectEqual(VecOp.range_source, ir.vector_metas[0].vec_op);
    try testing.expectEqual(@as(?u32, 10), ir.vector_metas[0].length); // 编译期推导长度
    try testing.expectEqual(ChanType.i32_chan, ir.vector_metas[0].elem_type);

    // vmeta[2]: vec_sink (sink_last)
    try testing.expectEqual(VecOp.sink_last, ir.vector_metas[2].vec_op);
}

test "e2e: for 循环 inclusive range 向量化" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: for i in 0..=5 { i }
    const for_stmt = ah.stmt(.{ .for_stmt = .{
        .name = "i",
        .iterable = ah.binary(.range_inclusive, ah.intLit("0"), ah.intLit("5")),
        .body = ah.ident("i"),
    } });
    const body = ah.block(&.{for_stmt}, null);
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // range_inclusive 长度 = 5 - 0 + 1 = 6
    try testing.expectEqual(@as(?u32, 6), ir.vector_metas[0].length);
}

test "e2e: for 循环带循环体运算" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: for i in 0..100 { i * 2 }
    const for_stmt = ah.stmt(.{ .for_stmt = .{
        .name = "i",
        .iterable = ah.binary(.range, ah.intLit("0"), ah.intLit("100")),
        .body = ah.binary(.mul, ah.ident("i"), ah.intLit("2")),
    } });
    const body = ah.block(&.{for_stmt}, null);
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 节点序列：const_i(0), const_i(100), vec_source, const_i(2), int_mul, vec_map, vec_sink, halt_return
    // 循环体子图：const_i(2), int_mul — body_start/body_len 引用这段
    try testing.expectEqual(@as(usize, 8), ir.nodes.len);
    try testing.expectEqual(NodeOp.vec_source, ir.nodes[2].op);
    try testing.expectEqual(NodeOp.int_mul, ir.nodes[4].op);
    try testing.expectEqual(NodeOp.vec_map, ir.nodes[5].op);

    // vec_map 的 meta 应记录循环体子图范围（vmeta[1] 是 vec_map）
    const map_meta = ir.vector_metas[1];
    try testing.expect(map_meta.body_len > 0); // 循环体非空
    try testing.expectEqual(@as(?u32, 100), ir.vector_metas[0].length);
}

test "e2e: while 循环向量化" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: while true { 1 }
    const while_stmt = ah.stmt(.{ .while_stmt = .{
        .condition = ah.boolLit(true),
        .body = ah.intLit("1"),
    } });
    const body = ah.block(&.{while_stmt}, null);
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // while 编译为 scalar_loop（while_loop kind）
    const has_scalar_loop = blk: {
        for (ir.nodes) |n| if (n.op == .scalar_loop) break :blk true;
        break :blk false;
    };
    try testing.expect(has_scalar_loop);

    // 验证 scalar_loop 的 loop_meta 为 while_loop kind
    const has_while_loop_meta = blk: {
        for (ir.loop_metas) |lm| if (lm.loop_kind == .while_loop) break :blk true;
        break :blk false;
    };
    try testing.expect(has_while_loop_meta);
}

test "e2e: vec_fold 归约编译" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // 直接测试 compileFold 方法
    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();

    // 手动构造场景：src_vec_chan 和 init_chan
    const src_vec = try builder.allocChannel(.i64_chan);
    const init_chan = try builder.allocChannel(.i64_chan);

    const fold_out = try builder.compileFold(.int_add, init_chan, src_vec);

    // 验证最后一个节点是 vec_fold
    const last_node = builder.nodes.items[builder.nodes.items.len - 1];
    try testing.expectEqual(NodeOp.vec_fold, last_node.op);
    try testing.expectEqual(@as(u8, 2), last_node.input_count);
    try testing.expectEqual(src_vec, last_node.inputs[0]);
    try testing.expectEqual(init_chan, last_node.inputs[1]);
    try testing.expectEqual(fold_out, last_node.output);

    // 验证向量元数据
    const fold_meta = builder.vector_metas.items[0];
    try testing.expectEqual(NodeOp.int_add, fold_meta.inner_op);
    try testing.expectEqual(ChanType.i64_chan, fold_meta.elem_type);
}

test "e2e: vec_scan 前缀计算编译" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();

    const src_vec = try builder.allocChannel(.i64_chan);
    const init_chan = try builder.allocChannel(.i64_chan);

    const scan_out = try builder.compileScan(.int_add, init_chan, src_vec);

    // 验证最后一个节点是 vec_scan
    const last_node = builder.nodes.items[builder.nodes.items.len - 1];
    try testing.expectEqual(NodeOp.vec_scan, last_node.op);
    try testing.expectEqual(@as(u8, 2), last_node.input_count);
    try testing.expectEqual(src_vec, last_node.inputs[0]);
    try testing.expectEqual(init_chan, last_node.inputs[1]);
    try testing.expectEqual(scan_out, last_node.output);

    // 验证向量元数据
    const scan_meta = builder.vector_metas.items[0];
    try testing.expectEqual(NodeOp.int_add, scan_meta.inner_op);
}

test "e2e: for 循环 dispatch 降频验证" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: for i in 0..1000 { i * 2 + 1 }
    // 传统执行：1000 次 dispatch（mul + add + const）
    // 向量化：3 次 dispatch（vec_source + vec_map + vec_sink）
    const for_stmt = ah.stmt(.{ .for_stmt = .{
        .name = "i",
        .iterable = ah.binary(.range, ah.intLit("0"), ah.intLit("1000")),
        .body = ah.binary(.add, ah.binary(.mul, ah.ident("i"), ah.intLit("2")), ah.intLit("1")),
    } });
    const body = ah.block(&.{for_stmt}, null);
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 统计向量 op 数量
    var vec_op_count: usize = 0;
    for (ir.nodes) |n| {
        if (op_table.isVector(n.op)) vec_op_count += 1;
    }

    // 向量 op 只有 3 个：vec_source + vec_map + vec_sink
    // 循环体子图（const_i, const_i, int_mul, int_add）是内联的，不算独立 dispatch
    try testing.expectEqual(@as(usize, 3), vec_op_count);

    // 编译期已知长度 1000
    try testing.expectEqual(@as(?u32, 1000), ir.vector_metas[0].length);
}

test "e2e: 向量 meta printer 输出" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: for i in 0..10 { i }
    const for_stmt = ah.stmt(.{ .for_stmt = .{
        .name = "i",
        .iterable = ah.binary(.range, ah.intLit("0"), ah.intLit("10")),
        .body = ah.ident("i"),
    } });
    const body = ah.block(&.{for_stmt}, null);
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    const output = try @import("printer.zig").irToString(testing.allocator, &ir);
    defer testing.allocator.free(output);

    // 验证向量元数据打印输出
    try testing.expect(std.mem.indexOf(u8, output, "向量元数据") != null);
    try testing.expect(std.mem.indexOf(u8, output, "range_source") != null);
    try testing.expect(std.mem.indexOf(u8, output, "sink_last") != null);
    try testing.expect(std.mem.indexOf(u8, output, "length=10") != null);
    try testing.expect(std.mem.indexOf(u8, output, "vec_source") != null);
    try testing.expect(std.mem.indexOf(u8, output, "vec_map") != null);
    try testing.expect(std.mem.indexOf(u8, output, "vec_sink") != null);
}

// ════════════════════════════════════════════════════════════════
// Phase 3 端到端测试：门控/路由/竞争/清理
// ════════════════════════════════════════════════════════════════

test "e2e: ? 传播表达式编译为 gate 节点链" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun f() -> i64 { 0 } fun main() -> i64 { f()? }
    const f_body = ah.block(&.{}, ah.intLit("0"));
    const f_decl = ah.funDecl("f", &.{}, ah.namedType("i64"), f_body, false);
    const body = ah.block(&.{}, ah.expr(.{ .propagate = .{
        .expr = ah.call("f", &.{}),
    } }));
    const decls = [_]ast.Decl{
        f_decl,
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 节点序列：call(f), gate_check, gate_get_ok, const_unit, halt_return
    try testing.expect(ir.nodes.len >= 3);

    // 查找 gate_check 和 gate_get_ok 节点
    var has_gate_check = false;
    var has_gate_get_ok = false;
    for (ir.nodes) |n| {
        if (n.op == .gate_check) has_gate_check = true;
        if (n.op == .gate_get_ok) has_gate_get_ok = true;
    }
    try testing.expect(has_gate_check);
    try testing.expect(has_gate_get_ok);

    // 验证门控元数据
    try testing.expect(ir.gate_metas.len >= 2);
    try testing.expectEqual(GateKind.check, ir.gate_metas[0].gate_kind);
    try testing.expectEqual(GateKind.get_ok, ir.gate_metas[1].gate_kind);
}

test "e2e: defer 语句编译为 cleanup_register" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun cleanup() -> i64 { 0 } fun main() -> i64 { defer cleanup(); return 42 }
    const cleanup_body = ah.block(&.{}, ah.intLit("0"));
    const cleanup_decl = ah.funDecl("cleanup", &.{}, ah.namedType("i64"), cleanup_body, false);
    const defer_stmt = ah.stmt(.{ .defer_stmt = .{
        .expr = ah.call("cleanup", &.{}),
    } });
    const return_stmt = ah.returnStmt(ah.intLit("42"));
    const body = ah.block(&.{ defer_stmt, return_stmt }, null);
    const decls = [_]ast.Decl{
        cleanup_decl,
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 查找 cleanup_register 节点
    var has_cleanup = false;
    for (ir.nodes) |n| {
        if (n.op == .cleanup_register) has_cleanup = true;
    }
    try testing.expect(has_cleanup);

    // 验证清理元数据
    try testing.expect(ir.cleanup_metas.len >= 1);
    const cm = ir.cleanup_metas[0];
    try testing.expectEqual(HaltKind.any_halt, cm.trigger);
    try testing.expect(cm.body_len > 0); // defer 体非空
    try testing.expectEqual(@as(u32, 0), cm.order); // 第一个 defer
}

test "e2e: 多个 defer LIFO 顺序" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun a() -> i64 { 0 } fun b() -> i64 { 0 } fun main() -> i64 { defer a(); defer b(); return 0 }
    const a_decl = ah.funDecl("a", &.{}, ah.namedType("i64"), ah.block(&.{}, ah.intLit("0")), false);
    const b_decl = ah.funDecl("b", &.{}, ah.namedType("i64"), ah.block(&.{}, ah.intLit("0")), false);
    const defer_a = ah.stmt(.{ .defer_stmt = .{
        .expr = ah.call("a", &.{}),
    } });
    const defer_b = ah.stmt(.{ .defer_stmt = .{
        .expr = ah.call("b", &.{}),
    } });
    const return_stmt = ah.returnStmt(ah.intLit("0"));
    const body = ah.block(&.{ defer_a, defer_b, return_stmt }, null);
    const decls = [_]ast.Decl{
        a_decl,
        b_decl,
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 两个 cleanup_register 节点
    var cleanup_count: usize = 0;
    for (ir.nodes) |n| {
        if (n.op == .cleanup_register) cleanup_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), cleanup_count);

    // 验证 LIFO 顺序：order 递增
    try testing.expectEqual(@as(u32, 0), ir.cleanup_metas[0].order);
    try testing.expectEqual(@as(u32, 1), ir.cleanup_metas[1].order);
}

test "e2e: throw 语句编译为 halt_throw" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun main() -> i64 { throw 42 }
    // 简化：throw 一个整数字面量
    const throw_stmt = ah.stmt(.{ .throw_stmt = .{
        .location = .{ .line = 1, .column = 1 },
        .expr = ah.intLit("42"),
    } });
    const body = ah.block(&.{throw_stmt}, null);
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 查找 halt_throw 节点
    var has_throw = false;
    for (ir.nodes) |n| {
        if (n.op == .halt_throw) has_throw = true;
    }
    try testing.expect(has_throw);

    // 验证门控元数据（make_err）
    try testing.expect(ir.gate_metas.len >= 1);
    var has_make_err = false;
    for (ir.gate_metas) |gm| {
        if (gm.gate_kind == .make_err) has_make_err = true;
    }
    try testing.expect(has_make_err);
}

test "e2e: select 多路复用编译为竞争图" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: select { ch1.recv() => v => 0; ch2.recv() => v => 1 }
    // 简化：使用整数通道，body 返回整数
    const arm1 = ast.SelectArm{ .receive = .{
        .location = AstHelper.loc,
        .channel_expr = ah.intLit("1"), // 简化：用整数代替通道
        .binding = "v",
        .body = ah.intLit("0"),
    } };
    const arm2 = ast.SelectArm{ .receive = .{
        .location = AstHelper.loc,
        .channel_expr = ah.intLit("2"),
        .binding = "v",
        .body = ah.intLit("1"),
    } };

    const arms = ah.alloc().alloc(ast.SelectArm, 2) catch unreachable;
    arms[0] = arm1;
    arms[1] = arm2;

    const body = ah.block(&.{}, ah.expr(.{ .select = .{ .arms = arms } }));
    const decls = [_]ast.Decl{
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 查找竞争节点
    var race_select_count: usize = 0;
    var has_route_dispatch = false;
    for (ir.nodes) |n| {
        if (n.op == .race_select) race_select_count += 1;
        if (n.op == .route_dispatch) has_route_dispatch = true;
    }

    // 单个阻塞式 race_select（receive 通道直接作为输入，无需 race_source 前置节点）
    try testing.expectEqual(@as(usize, 1), race_select_count);
    try testing.expect(has_route_dispatch);

    // 验证竞争元数据
    try testing.expect(ir.race_metas.len >= 1); // 1 个 race_select
    try testing.expectEqual(@as(u8, 2), ir.race_metas[0].source_count);
    try testing.expect(ir.race_metas[0].timeout_arm == null);

    // 验证路由元数据
    try testing.expect(ir.route_metas.len >= 1);
    try testing.expectEqual(@as(u8, 2), ir.route_metas[0].target_count);
}

test "e2e: Phase 3 元数据 printer 输出" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: fun cleanup() -> i64 { 0 } fun main() -> i64 { defer cleanup(); return 42 }
    const cleanup_decl = ah.funDecl("cleanup", &.{}, ah.namedType("i64"), ah.block(&.{}, ah.intLit("0")), false);
    const defer_stmt = ah.stmt(.{ .defer_stmt = .{
        .expr = ah.call("cleanup", &.{}),
    } });
    const return_stmt = ah.returnStmt(ah.intLit("42"));
    const body = ah.block(&.{ defer_stmt, return_stmt }, null);
    const decls = [_]ast.Decl{
        cleanup_decl,
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    const output = try @import("printer.zig").irToString(testing.allocator, &ir);
    defer testing.allocator.free(output);

    // 验证 Phase 3 元数据打印
    try testing.expect(std.mem.indexOf(u8, output, "清理元数据") != null);
    try testing.expect(std.mem.indexOf(u8, output, "cleanup_register") != null);
    try testing.expect(std.mem.indexOf(u8, output, "any_halt") != null);
}

// ── Phase 5 星轨扩展端到端测试 ──

test "e2e: async 函数调用编译为 orbit_async_create" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: async fun compute() -> i64 { 42 } fun main() -> i64 { compute().await() }
    const compute_decl = ah.asyncFunDecl("compute", &.{}, ah.namedType("i64"), ah.block(&.{}, ah.intLit("42")));
    const body = ah.block(&.{}, ah.methodCall(ah.call("compute", &.{}), "await", &.{}));
    const decls = [_]ast.Decl{
        compute_decl,
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 验证：compute 函数标记为 async
    try testing.expect(ir.functions[0].is_async);
    try testing.expect(!ir.functions[1].is_async);

    // 验证：main 函数中应发射 orbit_async_create + orbit_async_join
    // 节点序列：orbit_async_create, orbit_async_join, halt_return
    const main_nodes = ir.funcNodes(1);
    try testing.expectEqual(@as(usize, 3), main_nodes.len);
    try testing.expectEqual(NodeOp.orbit_async_create, main_nodes[0].op);
    try testing.expectEqual(NodeOp.orbit_async_join, main_nodes[1].op);
    try testing.expectEqual(NodeOp.halt_return, main_nodes[2].op);

    // 验证：orbit_async_create 的输出是 ref_chan（handle）
    try testing.expectEqual(ChanType.ref_chan, ir.channels.get(main_nodes[0].output).chan_type);

    // 验证：orbit_metas 表有 1 条记录
    try testing.expectEqual(@as(usize, 1), ir.orbit_metas.len);
    try testing.expectEqual(@as(u16, 0), ir.orbit_metas[0].func_index);
    try testing.expectEqual(@as(u8, 0), ir.orbit_metas[0].arg_count);
    try testing.expectEqual(ChanType.i64_chan, ir.orbit_metas[0].result_type);
}

test "e2e: orbit_async_join 等待异步结果" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: async fun compute() -> i64 { 42 } fun main() -> i64 { compute().await() }
    const compute_decl = ah.asyncFunDecl("compute", &.{}, ah.namedType("i64"), ah.block(&.{}, ah.intLit("42")));
    const body = ah.block(&.{}, ah.methodCall(ah.call("compute", &.{}), "await", &.{}));
    const decls = [_]ast.Decl{
        compute_decl,
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 验证：orbit_async_create 的 meta_index 指向 orbit_metas[0]
    const create_node = ir.funcNodes(1)[0];
    try testing.expectEqual(NodeOp.orbit_async_create, create_node.op);
    try testing.expectEqual(@as(u16, 1), create_node.meta_index);

    // 验证：orbit_metas 记录了结果类型，join 时用此类型分配结果通道
    try testing.expectEqual(ChanType.i64_chan, ir.orbit_metas[0].result_type);
}

test "e2e: async 函数带参数" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: async fun add(x: i64, y: i64) -> i64 { x + y } fun main() -> i64 { add(1, 2).await() }
    const x_param = ah.param("x", "i64");
    const y_param = ah.param("y", "i64");
    const add_decl = ah.asyncFunDecl("add", &.{ x_param, y_param }, ah.namedType("i64"),
        ah.block(&.{}, ah.binary(.add, ah.ident("x"), ah.ident("y"))));
    const body = ah.block(&.{}, ah.methodCall(ah.call("add", &.{ ah.intLit("1"), ah.intLit("2") }), "await", &.{}));
    const decls = [_]ast.Decl{
        add_decl,
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    // 验证：orbit_async_create 有 2 个输入（参数通道）
    // 节点序列：const_i(1), const_i(2), orbit_async_create, orbit_async_join, halt_return
    const main_nodes = ir.funcNodes(1);
    try testing.expectEqual(@as(usize, 5), main_nodes.len);
    try testing.expectEqual(NodeOp.const_i, main_nodes[0].op);
    try testing.expectEqual(NodeOp.const_i, main_nodes[1].op);
    try testing.expectEqual(NodeOp.orbit_async_create, main_nodes[2].op);
    try testing.expectEqual(@as(u8, 2), main_nodes[2].input_count);
    try testing.expectEqual(NodeOp.orbit_async_join, main_nodes[3].op);

    // 验证：orbit_metas 记录了正确的函数索引和参数数量
    try testing.expectEqual(@as(u16, 0), ir.orbit_metas[0].func_index);
    try testing.expectEqual(@as(u8, 2), ir.orbit_metas[0].arg_count);
}

test "e2e: orbit_chan_send/recv 通道通信" {
    // 直接用 builder 发射 orbit 通信节点（不经过 AST build）
    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();

    // 手动发射 orbit_chan_send 和 orbit_chan_recv
    const handle_chan: u16 = 0;
    const val_chan: u16 = 1;
    _ = try builder.emitOrbitSend(handle_chan, val_chan);
    _ = try builder.emitOrbitRecv(handle_chan, .i64_chan);
    _ = try builder.emitOrbitTryRecv(handle_chan, .i64_chan);

    // 验证节点已追加到 builder.nodes
    try testing.expectEqual(@as(usize, 3), builder.nodes.items.len);
    try testing.expectEqual(NodeOp.orbit_chan_send, builder.nodes.items[0].op);
    try testing.expectEqual(NodeOp.orbit_chan_recv, builder.nodes.items[1].op);
    try testing.expectEqual(NodeOp.orbit_chan_try_recv, builder.nodes.items[2].op);

    // 验证 send 节点是二元（handle + value）
    try testing.expectEqual(@as(u8, 2), builder.nodes.items[0].input_count);
    // 验证 recv 节点是一元（handle）
    try testing.expectEqual(@as(u8, 1), builder.nodes.items[1].input_count);
}

test "e2e: 星轨元数据 printer 输出" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: async fun compute() -> i64 { 42 } fun main() -> i64 { compute() }
    const compute_decl = ah.asyncFunDecl("compute", &.{}, ah.namedType("i64"), ah.block(&.{}, ah.intLit("42")));
    const body = ah.block(&.{}, ah.call("compute", &.{}));
    const decls = [_]ast.Decl{
        compute_decl,
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    const output = try @import("printer.zig").irToString(testing.allocator, &ir);
    defer testing.allocator.free(output);

    // 验证星轨元数据打印
    try testing.expect(std.mem.indexOf(u8, output, "星轨元数据") != null);
    try testing.expect(std.mem.indexOf(u8, output, "orbit_async_create") != null);
    try testing.expect(std.mem.indexOf(u8, output, "func=0") != null);
}

test "e2e: 优化器不消除 orbit 副作用节点" {
    var ah = AstHelper.init(testing.allocator);
    defer ah.deinit();

    // AST: async fun compute() -> i64 { 42 } fun main() -> i64 { compute().await() }
    const compute_decl = ah.asyncFunDecl("compute", &.{}, ah.namedType("i64"), ah.block(&.{}, ah.intLit("42")));
    const body = ah.block(&.{}, ah.methodCall(ah.call("compute", &.{}), "await", &.{}));
    const decls = [_]ast.Decl{
        compute_decl,
        ah.funDecl("main", &.{}, ah.namedType("i64"), body, true),
    };
    const mod = ah.module("test", &decls);

    var builder = try IRBuilder.init(testing.allocator);
    defer builder.deinit();
    var ir = try builder.build(mod);
    defer ir.deinit();

    _ = @import("optimizer.zig").optimize(&ir);

    // orbit_async_create 有副作用，不应被 deadNodeElim 消除
    const main_nodes = ir.funcNodes(1);
    try testing.expectEqual(NodeOp.orbit_async_create, main_nodes[0].op);
}
