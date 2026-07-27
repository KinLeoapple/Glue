//! Expression/Inference 编译器（v3 阶段 4：从 builder.zig 物理拆分）
//!
//! 包含表达式编译、类型推断、通道类型解析等相关方法。
//! 通过 pub const 别名注入 IRBuilder（Zig 0.16 已移除 usingnamespace）。

const std = @import("std");
const ast = @import("ast");
const scalar = @import("value").scalar;
const glue_builtin = @import("glue_builtin");
const syscall = @import("syscall");
const node_mod = @import("node.zig");
const meta_mod = @import("meta.zig");
const channel_mod = @import("channel.zig");
const builtin_registry = @import("builtin_registry.zig");
const builtin_type_names = @import("builtin_type_names.zig");
const sema_output_mod = @import("sema").sema_output;
const sema_type_resolver = @import("sema").type_resolver;
const sema_inference = @import("sema").inference;
const analysis_db_mod = @import("analysis_db");
const builder_mod = @import("builder.zig");
const type_descriptor_mod = @import("type_descriptor.zig");

const IRBuilder = builder_mod.IRBuilder;
const BuildError = builder_mod.BuildError;
const Node = builder_mod.Node;
const NodeOp = builder_mod.NodeOp;
const ChannelSpace = builder_mod.ChannelSpace;
const ScalarMeta = builder_mod.ScalarMeta;
const ScalarKind = builder_mod.ScalarKind;
const ConstVal = builder_mod.ConstVal;
const CallMeta = builder_mod.CallMeta;
const Function = builder_mod.Function;
const VectorMeta = builder_mod.VectorMeta;
// BoundType/TypeBinding 已删除：IR 侧不再维护类型绑定栈
const VecOp = builder_mod.VecOp;
const GateMeta = builder_mod.GateMeta;
const GateKind = builder_mod.GateKind;
const RouteMeta = builder_mod.RouteMeta;
const RaceMeta = builder_mod.RaceMeta;
const CleanupMeta = builder_mod.CleanupMeta;
const OrbitMeta = builder_mod.OrbitMeta;
const CoroutineMeta = builder_mod.CoroutineMeta;
const LoopMeta = builder_mod.LoopMeta;
const ClosureMeta = builder_mod.ClosureMeta;
const PartialMeta = builder_mod.PartialMeta;
const LoopKind = builder_mod.LoopKind;
const SyscallMeta = builder_mod.SyscallMeta;
const SyscallId = builder_mod.SyscallId;
const HaltKind = builder_mod.HaltKind;
const IntKind = builder_mod.IntKind;
const FloatKind = builder_mod.FloatKind;
const VarBinding = builder_mod.VarBinding;
const ModuleRef = IRBuilder.ModuleRef;
const SemaResult = sema_output_mod.SemaResult;
const TypeDefInfo = sema_output_mod.TypeDefInfo;
const CtorDefInfo = sema_output_mod.CtorDefInfo;
const TypeDefKind = sema_output_mod.TypeDefKind;
const TraitDefInfo = sema_output_mod.TraitDefInfo;
const TraitMethodSig = sema_output_mod.TraitMethodSig;

// Free function aliases (defined in builder.zig, re-exported for verbatim method bodies)
const chanTypeFromTypeNode = builder_mod.chanTypeFromTypeNode;
const chanTypeFromExprAst = builder_mod.chanTypeFromExprAst;
const isThrowType = builder_mod.isThrowType;
const typeNameFromTypeNodeConst = builder_mod.typeNameFromTypeNodeConst;
const primitiveLayout = builder_mod.primitiveLayout;
const alignUp = builder_mod.alignUp;
const binaryOpToNodeOp = builder_mod.binaryOpToNodeOp;
const unaryOpToNodeOp = builder_mod.unaryOpToNodeOp;
const binaryResultType = builder_mod.binaryResultType;
const throwOkChanType = builder_mod.throwOkChanType;
const throwOkTypeNode = builder_mod.throwOkTypeNode;
const throwOkTypeName = builder_mod.throwOkTypeName;
const asyncInnerTypeNode = builder_mod.asyncInnerTypeNode;
const isStringTypeNode = builder_mod.isStringTypeNode;
const isNullableTypeNode = builder_mod.isNullableTypeNode;
const typeNameFromTypeNode = builder_mod.typeNameFromTypeNode;
const allocChanFromTypeNode = builder_mod.allocChanFromTypeNode;
const filterDigits = builder_mod.filterDigits;
const intKindFromSuffix = builder_mod.intKindFromSuffix;
const floatKindFromSuffix = builder_mod.floatKindFromSuffix;
const astContainsBreakOrContinueExpr = builder_mod.astContainsBreakOrContinueExpr;
const astContainsBreakOrContinueStmt = builder_mod.astContainsBreakOrContinueStmt;
const extractAccumulatorPattern = builder_mod.extractAccumulatorPattern;
const binOpToNodeOp = builder_mod.binOpToNodeOp;
const tryExtractBreakContinueCond = builder_mod.tryExtractBreakContinueCond;
const astContainsExternalAssignExpr = builder_mod.astContainsExternalAssignExpr;
const astContainsExternalAssignStmt = builder_mod.astContainsExternalAssignStmt;
const unwrapBlockExpr = builder_mod.unwrapBlockExpr;
const unwrapAsyncType = builder_mod.unwrapAsyncType;
const retKindToChanType = builder_mod.retKindToChanType;

/// GadtContext.infer_expr_fn 的适配器：将 *anyopaque 转回 *IRBuilder 并调用 inferExprChanType
/// 用于 sema 侧 GADT 推断函数递归调用 IR 侧的表达式类型推断
fn inferExprChanTypeAdapter(ctx: *anyopaque, expr: *const ast.Expr) ?*const type_descriptor_mod.TypeDescriptor {
    const builder: *IRBuilder = @ptrCast(@alignCast(ctx));
    return Methods.inferExprChanType(builder, expr);
}

pub const Methods = struct {
    pub fn compileExpr(self: *IRBuilder, expr: *const ast.Expr) BuildError!u16 {
        // 尾位置传播：保存当前尾位置状态，函数返回时恢复
        // 尾位置传播的表达式（if/match/block/propagate/call）保持 in_tail_position，
        // 其他表达式清除 in_tail_position（其子表达式不在尾位置）
        const saved_tail = self.in_tail_position;
        defer self.in_tail_position = saved_tail;
        switch (expr.*) {
            .if_expr, .match, .block, .propagate, .call => {}, // 尾位置传播
            else => self.in_tail_position = false, // 非尾位置：子表达式不在尾位置
        }
        switch (expr.*) {
            .int_literal => |il| {
                var sema_chan: ?*const type_descriptor_mod.TypeDescriptor = null;
                { const sr = self.sema_result; if (sr.getExpr(@intFromPtr(expr))) |info| {
                    sema_chan = info.type_desc;
                } }
                return self.compileIntLiteral(il.raw, il.suffix, sema_chan);
            },
            .float_literal => |fl| {
                var sema_chan: ?*const type_descriptor_mod.TypeDescriptor = null;
                { const sr = self.sema_result; if (sr.getExpr(@intFromPtr(expr))) |info| {
                    sema_chan = info.type_desc;
                } }
                return self.compileFloatLiteral(fl.raw, fl.suffix, sema_chan);
            },
            .bool_literal => |bl| {
                const out = try self.allocChannel(type_descriptor_mod.bool_descriptor);
                const meta_idx = try self.addScalarMeta(.{
                    .kind = .bool,
                    .const_val = .{ .bool_val = bl.value },
                });
                try self.emit(Node.makeSink(.const_bool, out, meta_idx));
                return out;
            },
            .char_literal => |cl| {
                const out = try self.allocChannel(type_descriptor_mod.char_descriptor);
                const meta_idx = try self.addScalarMeta(.{
                    .kind = .char,
                    .const_val = .{ .char_val = cl.value },
                });
                try self.emit(Node.makeSink(.const_char, out, meta_idx));
                return out;
            },
            .null_literal => {
                const out = try self.allocChannel(type_descriptor_mod.null_descriptor);
                try self.emit(Node.makeSink(.const_null, out, 0));
                return out;
            },
            .unit_literal => {
                const out = try self.allocChannel(type_descriptor_mod.unit_descriptor);
                try self.emit(Node.makeSink(.const_unit, out, 0));
                return out;
            },
            .string_literal => |sl| {
                const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
                const str_idx = self.addString(sl.value);
                const meta_idx = try self.addScalarMeta(.{ .kind = .str, .const_val = .{ .int_val = @intCast(str_idx) } });
                try self.emit(Node.makeSink(.const_str, out, meta_idx));
                return out;
            },
            .array_literal => |al| {
                // 数组填充语法 [v, ..n]：用 fill_value 重复 fill_count 次
                if (al.fill_value) |fv| {
                    const count_expr = al.fill_count orelse return error.InvalidLiteral;
                    // 编译 count
                    const count_chan = try self.compileExpr(count_expr);
                    // 编译 fill_value
                    const value_chan = try self.compileExpr(fv);
                    // array_fill(output, count, value) — 使用 makeBinary
                    const arr_chan = try self.allocChannel(type_descriptor_mod.ref_descriptor);
                    try self.emit(Node.makeBinary(.array_fill, arr_chan, 0, count_chan, value_chan));
                    return arr_chan;
                }
                // 编译所有元素，然后创建数组
                // Phase 2.5 简化：array_make 接收长度，然后逐个 array_set
                const elem_count = al.elements.len;
                // 推断元素是否为 &T / *T：任一元素表达式为引用类型则整体按引用数组处理
                var elem_is_ref = false;
                for (al.elements) |elem_expr| {
                    if (self.isRefExpr(elem_expr)) {
                        elem_is_ref = true;
                        break;
                    }
                }
                // 长度常量
                const len_chan = try self.allocChannel(type_descriptor_mod.i64_descriptor);
                const len_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = @intCast(elem_count) } });
                try self.emit(Node.makeSink(.const_i, len_chan, len_meta));
                // 创建数组（_pad bit 0 标记 elem_is_ref）
                const arr_chan = try self.allocChannel(type_descriptor_mod.ref_descriptor);
                var make_node = Node.makeUnary(.array_make, arr_chan, 0, len_chan);
                make_node._pad = if (elem_is_ref) 1 else 0;
                try self.emit(make_node);
                // 逐个设置元素
                for (al.elements, 0..) |elem_expr, i| {
                    const elem_chan = try self.compileExpr(elem_expr);
                    const idx_chan = try self.allocChannel(type_descriptor_mod.i64_descriptor);
                    const idx_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = @intCast(i) } });
                    try self.emit(Node.makeSink(.const_i, idx_chan, idx_meta));
                    // array_set(arr, idx, value) — 使用 makeTernary
                    try self.emit(Node.makeTernary(.array_set, arr_chan, 0, arr_chan, idx_chan, elem_chan));
                }
                return arr_chan;
            },
            .identifier => |id| {
                // 先查变量绑定
                if (self.lookupVar(id.name)) |binding| return binding.chan;
                // 符号别名查找：selective import 的常量/函数短名 → mangled 名
                // 如 UNIX_EPOCH → std.time.SystemTime.UNIX_EPOCH（全局 val 已注册为变量）
                if (self.symbol_alias_map.get(id.name)) |mangled| {
                    if (self.lookupVar(mangled)) |binding| return binding.chan;
                }
                // 再查构造器表：无参构造器如 Leaf 可直接作为 identifier 引用
                if (self.sema_result.getCtorDef(id.name)) |ctor| {
                    if (ctor.field_type_descs.len == 0) {
                        return try self.compileConstructorCall(ctor, &.{});
                    }
                }
                return error.UnboundVariable;
            },
            .binary => |b| return self.compileBinary(b.op, b.left, b.right),
            .unary => |u| return self.compileUnary(u.op, u.operand),
            .ref_of => |r| return self.compileRefOf(r.operand),
            .deref => |d| return self.compileDeref(d.operand, expr),
            .block => |blk| return self.compileBlock(blk.statements, blk.trailing_expr),
            .call => |c| return self.compileCallWithTypeArgs(c.callee, c.arguments, c.type_args, expr),
            .if_expr => |ie| return self.compileIf(ie),
            .propagate => |p| return self.compilePropagate(p.expr),
            .select => |s| return self.compileSelect(s.arms),
            .type_cast => |tc| return self.compileTypeCast(tc),
            .cast_builder => |cb| return self.compileCastBuilder(cb),
            .record_literal => |rl| return self.compileRecordLiteral(rl.fields),
            .record_extend => |re| return self.compileRecordExtend(re.base, re.updates),
            .field_access => |fa| return self.compileFieldAccess(fa.object, fa.field, expr),
            .index => |idx| return self.compileIndex(idx.object, idx.index),
            .slice => |sl| return self.compileSlice(sl.object, sl.start, sl.end, sl.inclusive),
            .string_interpolation => |si| return self.compileStringInterpolation(si.parts),
            .non_null_assert => |nn| return self.compileNonNullAssert(nn.expr),
            .safe_access => |sa| return self.compileSafeAccess(sa.object, sa.field, expr),
            .method_call => |mc| return self.compileMethodCall(mc.object, mc.method, mc.arguments, false, expr),
            .safe_method_call => |mc| return self.compileMethodCall(mc.object, mc.method, mc.arguments, true, expr),
            .lambda => |lam| return self.compileLambda(lam),
            .match => |m| return self.compileMatch(m.scrutinee, m.arms),
            .assignment_expr => |a| return self.compileAssignmentExpr(a.target, a.value),
            .compound_assign => |ca| return self.compileCompoundAssignExpr(ca.op, ca.target, ca.value),
            .atomic_expr => |ae| return self.compileAtomicExpr(ae.value),
            .lazy => |lz| return self.compileLazyExpr(lz.expr),
            .spawn_expr => |se| return self.compileSpawnExpr(se.expr),
            .inline_trait_value => |itv| return self.compileInlineTraitValue(itv.methods),
        }
    }

    /// 编译整数字面量
    pub fn compileIntLiteral(self: *IRBuilder, raw: []const u8, suffix: ?[]const u8, sema_chan: ?*const type_descriptor_mod.TypeDescriptor) BuildError!u16 {
        // 优先使用 Sema 推导的类型（含 expected 约束与 Rust 模式无约束回退 i32）
        const chan_type = sema_chan orelse blk: {
            const ik = intKindFromSuffix(suffix) orelse .i32;
            break :blk type_descriptor_mod.lookupByIntKind(ik);
        };
        const int_kind = chan_type.toIntKind() orelse .i32;

        // 解析整数值（过滤下划线）
        var clean_buf: [64]u8 = undefined;
        const clean = filterDigits(raw, &clean_buf);

        // 检测进制前缀：0x/0X=十六进制, 0o/0O=八进制, 0b/0B=二进制
        const base: u8 = blk: {
            if (clean.len >= 2 and clean[0] == '0') {
                switch (clean[1]) {
                    'x', 'X' => break :blk 16,
                    'o', 'O' => break :blk 8,
                    'b', 'B' => break :blk 2,
                    else => {},
                }
            }
            break :blk 10;
        };
        const digits = if (base != 10) clean[2..] else clean;

        const value: i128 = std.fmt.parseInt(i128, digits, base) catch return error.InvalidLiteral;

        const out = try self.allocChannel(chan_type);
        const meta_idx = try self.addScalarMeta(.{
            .kind = .int,
            .int_kind = int_kind,
            .const_val = .{ .int_val = value },
        });
        try self.emit(Node.makeSink(.const_i, out, meta_idx));
        return out;
    }

    /// 编译浮点字面量
    pub fn compileFloatLiteral(self: *IRBuilder, raw: []const u8, suffix: ?[]const u8, sema_chan: ?*const type_descriptor_mod.TypeDescriptor) BuildError!u16 {
        // 优先使用 Sema 推导的类型（含 expected 约束与 Rust 模式无约束回退 f32）
        const chan_type = sema_chan orelse blk: {
            const fk = floatKindFromSuffix(suffix) orelse .f32;
            break :blk type_descriptor_mod.lookupByFloatKind(fk);
        };
        const float_kind = chan_type.toFloatKind() orelse .f32;

        const value: f64 = std.fmt.parseFloat(f64, raw) catch return error.InvalidLiteral;
        const bits: u64 = @bitCast(value);

        const out = try self.allocChannel(chan_type);
        const meta_idx = try self.addScalarMeta(.{
            .kind = .float,
            .float_kind = float_kind,
            .const_val = .{ .float_val = bits }, // f64 位模式存入 u128
        });
        try self.emit(Node.makeSink(.const_f, out, meta_idx));
        return out;
    }

    /// 编译二元运算
    pub fn compileBinary(self: *IRBuilder, op: ast.BinaryOp, left: *ast.Expr, right: *ast.Expr) BuildError!u16 {
        // Elvis 操作符 (??) 特殊处理：编译为 nullable_unwrap_or
        if (op == .elvis) {
            return self.compileElvis(left, right);
        }

        // Range 操作符 (.. / ..=) 特殊处理：创建数组
        if (op == .range or op == .range_inclusive) {
            return self.compileRangeExpr(left, right, op == .range_inclusive);
        }

        // 短路逻辑运算符 && / || ：用 route_dispatch 实现惰性求值
        if (op == .and_op or op == .or_op) {
            return self.compileShortCircuit(op, left, right);
        }

        // concat_list (++) 特殊处理：区分字符串拼接和数组拼接
        if (op == .concat_list) {
            const left_chan = try self.compileExpr(left);
            const right_chan = try self.compileExpr(right);
            const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
            const is_string = self.isStringExpr(left);
            const node_op: NodeOp = if (is_string) .string_concat else .array_concat;
            const meta_idx = try self.addScalarMeta(.{ .kind = .ref });
            try self.emit(Node.makeBinary(node_op, out, meta_idx, left_chan, right_chan));
            return out;
        }

        // .add 对字符串拼接特殊处理：避免被 force_lazy 误强制为标量。
        // 运行期 string_concat 会通过 readStr 自动观察 Lazy<String>。
        if (op == .add) {
            const left_is_string = self.isStringExpr(left);
            const right_is_string = self.isStringExpr(right);
            if (left_is_string or right_is_string) {
                const left_chan = try self.compileExpr(left);
                const right_chan = try self.compileExpr(right);
                const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
                const meta_idx = try self.addScalarMeta(.{ .kind = .ref });
                try self.emit(Node.makeBinary(.string_concat, out, meta_idx, left_chan, right_chan));
                return out;
            }
        }

        // ref_neq (!==) 特殊处理：发射 builtin_ref_eq + bool_not
        if (op == .ref_neq) {
            const left_chan = try self.compileExpr(left);
            const right_chan = try self.compileExpr(right);
            const eq_out = try self.allocChannel(type_descriptor_mod.bool_descriptor);
            try self.emit(Node.makeBinary(.builtin_ref_eq, eq_out, 0, left_chan, right_chan));
            const out = try self.allocChannel(type_descriptor_mod.bool_descriptor);
            try self.emit(Node.makeUnary(.bool_not, out, 0, eq_out));
            return out;
        }

        const left_chan = try self.compileExpr(left);
        return self.compileBinaryOpWithChan(op, left_chan, right);
    }

    /// 编译短路逻辑运算符 && / ||
    /// a && b: a 为 false 时直接返回 false，不评估 b
    /// a || b: a 为 true 时直接返回 true，不评估 b
    pub fn compileShortCircuit(self: *IRBuilder, op: ast.BinaryOp, left: *ast.Expr, right: *ast.Expr) BuildError!u16 {
        const left_chan = try self.compileExpr(left);

        // 条件转 winner 索引：bool cast 为 i64（true=1, false=0）
        const winner_chan = try self.allocChannel(type_descriptor_mod.i64_descriptor);
        const cast_meta_idx = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64 });
        try self.emit(Node.makeUnary(.cast, winner_chan, cast_meta_idx, left_chan));

        const arena_alloc = self.arena.allocator();

        // arm 0 = left is false, arm 1 = left is true
        // For &&: arm 0 → false (skip right), arm 1 → evaluate right
        // For ||: arm 0 → evaluate right, arm 1 → true (skip right)
        const short_circuit_arm: u8 = if (op == .and_op) 0 else 1;

        const arm0_start: u32 = @intCast(self.nodes.items.len);
        const arm0_chan: u16 = if (short_circuit_arm == 0) try self.emitConstBool(op == .or_op) else try self.compileExpr(right);
        if (self.nodes.items.len == arm0_start) {
            const load_chan = try self.allocChannel(self.channels.get(arm0_chan).type_desc);
            try self.emit(Node.makeUnary(.load, load_chan, 0, arm0_chan));
        }
        const arm0_len: u32 = @intCast(self.nodes.items.len - arm0_start);

        const arm1_start: u32 = @intCast(self.nodes.items.len);
        const arm1_chan: u16 = if (short_circuit_arm == 1) try self.emitConstBool(op == .or_op) else try self.compileExpr(right);
        if (self.nodes.items.len == arm1_start) {
            const load_chan = try self.allocChannel(self.channels.get(arm1_chan).type_desc);
            try self.emit(Node.makeUnary(.load, load_chan, 0, arm1_chan));
        }
        const arm1_len: u32 = @intCast(self.nodes.items.len - arm1_start);

        const body_starts = try arena_alloc.alloc(u32, 2);
        const body_lens = try arena_alloc.alloc(u32, 2);
        body_starts[0] = arm0_start;
        body_lens[0] = arm0_len;
        body_starts[1] = arm1_start;
        body_lens[1] = arm1_len;

        const result_chan = try self.allocChannel(type_descriptor_mod.bool_descriptor);
        const route_meta_idx = try self.addRouteMeta(.{
            .trait_id = 0,
            .method_id = 0,
            .target_count = 2,
            .body_starts = body_starts,
            .body_lens = body_lens,
        });
        try self.emit(Node.makeUnary(.route_dispatch, result_chan, route_meta_idx, winner_chan));
        return result_chan;
    }

    /// 编译 range 表达式：start..end 或 start..=end → array
    pub fn compileRangeExpr(self: *IRBuilder, left: *const ast.Expr, right: *const ast.Expr, inclusive: bool) BuildError!u16 {
        const start_chan = try self.compileExpr(left);
        const end_chan = try self.compileExpr(right);

        // 计算长度：end - start (或 end - start + 1 if inclusive)
        const diff_chan = try self.allocChannel(type_descriptor_mod.i64_descriptor);
        const meta_idx = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64 });
        try self.emit(Node.makeBinary(.int_sub, diff_chan, meta_idx, end_chan, start_chan));

        var len_chan = diff_chan;
        if (inclusive) {
            const one_chan = try self.allocChannel(type_descriptor_mod.i64_descriptor);
            const one_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = 1 } });
            try self.emit(Node.makeSink(.const_i, one_chan, one_meta));
            const incl_len = try self.allocChannel(type_descriptor_mod.i64_descriptor);
            try self.emit(Node.makeBinary(.int_add, incl_len, meta_idx, diff_chan, one_chan));
            len_chan = incl_len;
        }

        // 创建数组
        const arr_chan = try self.allocChannel(type_descriptor_mod.ref_descriptor);
        try self.emit(Node.makeUnary(.array_make, arr_chan, 0, len_chan));

        // 使用 vec_source + vec_sink 填充数组
        // 简化：直接返回空数组（长度已设置），元素通过 vec_source 填充
        // 完整实现需要 vec_source 从 start 到 end 生成值
        return arr_chan;
    }

    /// 编译二元运算（左操作数已编译为通道）
    pub fn compileBinaryOpWithChan(self: *IRBuilder, op: ast.BinaryOp, left_chan: u16, right: *ast.Expr) BuildError!u16 {
        if (op == .elvis) return error.UnsupportedExpr;

        const right_chan = try self.compileExpr(right);
        var left_meta = self.channels.get(left_chan);
        var right_meta = self.channels.get(right_chan);

        // var 变量绑定到 cell 通道，参与运算前需要先 load 出当前值
        var left_ch = if (left_meta.is_cell) try self.emitLoad(left_chan) else left_chan;
        var right_ch = if (right_meta.is_cell) try self.emitLoad(right_chan) else right_chan;
        left_meta = self.channels.get(left_ch);
        right_meta = self.channels.get(right_ch);

        // nullable == null / nullable != null 特殊处理：直接检查 null flag
        if (op == .eq or op == .not_eq) {
            const left_is_nullable = left_meta.type_desc.is_nullable;
            const right_is_nullable = right_meta.type_desc.is_nullable;
            const left_is_null = left_meta.type_desc.is_null_type;
            const right_is_null = right_meta.type_desc.is_null_type;
            if ((left_is_nullable and right_is_null) or (left_is_null and right_is_nullable)) {
                const nullable_chan = if (left_is_nullable) left_ch else right_ch;
                const is_null_out = try self.allocChannel(type_descriptor_mod.bool_descriptor);
                try self.emit(Node.makeUnary(.nullable_is_null, is_null_out, 0, nullable_chan));
                if (op == .eq) {
                    return is_null_out;
                } else {
                    const out = try self.allocChannel(type_descriptor_mod.bool_descriptor);
                    try self.emit(Node.makeUnary(.bool_not, out, 0, is_null_out));
                    return out;
                }
            }
        }

        // == / != 对两个 ref_chan 操作数：路由到 builtin_eq 做递归值相等比较。
        // ref_chan 可能是 Str/Array/Record/ADT/Newtype 等堆对象，value.equals 会按
        // type_tag 分派做递归比较；若误走 lazy_force 会对非 LazyValue 报 InvalidChannel。
        if ((op == .eq or op == .not_eq) and
            left_meta.type_desc.is_ref and right_meta.type_desc.is_ref)
        {
            const eq_out = try self.allocChannel(type_descriptor_mod.bool_descriptor);
            try self.emit(Node.makeBinary(.builtin_eq, eq_out, 0, left_ch, right_ch));
            if (op == .eq) return eq_out;
            const out = try self.allocChannel(type_descriptor_mod.bool_descriptor);
            try self.emit(Node.makeUnary(.bool_not, out, 0, eq_out));
            return out;
        }

        // + 对两个 ref_chan 操作数：isStringExpr 可能无法识别 lambda 内的字符串参数，
        // 此处兜底路由到 string_concat（+ 在两个堆引用上只可能是字符串拼接）。
        if (op == .add and
            left_meta.type_desc.is_ref and right_meta.type_desc.is_ref)
        {
            const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
            const meta_idx = try self.addScalarMeta(.{ .kind = .ref });
            try self.emit(Node.makeBinary(.string_concat, out, meta_idx, left_ch, right_ch));
            return out;
        }

        // < > <= >= 对两个 ref_chan 操作数：按字符串字典序比较。
        // ref_chan 堆对象中只有字符串支持有序比较（数组/记录/ADT 的 < 无语义），
        // 若误走 force_lazy 会把字符串当 i64 惰性值求值，触发 InvalidChannel。
        if ((op == .lt or op == .gt or op == .lt_eq or op == .gt_eq) and
            left_meta.type_desc.is_ref and right_meta.type_desc.is_ref)
        {
            const out = try self.allocChannel(type_descriptor_mod.bool_descriptor);
            // _pad 编码：0=lt, 1=le, 2=gt, 3=ge
            const pad: u8 = switch (op) {
                .lt => 0,
                .lt_eq => 1,
                .gt => 2,
                .gt_eq => 3,
                else => unreachable,
            };
            var node = Node.makeBinary(.string_cmp, out, 0, left_ch, right_ch);
            node._pad = pad;
            try self.emit(node);
            return out;
        }

        // 严格运算上下文：ref_chan 操作数视为 Lazy<T>，先强制求值到标量。
        // ref_eq/ref_neq 比较引用本身，不触发求值；concat/concat_list 已前置处理。
        const force_lazy = switch (op) {
            .add, .sub, .mul, .div, .mod,
            .eq, .not_eq, .lt, .gt, .lt_eq, .gt_eq,
            .bit_and, .bit_or, .bit_xor, .shl, .shr => true,
            else => false,
        };
        if (force_lazy) {
            if (left_meta.type_desc.is_ref and right_meta.type_desc.is_ref) {
                // 两侧都是惰性引用，无法从上下文推断 T：保守地强制为 i64
                left_ch = try self.emitLazyForce(left_ch, type_descriptor_mod.i64_descriptor);
                right_ch = try self.emitLazyForce(right_ch, type_descriptor_mod.i64_descriptor);
            } else if (left_meta.type_desc.is_ref) {
                left_ch = try self.emitLazyForce(left_ch, right_meta.type_desc);
            } else if (right_meta.type_desc.is_ref) {
                right_ch = try self.emitLazyForce(right_ch, left_meta.type_desc);
            }
            left_meta = self.channels.get(left_ch);
            right_meta = self.channels.get(right_ch);
        }

        // 类型统一：左右操作数为不同宽度的整数/浮点时，将较窄的一方提升到较宽的一方，
        // 避免引擎按宽类型读取窄通道时读到未初始化字节（如 i64 字面量 × i32 变量）
        const unified_type = blk: {
            const lt = left_meta.type_desc;
            const rt = right_meta.type_desc;
            if (lt.isInt() and rt.isInt() and lt != rt) {
                if (lt.elemWidth() >= rt.elemWidth()) {
                    right_ch = try self.emitScalarCast(right_ch, lt);
                    break :blk lt;
                } else {
                    left_ch = try self.emitScalarCast(left_ch, rt);
                    break :blk rt;
                }
            }
            if (lt.isFloat() and rt.isFloat() and lt != rt) {
                if (lt.elemWidth() >= rt.elemWidth()) {
                    right_ch = try self.emitScalarCast(right_ch, lt);
                    break :blk lt;
                } else {
                    left_ch = try self.emitScalarCast(left_ch, rt);
                    break :blk rt;
                }
            }
            break :blk lt;
        };

        const result_type = binaryResultType(op, unified_type);
        const out = try self.allocChannel(result_type);

        const node_op = try binaryOpToNodeOp(op, unified_type);
        const kind: ScalarKind = if (result_type.isInt()) .int else if (result_type.isFloat()) .float else if (result_type == type_descriptor_mod.ref_descriptor) .ref else .bool;
        const meta_idx = try self.addScalarMeta(.{
            .kind = kind,
            .int_kind = result_type.toIntKind() orelse .i64,
            .float_kind = result_type.toFloatKind() orelse .f64,
        });

        try self.emit(Node.makeBinary(node_op, out, meta_idx, left_ch, right_ch));
        return out;
    }

    /// 发射标量类型转换节点（int→int, float→float, int→float, float→int）
    /// 用于二元运算前统一操作数类型
    pub fn emitScalarCast(self: *IRBuilder, src_chan: u16, dst_ct: *const type_descriptor_mod.TypeDescriptor) BuildError!u16 {
        const out = try self.allocChannel(dst_ct);
        const kind: ScalarKind = if (dst_ct.isInt()) .int else if (dst_ct.isFloat()) .float else .bool;
        const meta_idx = try self.addScalarMeta(.{
            .kind = kind,
            .int_kind = dst_ct.toIntKind() orelse .i64,
            .float_kind = dst_ct.toFloatKind() orelse .f64,
        });
        try self.emit(Node.makeUnary(.cast, out, meta_idx, src_chan));
        return out;
    }

    /// 发射 lazy_force 节点：将 Lazy<T> 强制求值为标量 T。
    /// 用于二元/一元运算等严格上下文：ref_chan 操作数在参与标量运算前先被观察。
    pub fn emitLazyForce(self: *IRBuilder, src_chan: u16, dst_ct: *const type_descriptor_mod.TypeDescriptor) BuildError!u16 {
        const out = try self.allocChannel(dst_ct);
        try self.emit(Node.makeUnary(.lazy_force, out, 0, src_chan));
        return out;
    }

    /// 通用观察辅助：当通道是 ref_chan（Lazy<T> 或其他引用）且当前上下文需要标量值时，
    /// 发射 lazy_force 节点强制求值。若已是标量通道则原样返回。
    pub fn forceLazyIfRef(self: *IRBuilder, chan: u16, expected_ct: *const type_descriptor_mod.TypeDescriptor) BuildError!u16 {
        const meta = self.channels.get(chan);
        if (!meta.type_desc.is_ref) return chan;
        return try self.emitLazyForce(chan, expected_ct);
    }

    /// 函数参数观察辅助：实参通道传入目标形参通道前，若实参是 Lazy<T>（ref_chan）
    /// 而形参通道期望标量/nullable，则强制求值到目标类型；若目标也是引用类型则保留引用。
    pub fn forceLazyArgIfNeeded(self: *IRBuilder, arg_chan: u16, dst_chan: u16) BuildError!u16 {
        const arg_meta = self.channels.get(arg_chan);
        const dst_meta = self.channels.get(dst_chan);
        const dst_ct = dst_meta.type_desc;

        // 泛型参数装箱：标量实参 → ref_chan 形参（如 println<T>(x: T) 调用 println(42)）
        // 使用 ref_of 节点将标量装箱为 Cell 写入 ref_chan。
        // 运行时 chanToValue 通过 ref_ops.read 读取 Cell 并提取标量值。
        if (dst_ct == type_descriptor_mod.ref_descriptor and !arg_meta.type_desc.is_ref and !arg_meta.type_desc.is_nullable) {
            // 标量/bool/char/unit → ref_chan：装箱
            const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
            try self.emit(Node.makeUnary(.ref_of, out, 0, arg_chan));
            return out;
        }

        if (!arg_meta.type_desc.is_ref) return arg_chan;
        if (dst_ct == type_descriptor_mod.ref_descriptor) return arg_chan;
        // nullable<T> 参数：若内部类型已是引用，直接保留引用由运行时深拷贝到 nullable 通道
        if (dst_ct == type_descriptor_mod.nullable_descriptor and dst_meta.inner_type_desc != null and dst_meta.inner_type_desc.? == type_descriptor_mod.ref_descriptor) return arg_chan;
        if (dst_ct == type_descriptor_mod.nullable_descriptor) return try self.emitLazyForce(arg_chan, dst_meta.inner_type_desc orelse type_descriptor_mod.i64_descriptor);
        return try self.emitLazyForce(arg_chan, dst_ct);
    }

    /// 编译一元运算
    pub fn compileUnary(self: *IRBuilder, op: ast.UnaryOp, operand: *ast.Expr) BuildError!u16 {
        var operand_chan = try self.compileExpr(operand);
        var operand_meta = self.channels.get(operand_chan);

        // 严格运算上下文：ref_chan 操作数视为 Lazy<T>，先强制求值到标量。
        if (operand_meta.type_desc.is_ref) {
            const force_ct: *const type_descriptor_mod.TypeDescriptor = switch (op) {
                .not => type_descriptor_mod.bool_descriptor,
                .neg, .bit_not => type_descriptor_mod.i64_descriptor,
            };
            operand_chan = try self.emitLazyForce(operand_chan, force_ct);
            operand_meta = self.channels.get(operand_chan);
        }

        const result_type = operand_meta.type_desc;
        const out = try self.allocChannel(result_type);

        const node_op = try unaryOpToNodeOp(op, result_type);
        const kind: ScalarKind = if (result_type.isInt()) .int else if (result_type.isFloat()) .float else .bool;
        const meta_idx = try self.addScalarMeta(.{
            .kind = kind,
            .int_kind = result_type.toIntKind() orelse .i64,
            .float_kind = result_type.toFloatKind() orelse .f64,
        });

        try self.emit(Node.makeUnary(node_op, out, meta_idx, operand_chan));
        return out;
    }

    /// 编译取引用 &expr
    /// - 复合类型（ref_chan）：operand 已经是指针，ref_of 直接复制指针到新的 ref_chan
    /// - 标量（i32/f64 等）：operand 是内联值，ref_of 装箱为 Cell 写入 ref_chan
    ///   标量引用统一通过 Cell 装箱实现回写语义
    /// - ref_chan（已经是引用）：ref_of 复制引用本身（引用的引用）
    pub fn compileRefOf(self: *IRBuilder, operand: *ast.Expr) BuildError!u16 {
        const operand_chan = try self.compileExpr(operand);
        const operand_meta = self.channels.get(operand_chan);
        const operand_type = operand_meta.type_desc;

        const out = try self.allocRef(type_descriptor_mod.ref_descriptor);
        // meta.scalar_tag 记录被引用值的原始类型（用于 ref_get 时分配正确宽度的通道）
        const meta_idx = try self.addScalarMeta(.{
            .kind = if (operand_type.isInt()) .int else if (operand_type.isFloat()) .float else .ref,
            .int_kind = operand_type.toIntKind() orelse .i64,
            .float_kind = operand_type.toFloatKind() orelse .f64,
        });
        try self.emit(Node.makeUnary(.ref_of, out, meta_idx, operand_chan));
        return out;
    }

    /// 编译解引用 *expr
    /// 读取引用指向的值到新通道，output 通道类型由 sema 推断的 inner 类型决定
    pub fn compileDeref(self: *IRBuilder, operand: *ast.Expr, deref_expr: *const ast.Expr) BuildError!u16 {
        const operand_chan = try self.compileExpr(operand);

        // 从 sema 获取 *expr 的结果类型（即引用的 inner 类型）
        // 若 sema 不可用或类型未知，fallback 到 ref_chan
        const result_ct = self.inferChanTypeFromExpr(deref_expr) orelse type_descriptor_mod.ref_descriptor;
        const out = try self.allocChannel(result_ct);
        const meta_idx = try self.addScalarMeta(.{
            .kind = blk: {
                if (result_ct == type_descriptor_mod.bool_descriptor or result_ct == type_descriptor_mod.mask_descriptor) break :blk .bool;
                if (result_ct == type_descriptor_mod.char_descriptor) break :blk .char;
                if (result_ct.isInt()) break :blk .int;
                if (result_ct.isFloat()) break :blk .float;
                break :blk .ref;
            },
        });
        try self.emit(Node.makeUnary(.ref_get, out, meta_idx, operand_chan));
        return out;
    }

    /// 编译 if 表达式（惰性分支：then/else 作为子图，由 route_dispatch 按条件执行）
    pub fn compileIf(self: *IRBuilder, ie: anytype) BuildError!u16 {
        var cond_chan = try self.compileExpr(ie.condition);
        // 严格上下文：条件表达式需要被观察为 bool；若是 Lazy<T> 则强制求值。
        cond_chan = try self.forceLazyIfRef(cond_chan, type_descriptor_mod.bool_descriptor);

        // 条件转 winner 索引：bool cast 为 i64（true=1, false=0）
        // arm 0 = else, arm 1 = then → true→1→then, false→0→else
        const winner_chan = try self.allocChannel(type_descriptor_mod.i64_descriptor);
        const cast_meta_idx = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64 });
        try self.emit(Node.makeUnary(.cast, winner_chan, cast_meta_idx, cond_chan));

        // 编译 else/then 为子图（惰性求值，由 route_dispatch 按条件执行）
        // 注意：子图必须至少有一个节点，否则 route_dispatch 无法读取 body 输出
        // 如果表达式编译后没有发射节点（如纯 identifier），补一个 load 节点

        // arm 0 = else 子图
        const else_start: u32 = @intCast(self.nodes.items.len);
        const else_body_chan = if (ie.else_branch) |eb| try self.compileExpr(eb) else blk: {
            const ch = try self.allocChannel(type_descriptor_mod.unit_descriptor);
            try self.emit(Node.makeSink(.const_unit, ch, 0));
            break :blk ch;
        };
        if (self.nodes.items.len == else_start) {
            // 子图为空（纯 identifier 等），补 load 节点
            const load_chan = try self.allocChannel(self.channels.get(else_body_chan).type_desc);
            try self.emit(Node.makeUnary(.load, load_chan, 0, else_body_chan));
        } else if (self.nodes.items[self.nodes.items.len - 1].output != else_body_chan) {
            // 子图 trailing_expr 没有自己发射节点（纯 identifier 或嵌套块返回变量），
            // 补 load 节点确保 route_dispatch 读取的是 trailing_expr 的当前值
            const load_chan = try self.allocChannel(self.channels.get(else_body_chan).type_desc);
            try self.emit(Node.makeUnary(.load, load_chan, 0, else_body_chan));
        }
        const else_len: u32 = @intCast(self.nodes.items.len - else_start);

        // arm 1 = then 子图
        const then_start: u32 = @intCast(self.nodes.items.len);
        const then_body_chan = try self.compileExpr(ie.then_branch);
        if (self.nodes.items.len == then_start) {
            const load_chan = try self.allocChannel(self.channels.get(then_body_chan).type_desc);
            try self.emit(Node.makeUnary(.load, load_chan, 0, then_body_chan));
        } else if (self.nodes.items[self.nodes.items.len - 1].output != then_body_chan) {
            const load_chan = try self.allocChannel(self.channels.get(then_body_chan).type_desc);
            try self.emit(Node.makeUnary(.load, load_chan, 0, then_body_chan));
        }
        const then_len: u32 = @intCast(self.nodes.items.len - then_start);

        // 获取两个分支的实际输出通道类型
        const else_out_chan = self.nodes.items[else_start + else_len - 1].output;
        const then_out_chan = self.nodes.items[then_start + then_len - 1].output;
        const else_type = self.channels.get(else_out_chan).type_desc;
        const then_type = self.channels.get(then_out_chan).type_desc;

        // 类型统一：如果一个分支是 null_chan 而另一个是值类型，
        // 结果应为 nullable_chan（execRouteDispatch 会自动处理类型转换）
        const result_type: *const type_descriptor_mod.TypeDescriptor = blk: {
            if (else_type == type_descriptor_mod.null_descriptor and then_type != type_descriptor_mod.null_descriptor and then_type != type_descriptor_mod.nullable_descriptor) {
                break :blk type_descriptor_mod.nullable_descriptor;
            }
            if (then_type == type_descriptor_mod.null_descriptor and else_type != type_descriptor_mod.null_descriptor and else_type != type_descriptor_mod.nullable_descriptor) {
                break :blk type_descriptor_mod.nullable_descriptor;
            }
            // 默认：取 then 分支类型
            break :blk then_type;
        };

        // 复制到 arena 分配的 slice
        const arena_alloc = self.arena.allocator();
        const body_starts = try arena_alloc.alloc(u32, 2);
        const body_lens = try arena_alloc.alloc(u32, 2);
        body_starts[0] = else_start;
        body_lens[0] = else_len;
        body_starts[1] = then_start;
        body_lens[1] = then_len;

        // route_dispatch 按 winner 索引执行对应子图
        const result_chan = if (result_type == type_descriptor_mod.nullable_descriptor) blk: {
            const inner_ct = if (then_type != type_descriptor_mod.null_descriptor and then_type != type_descriptor_mod.nullable_descriptor) then_type
                else if (else_type != type_descriptor_mod.null_descriptor and else_type != type_descriptor_mod.nullable_descriptor) else_type
                else type_descriptor_mod.i64_descriptor;
            break :blk try self.channels.allocNullable(inner_ct);
        } else try self.allocChannel(result_type);
        const route_meta_idx = try self.addRouteMeta(.{
            .trait_id = 0,
            .method_id = 0,
            .target_count = 2,
            .body_starts = body_starts,
            .body_lens = body_lens,
        });
        try self.emit(Node.makeUnary(.route_dispatch, result_chan, route_meta_idx, winner_chan));
        return result_chan;
    }

    /// 编译类型转换（type_cast）
    /// safe=false: i32(big) — 不安全转换，wrap/饱和
    /// safe=true:  i32(x)?  — 安全转换，越界抛出错误（? 传播）
    pub fn compileTypeCast(self: *IRBuilder, tc: anytype) BuildError!u16 {
        const dst_chan_type = self.chanTypeFromTypeNodeResolved(tc.target_type) orelse return error.UnsupportedType;
        const src_chan = try self.forceLazyIfRef(try self.compileExpr(tc.expr), dst_chan_type);

        // str(x) 是内置函数调用，不是类型转换
        if (dst_chan_type == type_descriptor_mod.ref_descriptor) {
            if (tc.target_type.* == .named and std.mem.eql(u8, tc.target_type.named.name, "str")) {
                const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
                try self.emit(Node.makeUnary(.builtin_str, out, 0, src_chan));
                return out;
            }
        }

        const out = try self.allocChannel(dst_chan_type);

        // 构造目标类型的 ScalarMeta
        const kind: ScalarKind = if (dst_chan_type.isInt()) .int else if (dst_chan_type.isFloat()) .float else if (dst_chan_type == type_descriptor_mod.bool_descriptor) .bool else if (dst_chan_type == type_descriptor_mod.char_descriptor) .char else .ref;
        const meta_idx = try self.addScalarMeta(.{
            .kind = kind,
            .int_kind = dst_chan_type.toIntKind() orelse .i64,
            .float_kind = dst_chan_type.toFloatKind() orelse .f64,
        });

        const op: NodeOp = if (tc.safe) .cast_safe else .cast;
        try self.emit(Node.makeUnary(op, out, meta_idx, src_chan));
        return out;
    }

    /// 编译 cast builder 表达式（Phase 3）：cast(expr).to(T) / cast(expr).try_to(T)
    ///
    /// to 模式：
    ///   - 输出通道 = T 类型通道
    ///   - op = .cast_to（engine 在产生 Inf / str 解析失败时 panic，否则 wrap）
    ///   - str 目标：复用 .builtin_str 节点（永不失败）
    ///
    /// try_to 模式：
    ///   - 输出通道 = ref_chan（ThrowValue 引用）
    ///   - op = .cast_try_to（engine 在失败时构造 CastError + ThrowValue.err，成功时 ThrowValue.ok）
    ///   - str 目标：直接构造 Throw.ok(str)
    pub fn compileCastBuilder(self: *IRBuilder, cb: anytype) BuildError!u16 {
        const dst_chan_type = self.chanTypeFromTypeNodeResolved(cb.target_type) orelse return error.UnsupportedType;
        const target_is_str = blk: {
            if (cb.target_type.* == .named) {
                if (std.mem.eql(u8, cb.target_type.named.name, "str")) break :blk true;
            }
            break :blk false;
        };
        // 严格上下文：标量转换前若源为 Lazy<T> 则强制求值；
        // str 目标时同样先求值到 i64，再由 builtin_str 格式化。
        // 例外：源为 ref_chan（字符串/数组/标量位模式）时跳过 forceLazyIfRef，
        // 因为 ref_chan 持有的不是 LazyValue，强制求值会触发 InvalidChannel。
        // 引擎 execBuiltinStr / execCastTryTo / execCastTo 均直接处理 ref_chan 源。
        const force_ct: *const type_descriptor_mod.TypeDescriptor = if (target_is_str) type_descriptor_mod.i64_descriptor else dst_chan_type;
        const needs_force = target_is_str or dst_chan_type.isInt() or dst_chan_type.isFloat() or dst_chan_type == type_descriptor_mod.bool_descriptor or dst_chan_type == type_descriptor_mod.char_descriptor;
        const raw_src_chan = try self.compileExpr(cb.expr);
        const raw_is_ref = self.channels.get(raw_src_chan).type_desc.is_ref;
        const src_chan = if (needs_force and !raw_is_ref) try self.forceLazyIfRef(raw_src_chan, force_ct) else raw_src_chan;

        // str 目标：数值→str 永不失败，直接走 builtin_str，再按 mode 包装 Throw
        if (target_is_str) {
            const str_out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
            try self.emit(Node.makeUnary(.builtin_str, str_out, 0, src_chan));
            switch (cb.mode) {
                .to => return str_out,
                .try_to => {
                    // 包装为 Throw.ok(str)
                    const throw_out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
                    const meta_idx = try self.addScalarMeta(.{
                        .kind = .str,
                    });
                    try self.emit(Node.makeUnary(.cast_try_to, throw_out, meta_idx, str_out));
                    return throw_out;
                },
            }
        }

        // 构造目标类型的 ScalarMeta（描述 dst 类型，engine 据此分派转换路径）
        const kind: ScalarKind = if (dst_chan_type.isInt()) .int else if (dst_chan_type.isFloat()) .float else if (dst_chan_type == type_descriptor_mod.bool_descriptor) .bool else if (dst_chan_type == type_descriptor_mod.char_descriptor) .char else .ref;
        const meta_idx = try self.addScalarMeta(.{
            .kind = kind,
            .int_kind = dst_chan_type.toIntKind() orelse .i64,
            .float_kind = dst_chan_type.toFloatKind() orelse .f64,
        });

        switch (cb.mode) {
            .to => {
                // 输出类型 = T
                const out = try self.allocChannel(dst_chan_type);
                try self.emit(Node.makeUnary(.cast_to, out, meta_idx, src_chan));
                return out;
            },
            .try_to => {
                // 输出类型 = ref_chan（ThrowValue 引用）
                const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
                try self.emit(Node.makeUnary(.cast_try_to, out, meta_idx, src_chan));
                return out;
            },
        }
    }

    /// 预扫描 AST 表达式，为所有 record_literal / record_extend 字段注册全局 field_id
    /// 用于解决函数编译顺序导致的全局字段映射缺失问题（详见 build() 注释）
    /// 仅以 "" 命名空间注册，与 compileRecordLiteral/compileRecordExtend 的运行时注册保持一致
    pub fn preRegisterRecordFields(self: *IRBuilder, expr: *const ast.Expr) void {
        switch (expr.*) {
            .record_literal => |rl| {
                for (rl.fields, 0..) |f, i| {
                    self.registerFieldId("", f.name, @intCast(i));
                    self.preRegisterRecordFields(f.value);
                }
            },
            .record_extend => |re| {
                self.preRegisterRecordFields(re.base);
                for (re.updates, 0..) |f, i| {
                    // 仅在未注册时占用下一个 id；预扫描阶段 base 的字段数未知，
                    // 简化处理：直接按出现顺序注册，若已存在则跳过（compileRecordExtend 运行时会复用）
                    if (self.lookupFieldId("", f.name) == null) {
                        self.registerFieldId("", f.name, @intCast(i));
                    }
                    self.preRegisterRecordFields(f.value);
                }
            },
            .call => |c| {
                self.preRegisterRecordFields(c.callee);
                for (c.arguments) |a| self.preRegisterRecordFields(a);
            },
            .method_call => |mc| {
                self.preRegisterRecordFields(mc.object);
                for (mc.arguments) |a| self.preRegisterRecordFields(a);
            },
            .field_access => |fa| self.preRegisterRecordFields(fa.object),
            .safe_access => |sa| self.preRegisterRecordFields(sa.object),
            .safe_method_call => |smc| {
                self.preRegisterRecordFields(smc.object);
                for (smc.arguments) |a| self.preRegisterRecordFields(a);
            },
            .binary => |b| {
                self.preRegisterRecordFields(b.left);
                self.preRegisterRecordFields(b.right);
            },
            .unary => |u| self.preRegisterRecordFields(u.operand),
            .ref_of => |r| self.preRegisterRecordFields(r.operand),
            .deref => |d| self.preRegisterRecordFields(d.operand),
            .assignment_expr => |ae| {
                self.preRegisterRecordFields(ae.target);
                self.preRegisterRecordFields(ae.value);
            },
            .compound_assign => |ca| {
                self.preRegisterRecordFields(ca.target);
                self.preRegisterRecordFields(ca.value);
            },
            .non_null_assert => |nna| self.preRegisterRecordFields(nna.expr),
            .propagate => |p| self.preRegisterRecordFields(p.expr),
            .index => |idx| {
                self.preRegisterRecordFields(idx.object);
                self.preRegisterRecordFields(idx.index);
            },
            .array_literal => |al| {
                for (al.elements) |e| self.preRegisterRecordFields(e);
                if (al.fill_value) |fv| self.preRegisterRecordFields(fv);
                if (al.fill_count) |fc| self.preRegisterRecordFields(fc);
            },
            .slice => |sl| {
                self.preRegisterRecordFields(sl.object);
                self.preRegisterRecordFields(sl.start);
                self.preRegisterRecordFields(sl.end);
            },
            .string_interpolation => |si| {
                for (si.parts) |p| switch (p) {
                    .expression => |e| self.preRegisterRecordFields(e),
                    .literal => {},
                };
            },
            .type_cast => |tc| self.preRegisterRecordFields(tc.expr),
            .cast_builder => |cb| self.preRegisterRecordFields(cb.expr),
            .atomic_expr => |ae| self.preRegisterRecordFields(ae.value),
            .lazy => |l| self.preRegisterRecordFields(l.expr),
            .spawn_expr => |se| self.preRegisterRecordFields(se.expr),
            .if_expr => |ie| {
                self.preRegisterRecordFields(ie.condition);
                self.preRegisterRecordFields(ie.then_branch);
                if (ie.else_branch) |eb| self.preRegisterRecordFields(eb);
            },
            .block => |blk| {
                for (blk.statements) |s| self.preRegisterStmtFields(s);
                if (blk.trailing_expr) |te| self.preRegisterRecordFields(te);
            },
            .match => |m| {
                self.preRegisterRecordFields(m.scrutinee);
                for (m.arms) |arm| {
                    if (arm.guard) |g| self.preRegisterRecordFields(g);
                    self.preRegisterRecordFields(arm.body);
                }
            },
            .lambda => |l| switch (l.body) {
                .block => |b| self.preRegisterRecordFields(b),
                .expression => |e| self.preRegisterRecordFields(e),
            },
            .select => |s| {
                for (s.arms) |arm| switch (arm) {
                    .receive => |r| {
                        self.preRegisterRecordFields(r.channel_expr);
                        self.preRegisterRecordFields(r.body);
                    },
                    .timeout => |t| {
                        self.preRegisterRecordFields(t.duration);
                        self.preRegisterRecordFields(t.body);
                    },
                };
            },
            .inline_trait_value => |itv| {
                for (itv.methods) |m| {
                    if (m.body) |b| self.preRegisterRecordFields(b);
                }
            },
            .int_literal, .float_literal, .bool_literal, .char_literal,
            .string_literal, .null_literal, .unit_literal, .identifier => {},
        }
    }

    /// preRegisterRecordFields 的语句版：递归到语句内的表达式与子语句
    pub fn preRegisterStmtFields(self: *IRBuilder, stmt: *const ast.Stmt) void {
        switch (stmt.*) {
            .val_decl => |vd| self.preRegisterRecordFields(vd.value),
            .var_decl => |vd| self.preRegisterRecordFields(vd.value),
            .assignment => |a| {
                self.preRegisterRecordFields(a.target);
                self.preRegisterRecordFields(a.value);
            },
            .field_assignment => |fa| {
                self.preRegisterRecordFields(fa.object);
                self.preRegisterRecordFields(fa.value);
            },
            .compound_assignment => |ca| {
                self.preRegisterRecordFields(ca.target);
                self.preRegisterRecordFields(ca.value);
            },
            .expression => |es| self.preRegisterRecordFields(es.expr),
            .return_stmt => |rs| {
                if (rs.value) |v| self.preRegisterRecordFields(v);
            },
            .defer_stmt => |ds| self.preRegisterRecordFields(ds.expr),
            .throw_stmt => |ts| self.preRegisterRecordFields(ts.expr),
            .break_stmt, .continue_stmt => {},
            .for_stmt => |fs| {
                self.preRegisterRecordFields(fs.iterable);
                self.preRegisterRecordFields(fs.body);
            },
            .while_stmt => |ws| self.preRegisterRecordFields(ws.body),
            .loop_stmt => |ls| self.preRegisterRecordFields(ls.body),
        }
    }

    /// 编译记录字面量：{ field1: val1, field2: val2 }
    /// → record_make(field_count=N) + 逐个 record_set(field_id=i)
    /// 字段按声明顺序分配 field_id = 0..N-1
    pub fn compileRecordLiteral(self: *IRBuilder, fields: []ast.RecordFieldExpr) BuildError!u16 {
        const rec_chan = try self.allocChannel(type_descriptor_mod.ref_descriptor);
        // 计算字段引用标记位图
        var field_ref_bits: u64 = 0;
        for (fields, 0..) |field, i| {
            if (i < 64 and self.isRefExpr(field.value)) {
                field_ref_bits |= @as(u64, 1) << @intCast(i);
            }
        }
        // record_make：meta 编码 (field_ref_bits << 64) | (field_count << 32) | type_name_idx
        // record literal 无类型名，用空字符串
        const make_meta = try self.addRecordMakeMeta("", @intCast(fields.len), field_ref_bits);
        try self.emit(Node.makeSink(.record_make, rec_chan, make_meta));
        // 为每个字段分配 field_id 并注册（type_name 为空，用全局映射）
        for (fields, 0..) |field, i| {
            const val_chan = try self.compileExpr(field.value);
            const field_id: u16 = @intCast(i);
            self.registerFieldId("", field.name, field_id);
            const field_meta_idx = try self.addFieldIdMeta(field_id);
            try self.emit(Node.makeBinary(.record_set, rec_chan, field_meta_idx, rec_chan, val_chan));
        }
        return rec_chan;
    }

    /// 编译记录扩展：(...base, field: value, ...)
    /// → record_clone_extend(base, extra_count) → record_set(new_rec, field_id, value) ...
    /// record_clone 的 meta 编码扩展字段数：运行时分配 base.fields.len + extra 个槽位
    /// 已存在字段的 field_id 保持不变（复用 base 的），新字段从 base.fields.len 开始追加
    pub fn compileRecordExtend(self: *IRBuilder, base: *ast.Expr, updates: []ast.RecordFieldExpr) BuildError!u16 {
        const base_chan = try self.compileExpr(base);
        // 统计 base 的字段数（用于新字段 field_id 分配）
        const base_field_count = self.countRecordFields(base);
        // 克隆 base 记录并扩展 extra 个槽位
        const new_chan = try self.allocChannel(type_descriptor_mod.ref_descriptor);
        const clone_meta = try self.addScalarMeta(.{
            .kind = .int,
            .int_kind = .i64,
            .const_val = .{ .int_val = @as(i128, @intCast(updates.len)) },
        });
        try self.emit(Node.makeUnary(.record_clone, new_chan, clone_meta, base_chan));
        // 应用更新字段：已存在的复用 base field_id，新字段追加在末尾
        var new_field_idx: u16 = @intCast(base_field_count);
        for (updates) |field| {
            const val_chan = try self.compileExpr(field.value);
            // 若字段已在 base 中注册，复用其 field_id；否则分配新 field_id
            const field_id: u16 = self.lookupFieldId("", field.name) orelse blk: {
                self.registerFieldId("", field.name, new_field_idx);
                const id = new_field_idx;
                new_field_idx += 1;
                break :blk id;
            };
            const field_meta_idx = try self.addFieldIdMeta(field_id);
            try self.emit(Node.makeBinary(.record_set, new_chan, field_meta_idx, new_chan, val_chan));
        }
        return new_chan;
    }

    /// 统计 record 表达式的字段数（用于 record_extend 的 field_id 分配）
    pub fn countRecordFields(self: *IRBuilder, expr: *const ast.Expr) usize {
        switch (expr.*) {
            .record_literal => |rl| return rl.fields.len,
            .record_extend => |re| {
                var base_count = self.countRecordFields(re.base);
                // 统计 updates 中的新字段（不在 base 中的）
                for (re.updates) |u| {
                    if (self.lookupFieldId("", u.name) == null) base_count += 1;
                }
                return base_count;
            },
            .identifier => |id| {
                if (self.lookupVar(id.name)) |binding| {
                    if (binding.ast_expr) |e| return self.countRecordFields(e);
                }
                return 0;
            },
            .call => |c| {
                if (c.callee.* == .identifier) {
                    if (self.sema_result.getCtorDef(c.callee.identifier.name)) |ctor| {
                        // ADT: __tag + 字段数
                        return ctor.field_type_descs.len + 1;
                    }
                }
                return 0;
            },
            else => return 0,
        }
    }

    /// 编译赋值表达式：target = value（作为表达式，返回 value）
    pub fn compileAssignmentExpr(self: *IRBuilder, target: *ast.Expr, value: *ast.Expr) BuildError!u16 {
        const value_chan = try self.compileExpr(value);
        switch (target.*) {
            .identifier => |id| {
                const binding = self.lookupVar(id.name) orelse return error.UnboundVariable;
                try self.emit(Node.makeUnary(.store, binding.chan, 0, value_chan));
            },
            .deref => |d| {
                // *ref = value：通过引用写入
                const ref_chan = try self.compileExpr(d.operand);
                const meta_idx = try self.addScalarMeta(.{ .kind = .ref });
                try self.emit(Node.makeBinary(.ref_set, 0, meta_idx, ref_chan, value_chan));
            },
            else => return error.UnsupportedExpr,
        }
        return value_chan;
    }

    /// 编译复合赋值表达式：target op= value（作为表达式，返回结果）
    pub fn compileCompoundAssignExpr(self: *IRBuilder, op: ast.CompoundAssignOp, target: *ast.Expr, value: *ast.Expr) BuildError!u16 {
        // Atomic += / -= → atomic_fetch_add
        switch (target.*) {
            .identifier => |id| {
                const binding = self.lookupVar(id.name) orelse return error.UnboundVariable;
                if (binding.is_atomic and (op == .add_assign or op == .sub_assign)) {
                    const val_chan = try self.compileExpr(value);
                    const val_meta = self.channels.get(val_chan);
                    const out = try self.allocChannel(val_meta.type_desc);
                    var node = Node.makeBinary(.atomic_fetch_add, out, 0, binding.chan, val_chan);
                    node._pad = if (op == .sub_assign) 1 else 0;
                    try self.emit(node);
                    return out;
                }
            },
            else => {},
        }
        const bin_op: ast.BinaryOp = builder_mod.stmt_compoundAssignOpToBinaryOp(op);
        const result_chan = try self.compileBinary(bin_op, target, value);
        switch (target.*) {
            .identifier => |id| {
                const binding = self.lookupVar(id.name) orelse return error.UnboundVariable;
                try self.emit(Node.makeUnary(.store, binding.chan, 0, result_chan));
            },
            .deref => |d| {
                // *ref op= value：计算结果写回引用
                const ref_chan = try self.compileExpr(d.operand);
                const meta_idx = try self.addScalarMeta(.{ .kind = .ref });
                try self.emit(Node.makeBinary(.ref_set, 0, meta_idx, ref_chan, result_chan));
            },
            else => return error.UnsupportedExpr,
        }
        return result_chan;
    }

    /// 编译字段访问：obj.field
    /// → record_get(obj, field_id) 或 channel_sender/channel_receiver
    /// field_id 通过 field_id_map 查找：先推断 obj 的 type_name，再查映射
    pub fn compileFieldAccess(self: *IRBuilder, object: *ast.Expr, field: []const u8, field_access_expr: *const ast.Expr) BuildError!u16 {
        // 模块引用上的字段访问：std.time.SystemTime.UNIX_EPOCH → 查找全局变量 "std.time.SystemTime.UNIX_EPOCH"
        // pub val 声明在加载时被重命名为 mangled name 并通过 defineVar 注册为全局变量
        if (self.isModuleReference(field_access_expr)) |mod_ref| {
            if (self.lookupVar(mod_ref.full_path)) |binding| return binding.chan;
        }
        // channel 的 sender/receiver 字段特殊处理
        if (std.mem.eql(u8, field, "sender")) {
            const obj_chan = try self.compileExpr(object);
            const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
            try self.emit(Node.makeUnary(.channel_sender, out, 0, obj_chan));
            return out;
        }
        if (std.mem.eql(u8, field, "receiver")) {
            const obj_chan = try self.compileExpr(object);
            const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
            try self.emit(Node.makeUnary(.channel_receiver, out, 0, obj_chan));
            return out;
        }
        const obj_chan = try self.compileExpr(object);
        // 解析 field_id：先尝试从 obj 推断 type_name，再查 field_id_map
        // fallback：用全局 "" 类型名查（record literal 的字段）
        const inferred_type = self.inferTypeNameFromExpr(object);
        const field_id: u16 = blk: {
            if (std.mem.eql(u8, field, "__tag")) break :blk 0; // __tag 固定 field_id=0
            if (inferred_type) |type_name| {
                if (self.lookupFieldId(type_name, field)) |id| break :blk id;
            }
            if (self.lookupFieldId("", field)) |id| break :blk id;
            // 未注册字段：报编译错误（静默返回 0 会访问到 __tag，导致难以排查的 bug）
            std.debug.print("error: field '{s}' not registered on type '{?s}'\n", .{ field, inferred_type });
            return error.UnsupportedExpr;
        };
        const meta_idx = try self.addFieldIdMeta(field_id);
        // 优先从 sema 查询 field_access 表达式本身的 chan_type
        // 这能正确处理 ref 对象的 scalar 字段（如 g.v 中 g 是 ref 但 v 是 i32）
        // 以及 ref 对象的 ref 字段（如 self.inner 中 self 是 ref 且 inner 也是 ref）
        const sema_ct: ?*const type_descriptor_mod.TypeDescriptor = blk: {
            { const sr = self.sema_result;
                if (sr.getExpr(@intFromPtr(field_access_expr))) |info| {
                    if (!info.type_desc.is_null_type) break :blk info.type_desc;
                }
            }
            break :blk null;
        };
        const chan_type: *const type_descriptor_mod.TypeDescriptor = blk: {
            if (sema_ct) |ct| break :blk ct;
            if (self.inferFieldType(object, field)) |ft| break :blk ft;
            if (inferred_type) |tn| {
                if (self.inferFieldTypeByCtor(tn, field)) |ft| break :blk ft;
            }
            break :blk type_descriptor_mod.i64_descriptor;
        };
        const out = try self.allocChannel(chan_type);
        try self.emit(Node.makeUnary(.record_get, out, meta_idx, obj_chan));
        return out;
    }

    /// 通过类型名查 sema_result 获取字段类型（用于 method_call 返回值等场景）
    /// newtype/ADT 的构造器名与类型名相同，sema_result 存储了字段类型信息
    pub fn inferFieldTypeByCtor(self: *IRBuilder, type_name: []const u8, field: []const u8) ?*const type_descriptor_mod.TypeDescriptor {
        const ctor = self.sema_result.getCtorDef(type_name) orelse return null;
        for (ctor.field_names, 0..) |fname, i| {
            if (fname) |fn_str| {
                if (std.mem.eql(u8, fn_str, field)) {
                    if (i < ctor.field_type_descs.len) return ctor.field_type_descs[i];
                    return null;
                }
            }
        }
        return null;
    }

    /// TypeInfo 字段名 → 通道类型（用于 typeof(TypeName).field 的字段访问）
    ///
    /// 新设计：7 个顶层字段，字段顺序与 IRBuilder.registerTypeInfoFields 和 engine.execBuiltinTypeof 一致：
    ///   0: name (str) → ref_chan
    ///   1: module (str) → ref_chan
    ///   2: kind (TypeKind，str 表示 ADT 构造器名) → ref_chan
    ///   3: structure (TypeStructure ADT) → ref_chan
    ///   4: layout (LayoutInfo) → ref_chan
    ///   5: impls (TraitImplInfo) → ref_chan
    ///   6: type_params (Array<TypeParamMeta>) → ref_chan
    /// 所有顶层字段都是引用类型（字符串或嵌套 RecordValue/Array）
    pub fn typeInfoFieldType(field: []const u8) ?*const type_descriptor_mod.TypeDescriptor {
        const ref_fields = [_][]const u8{
            "name", "module", "kind", "structure", "layout", "impls", "type_params",
        };
        for (ref_fields) |f| if (std.mem.eql(u8, field, f)) return type_descriptor_mod.ref_descriptor;
        return null;
    }

    /// 从表达式推断通道类型
    pub fn inferChanTypeFromExpr(self: *IRBuilder, expr: *const ast.Expr) ?*const type_descriptor_mod.TypeDescriptor {
        { const sr = self.sema_result;
            if (sr.getExpr(@intFromPtr(expr))) |info| {
                return info.type_desc;
            }
        }
        return null;
    }

    /// 编译索引访问：obj[index]
    /// 数组 → array_get，字符串 → string_index
    pub fn compileIndex(self: *IRBuilder, object: *ast.Expr, index: *ast.Expr) BuildError!u16 {
        const obj_chan = try self.compileExpr(object);
        const idx_chan = try self.forceLazyIfRef(try self.compileExpr(index), type_descriptor_mod.i64_descriptor);
        // 通过 AST 节点类型推断 + 参数类型标注
        const is_string = self.isStringExpr(object) or self.isStringParam(object);
        if (is_string) {
            const out = try self.allocChannel(type_descriptor_mod.char_descriptor);
            try self.emit(Node.makeBinary(.string_index, out, 0, obj_chan, idx_chan));
            return out;
        }
        // 默认数组索引：根据数组元素类型推断 out 通道类型
        const elem_type = self.inferArrayElemType(object);
        const out = try self.allocChannel(elem_type);
        try self.emit(Node.makeBinary(.array_get, out, 0, obj_chan, idx_chan));
        return out;
    }

    /// 编译切片表达式 obj[start..end] 或 obj[start..=end]
    /// 根据 object 类型分派到 array_slice 或 string_slice NodeOp
    /// inclusive=true 时 end 包含在结果中（start..=end）
    pub fn compileSlice(self: *IRBuilder, object: *ast.Expr, start: *ast.Expr, end: *ast.Expr, inclusive: bool) BuildError!u16 {
        const obj_chan = try self.compileExpr(object);
        const start_chan = try self.forceLazyIfRef(try self.compileExpr(start), type_descriptor_mod.i64_descriptor);
        const end_chan = try self.forceLazyIfRef(try self.compileExpr(end), type_descriptor_mod.i64_descriptor);
        const is_string = self.isStringExpr(object) or self.isStringParam(object);
        const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
        // 使用 _pad 字段传递 inclusive 标记（0 = exclusive, 1 = inclusive）
        var node = Node.makeTernary(
            if (is_string) .string_slice else .array_slice,
            out,
            0,
            obj_chan,
            start_chan,
            end_chan,
        );
        node._pad = if (inclusive) 1 else 0;
        try self.emit(node);
        return out;
    }

    /// 编译字符串插值："...${expr}..."
    /// → 逐段 string_concat 链
    pub fn compileStringInterpolation(self: *IRBuilder, parts: []ast.InterpolationPart) BuildError!u16 {
        if (parts.len == 0) {
            // 空插值 → 空字符串
            const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
            const str_idx = self.addString("");
            const meta_idx = try self.addScalarMeta(.{ .kind = .str, .const_val = .{ .int_val = @intCast(str_idx) } });
            try self.emit(Node.makeSink(.const_str, out, meta_idx));
            return out;
        }
        // 第一段
        var current_chan: u16 = switch (parts[0]) {
            .literal => |s| blk: {
                const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
                const str_idx = self.addString(s);
                const meta_idx = try self.addScalarMeta(.{ .kind = .str, .const_val = .{ .int_val = @intCast(str_idx) } });
                try self.emit(Node.makeSink(.const_str, out, meta_idx));
                break :blk out;
            },
            .expression => |e| try self.exprToStringChan(e),
        };
        // 后续段逐个 concat
        for (parts[1..]) |part| {
            const next_chan: u16 = switch (part) {
                .literal => |s| blk: {
                    const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
                    const str_idx = self.addString(s);
                    const meta_idx = try self.addScalarMeta(.{ .kind = .str, .const_val = .{ .int_val = @intCast(str_idx) } });
                    try self.emit(Node.makeSink(.const_str, out, meta_idx));
                    break :blk out;
                },
                .expression => |e| try self.exprToStringChan(e),
            };
            const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
            const meta_idx = try self.addScalarMeta(.{ .kind = .ref });
            try self.emit(Node.makeBinary(.string_concat, out, meta_idx, current_chan, next_chan));
            current_chan = out;
        }
        return current_chan;
    }

    /// 将表达式编译为字符串通道（非字符串表达式先 builtin_str 转换）
    pub fn exprToStringChan(self: *IRBuilder, e: *const ast.Expr) BuildError!u16 {
        const chan = try self.compileExpr(e);
        const meta = self.channels.get(chan);
        // 字符串/引用类型直接使用
        if (meta.type_desc.is_ref) return chan;
        // 其他类型通过 builtin_str 转换
        const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
        try self.emit(Node.makeUnary(.builtin_str, out, 0, chan));
        return out;
    }

    /// 发射字符串常量通道（const_str 节点）。
    /// 复用字符串字面量编译方式：addString + const_str sink 节点。
    pub fn emitStrConstant(self: *IRBuilder, s: []const u8) BuildError!u16 {
        const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
        const str_idx = self.addString(s);
        const meta_idx = try self.addScalarMeta(.{ .kind = .str, .const_val = .{ .int_val = @intCast(str_idx) } });
        try self.emit(Node.makeSink(.const_str, out, meta_idx));
        return out;
    }

    /// 发射字符串拼接 IR（string_concat 节点），返回结果通道。
    pub fn emitStrConcat(self: *IRBuilder, left: u16, right: u16) BuildError!u16 {
        const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
        const meta_idx = try self.addScalarMeta(.{ .kind = .ref });
        try self.emit(Node.makeBinary(.string_concat, out, meta_idx, left, right));
        return out;
    }

    /// 通过类型名 + 字段名生成字段访问 IR（record_get 节点）。
    /// 复用 lookupFieldId / addFieldIdMeta，与 compileFieldAccess 同机制。
    pub fn compileFieldAccessByChan(
        self: *IRBuilder,
        obj_chan: u16,
        type_name: []const u8,
        field_name: []const u8,
        field_chan_type: *const type_descriptor_mod.TypeDescriptor,
    ) BuildError!u16 {
        const field_id = self.lookupFieldId(type_name, field_name) orelse return obj_chan;
        const meta_idx = try self.addFieldIdMeta(field_id);
        const out = try self.allocChannel(field_chan_type);
        try self.emit(Node.makeUnary(.record_get, out, meta_idx, obj_chan));
        return out;
    }

    /// 编译函数调用
    pub fn compileCall(self: *IRBuilder, callee: *ast.Expr, arguments: []*ast.Expr) BuildError!u16 {
        // call_expr 传 callee 作为占位（compileCall 无调用表达式上下文，
        // 不会命中 sema call_instantiations，typeArgsFromCallExpr 返回空切片）
        return try self.compileCallWithTypeArgs(callee, arguments, null, callee);
    }

    /// typeof 参数解析为 meta_index
    ///
    /// 递归处理 propagate 节点（typeof(T?) 形式）：
    /// - identifier "TypeName" → 查 type_name_to_id / 泛型参数 / Self → type_id 或 0x8000|idx 或 0
    /// - propagate(inner) → 0x4000 | resolveTypeofMetaIndex(inner)
    ///
    /// meta_index 编码（u16）：
    /// - bit 15 (0x8000): 泛型参数哨兵
    /// - bit 14 (0x4000): nullable 包装哨兵
    /// - bit 0-13: type_id 或 param_idx
    pub fn resolveTypeofMetaIndex(self: *IRBuilder, arg: *ast.Expr) BuildError!u16 {
        switch (arg.*) {
            .propagate => |p| {
                // typeof(T?) — nullable 包装
                const inner_meta = try self.resolveTypeofMetaIndex(p.expr);
                if (inner_meta == 0) return 0; // inner 未识别，整体返回 0
                const nullable_meta: u16 = 0x4000 | inner_meta;
                return nullable_meta;
            },
            .identifier => |id| {
                const type_name = id.name;
                // 1. 具体类型：查 type_name_to_id
                if (self.type_name_to_id.get(type_name)) |tid| return tid;
                // 2. Self：在 trait default 方法中
                if (std.mem.eql(u8, type_name, "Self")) {
                    if (self.current_self_type_name) |self_name| {
                        if (self.type_name_to_id.get(self_name)) |tid| return tid;
                    }
                    return 0; // Self 未解析
                }
                // 3. 泛型参数 T
                if (self.current_func_type_params) |tps| {
                    for (tps, 0..) |tp, idx| {
                        if (std.mem.eql(u8, tp.name, type_name)) {
                            // 单态化上下文：类型参数已绑定到具体 type_id（sema instance.type_args）
                            if (idx < self.current_type_args.len) {
                                const tid = self.current_type_args[idx].type_id;
                                if (tid != 0) return tid;
                            }
                            // 非单态化：发出哨兵，运行时从 frame.type_args 查表
                            const sentinel: u16 = @intCast(0x8000 | idx);
                            return sentinel;
                        }
                    }
                }
                // 4. 未识别类型
                return 0;
            },
            else => return error.UnsupportedExpr,
        }
    }

    /// reflect(x) 参数解析为 meta_index
    ///
    /// 与 typeof 不同，reflect 接收值表达式而非类型表达式。
    /// 解析策略：
    /// 1. 若 arg 是标识符且匹配当前函数的某个参数名：
    ///    a. 检查该参数的 type_annotation，若是 `.named` 且匹配某个类型参数 T，
    ///       发射哨兵 `0x8000|param_idx`（运行时从 frame.type_args 解析）
    ///    b. 若 type_annotation 是具体类型名，查 type_name_to_id 返回 type_id
    /// 2. 其他情况：从 sema 获取实参 type_name 查表，未找到返回 0
    pub fn resolveReflectMetaIndex(self: *IRBuilder, arg: *const ast.Expr) BuildError!u16 {
        switch (arg.*) {
            .identifier => |id| {
                const var_name = id.name;
                // 在当前函数参数列表中查找同名参数
                if (self.current_func_param_types) |params| {
                    for (params) |param| {
                        if (!std.mem.eql(u8, param.name, var_name)) continue;
                        if (param.type_annotation) |ta| {
                            // 处理 ref_type/nullable 包裹（&T, T?）递归到 inner
                            const inner = switch (ta.*) {
                                .ref_type => |rt| rt.inner,
                                .nullable => |n| n.inner,
                                else => ta,
                            };
                            switch (inner.*) {
                                .named => |nm| {
                                    // 检查是否为类型参数
                                    if (self.current_func_type_params) |tps| {
                                        for (tps, 0..) |tp, tp_idx| {
                                            if (std.mem.eql(u8, tp.name, nm.name)) {
                                                // 单态化上下文：类型参数已绑定到具体 type_id（sema instance.type_args）
                                                // 直接返回具体 type_id，无需运行时哨兵查表
                                                if (tp_idx < self.current_type_args.len) {
                                                    const tid = self.current_type_args[tp_idx].type_id;
                                                    if (tid != 0) return tid;
                                                }
                                                // 非单态化：发出哨兵，运行时从 frame.type_args 查表
                                                return @intCast(0x8000 | tp_idx);
                                            }
                                        }
                                    }
                                    // 具体类型：查表
                                    if (self.type_name_to_id.get(nm.name)) |tid| return tid;
                                },
                                else => {},
                            }
                        }
                        break; // 找到参数名后停止查找
                    }
                }
                // 回退：从 sema 获取类型信息
                { const sr = self.sema_result;
                    if (sr.getExpr(@intFromPtr(arg))) |info| {
                        if (info.type_name) |tn| {
                            if (self.type_name_to_id.get(tn)) |tid| return tid;
                        }
                    }
                }
                return 0;
            },
            else => {
                // 非标识符表达式：从 sema 获取类型信息
                { const sr = self.sema_result;
                    if (sr.getExpr(@intFromPtr(arg))) |info| {
                        if (info.type_name) |tn| {
                            if (self.type_name_to_id.get(tn)) |tid| return tid;
                        }
                    }
                }
                return 0;
            },
        }
    }

    /// 编译函数调用，附带显式类型实参（来自 `func[T](args)` 形式）
    /// type_args_hint != null 时优先使用显式类型实参；否则从参数类型推断
    /// call_expr 是调用表达式本身的 AST 指针，用于查询 sema 的 call_instantiations
    pub fn compileCallWithTypeArgs(
        self: *IRBuilder,
        callee: *ast.Expr,
        arguments: []*ast.Expr,
        type_args_hint: ?[]*ast.TypeNode,
        call_expr: *const ast.Expr,
    ) BuildError!u16 {
        _ = type_args_hint; // sema 已预先收集显式类型实参，IR 直接消费 sema call_instantiations
        // 只支持直接函数名调用
        const func_name = switch (callee.*) {
            .identifier => |id| id.name,
            else => return error.UnsupportedExpr,
        };

        // 内置函数分派（注册表驱动，v3 阶段 4）
        // reflect/__scalar_to_str/type/typeof/Panic/Ok/Error/str/channel
        // 详见 src/ir/builtin_registry.zig
        if (builtin_registry.lookupBuiltin(func_name)) |entry| {
            if (entry.arg_count) |expected| {
                if (arguments.len != expected) return error.UnsupportedExpr;
            }
            const out = try self.allocChannel(entry.out_type_desc);
            // meta_idx 仅在 unary/sink 形状下有意义；sink_optional 始终用 0
            const meta_idx: u16 = switch (entry.meta_source) {
                .zero => 0,
                .reflect => try self.resolveReflectMetaIndex(arguments[0]),
                .typeof => try self.resolveTypeofMetaIndex(arguments[0]),
            };
            switch (entry.shape) {
                .unary => {
                    const arg_chan = try self.compileExpr(arguments[0]);
                    try self.emit(Node.makeUnary(entry.op, out, meta_idx, arg_chan));
                },
                .sink => {
                    try self.emit(Node.makeSink(entry.op, out, meta_idx));
                },
                .sink_optional => {
                    // Panic：0 或 1 个参数。有参数时先编译以保留副作用，再触发 panic
                    if (arguments.len > 0) {
                        _ = try self.compileExpr(arguments[0]);
                    }
                    try self.emit(Node.makeSink(entry.op, out, 0));
                },
            }
            return out;
        }

        // Syscall 调用：__ 前缀函数（如 __file_open/__instant_now_ns 等）
        // 编译为 syscall_call 节点，meta_index 索引 syscall_metas 表。
        // syscall 名字→ID 查询由 syscall 模块的 registry.lookupByName 完成（inline for，运行时 0 开销）。
        if (syscall.lookupByName(func_name)) |sid| {
            // 编译参数（最多 4 个，超出走不了 16B Node 固定布局）
            if (arguments.len > 4) return error.UnsupportedExpr;
            var arg_chans: [4]u16 = .{ 0, 0, 0, 0 };
            for (arguments, 0..) |arg, i| {
                arg_chans[i] = try self.compileExpr(arg);
            }
            const ret_chan_type = retKindToChanType(syscall.returnKind(sid));
            const meta_idx = try self.addSyscallMeta(.{
                .syscall_id = @intFromEnum(sid),
                .arg_count = @intCast(arguments.len),
                .return_type_desc = ret_chan_type,
            });
            const out = try self.allocChannel(ret_chan_type);
            try self.emit(Node{
                .op = .syscall_call,
                .input_count = @intCast(arguments.len),
                .output = out,
                .meta_index = meta_idx,
                .inputs = arg_chans,
            });
            return out;
        }

        // 构造器调用：Node(5, Leaf, Leaf) → record_make + record_set __tag + 各字段
        if (self.sema_result.getCtorDef(func_name)) |ctor| {
            return try self.compileConstructorCall(ctor, arguments);
        }

        // 短名别名解析：本地函数优先（原名在 func_table 中），否则查 symbol_alias_map 获取 mangled 名
        // import std.time.Calendar { is_leap_year } → "is_leap_year" → "std.time.Calendar.is_leap_year"
        const effective_name = if (self.func_table.contains(func_name))
            func_name
        else
            (self.symbol_alias_map.get(func_name) orelse func_name);

        // Console 函数现在调用 std.reflect.format，不再需要调用点内联。
        // println/print/eprintln/eprint 作为普通 Glue 函数编译。

        const func_idx = self.func_table.get(effective_name) orelse {
            // 不在 func_table 中：检查是否为变量（lambda 调用）
            if (self.lookupVar(func_name)) |binding| {
                // 从绑定的 type_annotation 推断闭包返回类型
                // 对于函数类型 (A) -> R，返回类型是 R，不是 ref_chan
                const ret_chan_type = blk: {
                    if (binding.type_annotation) |tn| {
                        switch (tn.*) {
                            .function => |f| break :blk self.chanTypeFromTypeNodeBound(f.return_type) orelse type_descriptor_mod.i64_descriptor,
                            else => break :blk self.chanTypeFromTypeNodeBound(tn) orelse type_descriptor_mod.i64_descriptor,
                        }
                    }
                    break :blk type_descriptor_mod.i64_descriptor;
                };
                return try self.compileCallIndirect(binding.chan, arguments, ret_chan_type);
            }
            return error.UndefinedFunction;
        };

        // 单态化：提前计算 type_args，泛型函数实例化为特化版本
        // type_args 也用于 typeof(T) 运行时查表（CallMeta.type_args）
        // sema 已预先收集所有泛型调用点，IR 直接消费 sema call_instantiations
        const type_args = try self.typeArgsFromCallExpr(call_expr);
        const mono_func_idx = if (type_args.len > 0)
            try self.instantiateFunction(effective_name, type_args)
        else
            func_idx;
        const func = self.functions.items[mono_func_idx];

        // 线性递归优化：fib(n) 等模式 → 迭代 scalar_loop（O(N) 替代 O(2^N)）
        if (self.linear_rec_map.get(effective_name)) |rec_info| {
            if (arguments.len == 1) {
                const arg_chan = try self.compileExpr(arguments[0]);
                const forced_arg = try self.forceLazyArgIfNeeded(arg_chan, func.param_channels[0]);
                return try self.compileLinearRecurrenceCall(rec_info, forced_arg);
            }
        }

        // 编译参数
        const arena_alloc = self.arena.allocator();
        var arg_chans = try arena_alloc.alloc(u16, arguments.len);
        // 读取尾位置标志（参数不在尾位置）
        const tail_call = self.in_tail_position;
        self.in_tail_position = false;
        // 获取被调用函数的参数信息（用于判断参数是否为 trait 类型）
        const func_sig = self.sema_result.getFuncSig(effective_name);
        const func_return_type = self.findFuncReturnTypeAst(effective_name);
        // 收集参数引用标记，用于运行时值语义深拷贝判定
        var arg_ref_bits: u16 = 0;
        for (arguments, 0..) |arg, i| {
            if (i >= 16) break;
            if (self.isRefExpr(arg)) {
                arg_ref_bits |= @as(u16, 1) << @intCast(i);
            }
        }
        for (arguments, 0..) |arg, i| {
            // 检查是否为模块引用且参数类型为 trait → 构造 trait 值
            if (func_sig) |sig| {
                if (i < sig.param_type_names.len) {
                    if (sig.param_type_names[i]) |tn| {
                        if (self.sema_result.getTraitDef(tn) != null) {
                            if (self.isModuleReference(arg)) |mod_ref| {
                                arg_chans[i] = try self.compileModuleTraitValue(mod_ref, tn);
                                continue;
                            }
                        }
                    }
                }
            }
            var arg_chan = try self.compileExpr(arg);
            // 严格上下文：若实参是 Lazy<T>（ref_chan）而形参通道是标量/nullable，则强制求值。
            if (i < func.param_channels.len) {
                arg_chan = try self.forceLazyArgIfNeeded(arg_chan, func.param_channels[i]);
            }
            arg_chans[i] = arg_chan;
        }

        // 部分应用：实参数量少于函数形参数量时，构造 PartialApplication
        if (arguments.len < func.param_channels.len and !func.is_async) {
            const bound_meta = try self.addPartialMeta(.{
                .func_index = mono_func_idx,
                .bound_arg_channels = arg_chans,
                .bound_arg_ref_bits = arg_ref_bits,
                .remaining_arity = @intCast(func.param_channels.len - arguments.len),
            });
            const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
            try self.emit(Node.makeSink(.partial_make, out, bound_meta));
            return out;
        }

        // async 函数：发射 orbit_async_create 返回 AsyncHandle（不自动 await）
        // 用户需显式调用 .await() 获取结果，.status() 查询状态
        if (func.is_async) {
            return try self.emitOrbitCreate(mono_func_idx, arg_chans, func, type_args);
        }

        // 普通函数：发射 call 节点
        const ret_meta = self.channels.get(func.return_channel);
        // 泛型函数：尝试从实参类型推断返回类型
        const inferred_ret_type = self.inferGenericCallReturnType(effective_name, arguments);
        const ret_chan_type = inferred_ret_type orelse ret_meta.type_desc;
        const out = if (ret_chan_type == type_descriptor_mod.nullable_descriptor)
            try self.channels.allocNullable(ret_meta.inner_type_desc orelse type_descriptor_mod.i64_descriptor)
        else
            try self.allocChannel(ret_chan_type);
        // type_args 已在单态化前计算（用于实例化 + typeof 查表）
        // 判断函数返回类型是否为引用类型，用于返回值深拷贝判定
        const ret_is_ref = blk: {
            if (func_return_type) |rtn| {
                switch (rtn.*) {
                    .ref_type, .raw_ptr => break :blk true,
                    else => {},
                }
            }
            break :blk false;
        };
        const call_meta_idx = try self.addCallMeta(.{
            .func_index = mono_func_idx,
            .arg_count = @intCast(arguments.len),
            .tail_call = tail_call,
            .memo_slot = self.tryAssignMemoSlot(effective_name, arg_chans, ret_chan_type, ret_meta.inner_type_desc orelse type_descriptor_mod.i64_descriptor),
            .type_args = type_args,
            .arg_ref_bits = arg_ref_bits,
            .ret_is_ref = ret_is_ref,
        });

        var inputs: [4]u16 = .{ 0, 0, 0, 0 };
        for (arg_chans, 0..) |ch, i| {
            if (i < 4) inputs[i] = ch;
        }
        try self.emit(Node{
            .op = .call,
            .input_count = @intCast(@min(arguments.len, 4)),
            .output = out,
            .meta_index = call_meta_idx,
            .inputs = inputs,
        });
        return out;
    }

    /// 从 sema call_instantiations 查询调用点的 type_args
    ///
    /// sema 已预先收集所有泛型调用点（collectMonomorphInstances），
    /// IR 直接消费 sema 产出，不再重复推断。
    /// 返回切片由 arena 拥有；未命中时返回空切片。
    pub fn typeArgsFromCallExpr(self: *IRBuilder, call_expr: *const ast.Expr) ![]const u16 {
        const arena_alloc = self.arena.allocator();
        if (self.sema_result.call_instantiations.get(@intFromPtr(call_expr))) |instance_id| {
            if (instance_id < self.sema_result.monomorph_instances.items.len) {
                const instance = self.sema_result.monomorph_instances.items[instance_id];
                const tds = try arena_alloc.alloc(u16, instance.type_args.len);
                for (instance.type_args, 0..) |td, i| tds[i] = td.type_id;
                return tds;
            }
        }
        return &.{};
    }

    /// 从参数类型注解匹配类型参数名，并从实参提取对应的 type_id
    /// 例如：参数注解 T，实参 typeof(Point) → name_to_typeid["T"] = Point 的 type_id
    ///
    /// 单态化上下文：当外层泛型函数被实例化时（如 println<i32>），其参数 x: T
    /// 的类型参数 T 已在 sema instance.type_args 中绑定到具体 type_id。
    /// 内层调用 format(x) 时，实参 x 的类型注解仍是 T，此时从 current_type_args
    /// 查找 T 的具体 type_id，使内层泛型函数也能正确单态化。
    pub fn matchTypeParamToTypeId(
        self: *IRBuilder,
        param_type: *ast.TypeNode,
        arg_expr: *const ast.Expr,
        name_to_typeid: *std.StringHashMap(u16),
    ) !void {
        // 实参解引用：若实参是变量绑定，则替换为其绑定的表达式
        const resolved_expr: *const ast.Expr = blk: {
            if (arg_expr.* == .identifier) {
                if (self.lookupVar(arg_expr.identifier.name)) |binding| {
                    if (binding.ast_expr) |var_expr| break :blk var_expr;
                }
            }
            break :blk arg_expr;
        };
        switch (param_type.*) {
            .named => |n| {
                if (!self.isTypeParamName(n.name)) return;
                if (name_to_typeid.contains(n.name)) return;
                // 1. 优先：实参是标识符且其类型注解是类型参数名 → 查 current_type_args
                //    场景：println<T> 内调用 format(x)，x: T，T 已绑定到具体 type_id（sema instance.type_args）
                if (arg_expr.* == .identifier) {
                    if (self.lookupVar(arg_expr.identifier.name)) |binding| {
                        if (binding.type_annotation) |ta| {
                            const eff_ta = switch (ta.*) {
                                .ref_type => |rt| rt.inner,
                                .nullable => |nb| nb.inner,
                                else => ta,
                            };
                            if (eff_ta.* == .named) {
                                // 查 current_func_type_params 找索引，再查 current_type_args
                                if (self.current_func_type_params) |tps| {
                                    for (tps, 0..) |tp, tp_idx| {
                                        if (std.mem.eql(u8, tp.name, eff_ta.named.name)) {
                                            if (tp_idx < self.current_type_args.len) {
                                                const tid = self.current_type_args[tp_idx].type_id;
                                                if (tid != 0) {
                                                    try name_to_typeid.put(n.name, tid);
                                                    return;
                                                }
                                            }
                                            break;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                // 2. 从实参推导 type_id（先试类型名，再试 sema chan_type 反查）
                const tid = self.inferTypeIdFromExpr(resolved_expr);
                if (tid != 0) {
                    try name_to_typeid.put(n.name, tid);
                }
            },
            .generic => |g| {
                // 泛型类型如 Box<T>：从构造器调用参数递归推断 T 的具体类型
                // 例如：参数类型 Box<T>，实参 Box(Point(1, 2))
                // → 查 Box 的字段定义（value: T），用第 0 个实参 Point(1, 2) 递归匹配 T
                if (resolved_expr.* == .call) {
                    if (resolved_expr.call.callee.* == .identifier) {
                        const ctor_name = resolved_expr.call.callee.identifier.name;
                        if (self.sema_result.getCtorDef(ctor_name)) |ctor| {
                            // 1. 优先：GADT 构造器，从 return_type 显式提取具体类型
                            //    return_type_name 只是基类名，需 sema_result 获取完整 TypeNode
                            if (ctor.return_type_name != null) {
                                if (self.getCtorAstReturnType(ctor_name)) |rt| {
                                    if (rt.* == .generic and rt.generic.args.len > 0) {
                                        for (g.args, 0..) |param_arg, idx| {
                                            if (param_arg.* != .named) continue;
                                            if (!self.isTypeParamName(param_arg.named.name)) continue;
                                            if (idx >= rt.generic.args.len) continue;
                                            const concrete_name = typeNameFromTypeNodeConst(rt.generic.args[idx]);
                                            const tid = self.lookupTypeId(concrete_name);
                                            if (tid != 0) {
                                                try name_to_typeid.put(param_arg.named.name, tid);
                                            }
                                        }
                                    }
                                }
                            }
                            // 2. 通用：递归匹配构造器字段类型与构造器实参
                            //    Box<T> 的字段 value: T，实参 arg → 递归匹配 T 与 arg
                            const ctor_args = resolved_expr.call.arguments;
                            const field_count = @min(ctor.field_type_descs.len, ctor_args.len);
                            for (0..field_count) |fi| {
                                if (self.getCtorAstFieldTypeNode(ctor_name, fi)) |ftn| {
                                    try self.matchTypeParamToTypeId(ftn, ctor_args[fi], name_to_typeid);
                                }
                            }
                        }
                    }
                }
            },
            .nullable => |nb| try self.matchTypeParamToTypeId(nb.inner, resolved_expr, name_to_typeid),
            else => {},
        }
    }

    /// 判断通道类型是否为标量（无堆指针，可安全作为 memo key/val）
    /// 标量：整数、浮点、布尔、字符。排除 ref/nullable/null/unit（后者无信息量或含堆指针）
    pub fn isScalarChanType(ct: *const type_descriptor_mod.TypeDescriptor) bool {
        return ct.isInt() or ct.isFloat() or
            ct == type_descriptor_mod.bool_descriptor or ct == type_descriptor_mod.char_descriptor or
            ct == type_descriptor_mod.mask_descriptor;
    }

    /// 可 memoize 的通道类型：标量 + nullable_chan
    /// 排除 ref_chan（指针哈希命中率低，deepCopy 返回值开销巨大）
    /// 排除 unit_chan/null_chan（无数据）和 mask_chan（内部状态）
    /// nullable_chan 仅当 inner_type 为标量时才有效（Engine 层处理）
    pub fn isMemoizableChanType(ct: *const type_descriptor_mod.TypeDescriptor) bool {
        return ct.isInt() or ct.isFloat() or
            ct == type_descriptor_mod.bool_descriptor or ct == type_descriptor_mod.char_descriptor or
            ct == type_descriptor_mod.mask_descriptor or
            ct == type_descriptor_mod.nullable_descriptor;
    }

    /// 尝试为纯函数分配 memo_slot。
    /// 条件：purity_db 可用 + 函数为 pure + 所有实参通道为标量 + 返回类型为标量。
    /// 同一函数名复用同一 slot（per-function memo，非 per-call-site）。
    /// 返回 0 表示不可 memoize，>0 表示 slot 索引。
    pub fn tryAssignMemoSlot(self: *IRBuilder, func_name: []const u8, arg_chans: []const u16, ret_chan_type: *const type_descriptor_mod.TypeDescriptor, ret_inner_type: *const type_descriptor_mod.TypeDescriptor) u16 {
        const pdb = self.purity_db orelse return 0;
        if (!pdb.isPure(func_name)) return 0;
        // 仅对递归函数启用 memoization
        // 非递归纯函数的参数通常每次不同，哈希开销 > 收益
        if (!pdb.isRecursive(func_name)) return 0;
        // 返回类型必须为可 memoize 类型（标量/nullable<标量>）
        if (!isMemoizableChanType(ret_chan_type)) return 0;
        // nullable 返回的 inner_type 必须为标量（排除 nullable<ref>）
        if (ret_chan_type == type_descriptor_mod.nullable_descriptor and !isScalarChanType(ret_inner_type)) return 0;
        // 所有实参通道必须为可 memoize 类型
        for (arg_chans) |ch| {
            const meta = self.channels.get(ch);
            if (!isMemoizableChanType(meta.type_desc)) return 0;
            // nullable 的 inner_type 必须为标量（排除 nullable<ref>）
            if (meta.type_desc.is_nullable and !isScalarChanType(meta.inner_type_desc orelse type_descriptor_mod.i64_descriptor)) return 0;
        }
        // per-function memo_slot：同函数名复用同一 slot
        if (self.func_memo_slots.get(func_name)) |slot| return slot;
        const slot = self.memo_slot_counter;
        self.memo_slot_counter += 1;
        // hashmap 内部存储用 self.allocator（与 deinit 一致）
        self.func_memo_slots.put(self.allocator, func_name, slot) catch return 0;
        return slot;
    }

    /// 推断表达式的通道类型（用于泛型类型参数推断）
    /// 优先查 sema 权威数据（current_instance.expr_types 或 sema_result.expr_types），
    /// 未命中时调用 sema.inference.inferExprChanType（覆盖字面量/binary/identifier/普通函数调用）。
    /// ctor 调用的 GADT 推断通过 GadtContext 委托 sema.inference.inferConstructorChanType
    /// （gadt_binding_stack 通过 GadtContext.binding_stack 传入 sema）。
    pub fn inferExprChanType(self: *IRBuilder, expr: *const ast.Expr) ?*const type_descriptor_mod.TypeDescriptor {
        // 1. 优先查 sema instance.expr_types（当前单态化实例的局部类型表）
        if (self.current_instance) |inst| {
            if (inst.expr_types.get(@intFromPtr(expr))) |info| {
                return info.type_desc;
            }
        }
        // 2. 查 sema_result.expr_types（全局表达式类型表，由 populate 填充）
        if (self.sema_result.getExpr(@intFromPtr(expr))) |info| {
            return info.type_desc;
        }
        // 3. 调用 sema.inference.inferExprChanType（完整版，含字面量/binary/identifier/普通函数调用）
        var ctx_opt = self.inferContext();
        if (ctx_opt) |*base_ctx| {
            var ext = self.inferContextExt(base_ctx);
            if (sema_inference.inferExprChanType(&ext, expr)) |ct| return ct;
        }
        // 4. ctor 调用的 GADT 推断回退（通过 GadtContext 委托 sema.inference.inferConstructorChanType）
        // sema 侧的 inferExprChanType（InferContextExt 版本）不处理 ctor GADT 推断，
        // 因为 GADT 推断需要 GadtContext（含 gadt_binding_stack 和 infer_expr_fn 回调）
        switch (expr.*) {
            .call => |c| {
                const func_name = switch (c.callee.*) {
                    .identifier => |id| id.name,
                    else => return null,
                };
                if (self.sema_result.getCtorDef(func_name)) |ctor| {
                    return self.inferConstructorChanType(ctor, c.arguments);
                }
            },
            else => {},
        }
        return null;
    }

    /// 检查类型节点是否包含类型参数（单字母大写名）
    pub fn typeNodeHasTypeParam(type_node: *ast.TypeNode) bool {
        return switch (type_node.*) {
            .named => |n| isTypeNameParam(n.name),
            .generic => |g| {
                for (g.args) |arg| {
                    if (typeNodeHasTypeParam(arg)) return true;
                }
                return false;
            },
            .nullable => |nb| typeNodeHasTypeParam(nb.inner),
            else => false,
        };
    }

    /// 检查名称是否为类型参数（单字母大写名或 T1, T2 等）
    pub fn isTypeNameParam(name: []const u8) bool {
        if (name.len == 1 and name[0] >= 'A' and name[0] <= 'Z') return true;
        if (name.len == 2 and name[0] >= 'A' and name[0] <= 'Z' and (name[1] >= '0' and name[1] <= '9')) return true;
        return false;
    }

    /// 推断构造器调用的通道类型（含 GADT 类型参数推断）
    /// 对于 If(Expr<bool>, Expr<T>, Expr<T>) : Expr<T>，
    /// 当实参为 (BoolLit, IntLit, IntLit) 时，T=i32，返回 Expr<i32> 的通道类型
    /// 已迁移至 sema.inference.inferConstructorChanType（通过 GadtContext）
    pub fn inferConstructorChanType(self: *IRBuilder, ctor: CtorDefInfo, arguments: []*ast.Expr) ?*const type_descriptor_mod.TypeDescriptor {
        var ctx = self.gadtContext();
        ctx.infer_expr_ctx = @ptrCast(self);
        ctx.infer_expr_fn = inferExprChanTypeAdapter;
        return sema_inference.inferConstructorChanType(&ctx, ctor, arguments);
    }

    /// 使用 GADT 绑定栈解析类型节点的通道类型
    /// 已迁移至 sema.inference.resolveFieldTypeWithBindings（通过 GadtContext）
    pub fn resolveFieldTypeWithBindings(self: *IRBuilder, type_node: ?*ast.TypeNode) *const type_descriptor_mod.TypeDescriptor {
        const ctx = self.gadtContext();
        return sema_inference.resolveFieldTypeWithBindings(&ctx, type_node);
    }

    /// 从 AST 类型节点 + 泛型绑定映射推导通道类型
    /// 已迁移至 sema.inference.chanTypeWithTypeNode（通过 GadtContext）
    pub fn chanTypeWithTypeNode(self: *IRBuilder, type_node: ?*ast.TypeNode, type_bindings: std.StringHashMap(*const type_descriptor_mod.TypeDescriptor)) ?*const type_descriptor_mod.TypeDescriptor {
        const ctx = self.gadtContext();
        return sema_inference.chanTypeWithTypeNode(&ctx, type_node, type_bindings);
    }

    /// 推断泛型函数调用的返回通道类型
    /// 已迁移至 sema.inference.inferGenericCallReturnType（通过 GadtContext）
    pub fn inferGenericCallReturnType(self: *IRBuilder, func_name: []const u8, arguments: []*ast.Expr) ?*const type_descriptor_mod.TypeDescriptor {
        var ctx = self.gadtContext();
        ctx.infer_expr_ctx = @ptrCast(self);
        ctx.infer_expr_fn = inferExprChanTypeAdapter;
        return sema_inference.inferGenericCallReturnType(&ctx, func_name, arguments);
    }

    /// 递归匹配类型参数绑定
    /// 已迁移至 sema.inference.matchTypeParamBinding（通过 GadtContext）
    pub fn matchTypeParamBinding(self: *IRBuilder, param_type: *ast.TypeNode, arg_type: *const type_descriptor_mod.TypeDescriptor, bindings: *std.StringHashMap(*const type_descriptor_mod.TypeDescriptor)) void {
        const ctx = self.gadtContext();
        sema_inference.matchTypeParamBinding(&ctx, param_type, arg_type, bindings);
    }

    /// 检查名称是否为类型参数（委托给 isTypeNameParam）
    pub fn isTypeParamName(self: *IRBuilder, name: []const u8) bool {
        _ = self;
        return isTypeNameParam(name);
    }

    /// 从构造器调用表达式或带类型注解的标识符提取 GADT 类型参数绑定
    /// 已迁移至 sema.inference.extractCtorTypeBinding（通过 GadtContext）
    pub fn extractCtorTypeBinding(self: *IRBuilder, expr: *const ast.Expr, param_type: ?*ast.TypeNode, bindings: *std.StringHashMap(*const type_descriptor_mod.TypeDescriptor)) void {
        var ctx = self.gadtContext();
        ctx.infer_expr_ctx = @ptrCast(self);
        ctx.infer_expr_fn = inferExprChanTypeAdapter;
        sema_inference.extractCtorTypeBinding(&ctx, expr, param_type, bindings);
    }

    /// 编译构造器调用：Ctor(args...) → record_make(type_name, field_count=N+1) + record_set(__tag=0, tag) + record_set(field_id=i+1, val)...
    /// ADT 值用 record 表示，__tag 字段（field_id=0）存储构造器索引（用于 match 分派）
    pub fn compileConstructorCall(self: *IRBuilder, ctor: CtorDefInfo, arguments: []*ast.Expr) BuildError!u16 {
        // 构造器参数不在尾位置：防止参数中的函数调用被错误标记为 tail_call
        // （如 BNode(n, bstInsert(lo, v), hi) 中的 bstInsert 不是尾调用）
        const saved_tail = self.in_tail_position;
        self.in_tail_position = false;
        defer self.in_tail_position = saved_tail;

        // Newtype 构造器：在无 sema 时仍用 record 表示（保持字段访问兼容性）
        // 当 sema 接入后，可改用 newtype_wrap 节点
        const rec_chan = try self.allocChannel(type_descriptor_mod.ref_descriptor);
        // record_make：field_count = __tag(1) + 构造器字段数
        const field_count: u32 = @intCast(ctor.field_type_descs.len + 1);
        // 计算字段引用标记位图（field_id=0 是 __tag，固定非引用；构造器字段从 1 开始）
        var field_ref_bits: u64 = 0;
        const arg_count = @min(arguments.len, ctor.field_type_descs.len);
        for (0..arg_count) |i| {
            if (self.isRefExpr(arguments[i])) {
                const field_id = i + 1;
                if (field_id < 64) {
                    field_ref_bits |= @as(u64, 1) << @intCast(field_id);
                }
            }
        }
        const make_meta = try self.addRecordMakeMeta(ctor.type_name, field_count, field_ref_bits);
        try self.emit(Node.makeSink(.record_make, rec_chan, make_meta));

        // 设置 __tag 字段（field_id=0，构造器索引，用于 match 分派）
        const tag_chan = try self.allocChannel(type_descriptor_mod.i64_descriptor);
        const ctor_tag = self.getCtorTag(ctor.name) orelse 0;
        const tag_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = @intCast(ctor_tag) } });
        try self.emit(Node.makeSink(.const_i, tag_chan, tag_meta));
        const tag_field_meta = try self.addFieldIdMeta(0);
        try self.emit(Node.makeBinary(.record_set, rec_chan, tag_field_meta, rec_chan, tag_chan));

        // 设置各字段（field_id = i+1，因为 0 是 __tag）
        for (0..arg_count) |i| {
            var val_chan = try self.compileExpr(arguments[i]);
            const field_ct = ctor.field_type_descs[i];
            // 标量字段类型与实参通道类型不匹配时插入 cast（如整数字面量 2 → f64 字段）
            // 避免 i32 字节直接写入 f64 字段位置导致运行时读取错误值
            const arg_ct = self.channels.get(val_chan).type_desc;
            const need_cast = (arg_ct != field_ct) and
                (field_ct.isInt() or field_ct.isFloat()) and
                (arg_ct.isInt() or arg_ct.isFloat() or arg_ct == type_descriptor_mod.bool_descriptor);
            if (need_cast) {
                val_chan = try self.emitScalarCast(val_chan, field_ct);
            }
            const field_meta = try self.addFieldIdMeta(@intCast(i + 1));
            try self.emit(Node.makeBinary(.record_set, rec_chan, field_meta, rec_chan, val_chan));
        }
        return rec_chan;
    }

    /// 发射 orbit_async_create 节点：创建异步轨道，返回 handle 通道
    pub fn emitOrbitCreate(self: *IRBuilder, func_idx: u16, arg_chans: []const u16, func: Function, type_args: []const u16) BuildError!u16 {
        // handle 通道：ref_chan 存储轨道句柄
        const handle_chan = try self.allocChannel(type_descriptor_mod.ref_descriptor);
        const result_type = self.channels.get(func.return_channel).type_desc;

        // 从形参通道提取引用位图：第 i 位为 1 表示形参 i 为 &T / *T（引用语义）
        var arg_ref_bits: u8 = 0;
        for (func.param_channels, 0..) |pc, i| {
            if (i >= 8) break;
            if (self.channels.get(pc).type_desc.is_ref) {
                arg_ref_bits |= @as(u8, 1) << @intCast(i);
            }
        }

        const orbit_meta_idx = try self.addOrbitMeta(.{
            .func_index = func_idx,
            .arg_count = @intCast(arg_chans.len),
            .result_type_desc = result_type,
            .is_spawn = false,
            .arg_ref_bits = arg_ref_bits,
            .type_args = type_args,
        });

        var inputs: [4]u16 = .{ 0, 0, 0, 0 };
        for (arg_chans, 0..) |ch, i| {
            if (i < 4) inputs[i] = ch;
        }
        try self.emit(Node{
            .op = .orbit_async_create,
            .input_count = @intCast(@min(arg_chans.len, 4)),
            .output = handle_chan,
            .meta_index = orbit_meta_idx,
            .inputs = inputs,
        });
        // 记录 handle_chan → orbit_meta_idx 映射，供 await 查询 result_type
        self.async_handle_meta.put(handle_chan, orbit_meta_idx) catch return error.OutOfMemory;
        return handle_chan;
    }

    /// 编译 iterable 表达式为 vec_source 节点
    pub fn compileVecSource(self: *IRBuilder, iterable: *ast.Expr) BuildError!u16 {
        switch (iterable.*) {
            .binary => |b| {
                if (b.op == .range or b.op == .range_inclusive) {
                    // range 表达式：start..end 或 start..=end
                    const start_chan = try self.compileExpr(b.left);
                    const end_chan = try self.compileExpr(b.right);

                    // 尝试从常量推导长度
                    var length: ?u32 = null;
                    const start_meta = self.channels.get(start_chan);
                    if (start_meta.type_desc.isInt()) {
                        // 查找常量值
                        if (self.findConstVal(start_chan)) |sv| {
                            if (self.findConstVal(end_chan)) |ev| {
                                const s_val: i64 = @intCast(sv);
                                const e_val: i64 = @intCast(ev);
                                const len: i64 = if (b.op == .range_inclusive) e_val - s_val + 1 else e_val - s_val;
                                if (len >= 0) length = @intCast(len);
                            }
                        }
                    }

                    const elem_type = self.channels.get(start_chan).type_desc;
                    const meta_idx = try self.addVectorMeta(.{
                        .vec_op = .range_source,
                        .length = length,
                        .elem_type_desc = elem_type,
                    });

                    const out = try self.allocChannel(elem_type);
                    var vs_node = Node.makeBinary(.vec_source, out, meta_idx, start_chan, end_chan);
                    // _pad=1 标记 inclusive range（..=），engine 据此 count = end - start + 1
                    vs_node._pad = if (b.op == .range_inclusive) 1 else 0;
                    try self.emit(vs_node);
                    return out;
                }
                if (b.op == .concat_list) {
                    // a ++ b：编译为 array_concat，得到 ref_chan，再 vec_source(array_source)
                    const ref_chan = try self.compileExpr(iterable);
                    const elem_type = self.inferArrayElemType(iterable);
                    return try self.emitArraySource(ref_chan, null, elem_type);
                }
                return error.UnsupportedExpr;
            },
            .array_literal => {
                // 数组字面量：先编译为 array_make（返回 ref_chan），再 vec_source(array_source)
                const arr_chan = try self.compileExpr(iterable);
                const length: ?u32 = null; // 长度由运行时从 ArrayValue 读取
                // 从字面量第一个元素推断元素类型
                const elem_type = sema_inference.inferArrayLiteralElemType(iterable);
                return try self.emitArraySource(arr_chan, length, elem_type);
            },
            .string_literal => {
                // 字符串字面量 → vec_source(string_source)，迭代 Unicode 标量值
                const str_chan = try self.compileExpr(iterable);
                const meta_idx = try self.addVectorMeta(.{
                    .vec_op = .string_source,
                    .elem_type_desc = type_descriptor_mod.char_descriptor,
                });
                const out = try self.allocChannel(type_descriptor_mod.char_descriptor);
                try self.emit(Node.makeUnary(.vec_source, out, meta_idx, str_chan));
                return out;
            },
            .identifier, .call, .method_call, .index, .field_access => {
                // 检查是否为字符串表达式 → string_source（迭代 Unicode 标量值）
                if (self.isStringExpr(iterable) or self.isStringParam(iterable)) {
                    const str_chan = try self.compileExpr(iterable);
                    const meta_idx = try self.addVectorMeta(.{
                        .vec_op = .string_source,
                        .elem_type_desc = type_descriptor_mod.char_descriptor,
                    });
                    const out = try self.allocChannel(type_descriptor_mod.char_descriptor);
                    try self.emit(Node.makeUnary(.vec_source, out, meta_idx, str_chan));
                    return out;
                }
                // 标识符/调用/方法调用/索引/字段访问：编译为 ref_chan，再 vec_source(array_source)
                const ref_chan = try self.compileExpr(iterable);
                // 推断数组元素类型（如 s.bytes() → u8_chan）
                const elem_type = self.inferArrayElemType(iterable);
                return try self.emitArraySource(ref_chan, null, elem_type);
            },
            else => return error.UnsupportedExpr,
        }
    }

    /// 发射 array_source vec_source 节点
    /// inputs[0] = arr_chan（ref_chan 指向 ArrayValue）
    /// elem_type 为编译期推断的元素通道类型（无法精确推断时回退 i64_chan）
    pub fn emitArraySource(self: *IRBuilder, arr_chan: u16, length: ?u32, elem_type: *const type_descriptor_mod.TypeDescriptor) BuildError!u16 {
        const meta_idx = try self.addVectorMeta(.{
            .vec_op = .array_source,
            .length = length,
            .elem_type_desc = elem_type,
        });
        const out = try self.allocChannel(elem_type);
        try self.emit(Node.makeUnary(.vec_source, out, meta_idx, arr_chan));
        return out;
    }

    /// 从数组表达式推断元素通道类型
    /// 支持 method_call（如 s.bytes() → u8_chan）、identifier（从 var 类型推断）、array_literal、binary.concat_list、field_access
    /// 已委托到 sema.inference.inferArrayElemType（消除双轨制）
    pub const inferArrayElemType = builder_mod.IRBuilder.inferArrayElemType;

    /// 从 AST 表达式粗略推断通道类型（用于数组元素类型推断）
    /// 已迁移至 sema/inference.zig（消除双轨制），此处通过 builder.zig 别名复用

    /// 从通道查找编译期常量值
    pub fn findConstVal(self: *IRBuilder, chan: u16) ?i128 {
        // 遍历节点流，找到 output == chan 的 const_i 节点
        for (self.nodes.items) |n| {
            if (n.output == chan and n.op == .const_i) {
                if (n.meta_index > 0 and n.meta_index < self.scalar_metas.items.len) {
                    const meta = self.scalar_metas.items[n.meta_index];
                    if (meta.const_val) |cv| {
                        return switch (cv) {
                            .int_val => |v| v,
                            else => null,
                        };
                    }
                }
            }
        }
        return null;
    }

    /// 编译归约表达式（vec_fold）
    /// 用于 sum(range) / max(range) / min(range) 等场景
    pub fn compileFold(
        self: *IRBuilder,
        fold_op: NodeOp,
        init_chan: u16,
        src_vec_chan: u16,
    ) BuildError!u16 {
        const elem_type = self.channels.get(src_vec_chan).type_desc;
        const meta_idx = try self.addVectorMeta(.{
            .inner_op = fold_op,
            .elem_type_desc = elem_type,
        });

        const out = try self.allocChannel(elem_type);
        // vec_fold 是二元节点：inputs[0] = src_vec, inputs[1] = init_val
        const inputs: [4]u16 = .{ src_vec_chan, init_chan, 0, 0 };
        try self.emit(Node{
            .op = .vec_fold,
            .input_count = 2,
            .output = out,
            .meta_index = meta_idx,
            .inputs = inputs,
        });
        return out;
    }

    /// 编译前缀计算（vec_scan）
    /// 用于递归线性化：fib(n) → scan(step, (0,1)) |> take(n) |> last
    pub fn compileScan(
        self: *IRBuilder,
        scan_op: NodeOp,
        init_chan: u16,
        src_vec_chan: u16,
    ) BuildError!u16 {
        const elem_type = self.channels.get(src_vec_chan).type_desc;
        const meta_idx = try self.addVectorMeta(.{
            .inner_op = scan_op,
            .elem_type_desc = elem_type,
        });

        const out = try self.allocChannel(elem_type);
        const inputs: [4]u16 = .{ src_vec_chan, init_chan, 0, 0 };
        try self.emit(Node{
            .op = .vec_scan,
            .input_count = 2,
            .output = out,
            .meta_index = meta_idx,
            .inputs = inputs,
        });
        return out;
    }

    /// 编译 ? 传播表达式
    ///
    /// expr? 编译为门控节点链：
    ///   N0: ch_val = <expr>
    ///   N1: ch_ok = gate_check(ch_val)       // 检查 is_ok
    ///   N2: ch_inner = gate_get_ok(ch_val)   // 提取 Ok 值
    ///
    /// 后续 ? 点的 gate_propagate 会 OR 传播错误掩码。
    /// gate_select 在链尾按 mask 选择最终结果。
    pub fn compilePropagate(self: *IRBuilder, inner_expr: *ast.Expr) BuildError!u16 {
        // 编译内部表达式
        const val_chan = try self.compileExpr(inner_expr);
        const val_meta = self.channels.get(val_chan);

        // null_literal 传播：a? 返回 null → 传播 null（返回零值通道）
        if (val_meta.type_desc.is_null_type) {
            // null 传播：返回一个零值通道（后续使用时会有问题，但 ?? 会短路）
            // 简化：直接返回 null_chan，由调用方处理
            return val_chan;
        }

        // nullable 传播：a? — unwrap nullable，null 时返回零值（简化：不做短路返回）
        if (val_meta.type_desc.is_nullable) {
            const inner_type = val_meta.inner_type_desc orelse type_descriptor_mod.i64_descriptor;
            const unwrapped_chan = try self.allocChannel(inner_type);
            try self.emit(Node.makeUnary(.nullable_unwrap, unwrapped_chan, 0, val_chan));
            return unwrapped_chan;
        }

        // Throw 传播：a? — 检查 is_ok，is_err 时函数返回 error，is_ok 时提取 Ok 值
        // 推断 inner_expr 的 Throw Ok 类型，避免使用 current_throw_ok_type_desc（当前函数返回类型）
        // 当 ? 应用于其他函数返回值时，Ok 类型可能不同
        const inferred_ok = self.inferThrowOkChanType(inner_expr);
        const ok_val_type = inferred_ok orelse self.current_throw_ok_type_desc;

        // gate_check：检查 is_ok，输出 mask_chan
        const check_meta_idx = try self.addGateMeta(.{
            .gate_kind = .check,
            .error_type = 0,
        });
        const ok_chan = try self.allocChannel(type_descriptor_mod.mask_descriptor);
        try self.emit(Node.makeUnary(.gate_check, ok_chan, check_meta_idx, val_chan));

        // 使用 route_dispatch 实现短路：Err → halt_return，Ok → gate_get_ok
        const ret_chan = self.current_return_chan orelse {
            // 无返回通道（不应在 Throw 返回函数中出现）：退化为不短路
            const get_ok_meta_idx_fallback = try self.addGateMeta(.{ .gate_kind = .get_ok });
            const inner_chan_fb = try self.allocChannel(ok_val_type);
            try self.emit(Node.makeUnary(.gate_get_ok, inner_chan_fb, get_ok_meta_idx_fallback, val_chan));
            return inner_chan_fb;
        };

        // cast bool → i64 (true=1=Ok→arm1, false=0=Err→arm0)
        const winner_chan = try self.allocChannel(type_descriptor_mod.i64_descriptor);
        const cast_meta_idx = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64 });
        try self.emit(Node.makeUnary(.cast, winner_chan, cast_meta_idx, ok_chan));

        // arm 0 = Err: halt_return with original ThrowValue（传播错误）
        const err_arm_start: u32 = @intCast(self.nodes.items.len);
        try self.emit(Node.makeUnary(.halt_return, ret_chan, 0, val_chan));
        const err_arm_len: u32 = @intCast(self.nodes.items.len - err_arm_start);

        // arm 1 = Ok: gate_get_ok（提取 Ok 值）
        const ok_arm_start: u32 = @intCast(self.nodes.items.len);
        const get_ok_meta_idx = try self.addGateMeta(.{ .gate_kind = .get_ok });
        const inner_chan = try self.allocChannel(ok_val_type);
        try self.emit(Node.makeUnary(.gate_get_ok, inner_chan, get_ok_meta_idx, val_chan));
        const ok_arm_len: u32 = @intCast(self.nodes.items.len - ok_arm_start);

        // route_dispatch 按 winner 索引执行对应子图
        const arena_alloc = self.arena.allocator();
        const body_starts = try arena_alloc.alloc(u32, 2);
        const body_lens = try arena_alloc.alloc(u32, 2);
        body_starts[0] = err_arm_start;
        body_lens[0] = err_arm_len;
        body_starts[1] = ok_arm_start;
        body_lens[1] = ok_arm_len;

        const result_chan = try self.allocChannel(ok_val_type);
        const route_meta_idx = try self.addRouteMeta(.{
            .trait_id = 0,
            .method_id = 0,
            .target_count = 2,
            .body_starts = body_starts,
            .body_lens = body_lens,
        });
        try self.emit(Node.makeUnary(.route_dispatch, result_chan, route_meta_idx, winner_chan));
        return result_chan;
    }

    /// 编译 non_null_assert (expr!)：断言 nullable 非 null，提取内部值
    /// 等价于 nullable_unwrap，null 时 panic
    pub fn compileNonNullAssert(self: *IRBuilder, expr: *const ast.Expr) BuildError!u16 {
        const src_chan = try self.compileExpr(expr);
        const src_meta = self.channels.get(src_chan);

        // 如果已经是 nullable_chan，直接 unwrap
        if (src_meta.type_desc.is_nullable) {
            const out = try self.allocChannel(src_meta.inner_type_desc orelse type_descriptor_mod.i64_descriptor);
            try self.emit(Node.makeUnary(.nullable_unwrap, out, 0, src_chan));
            return out;
        }

        // 如果是 ref_chan，包装为 nullable 后 unwrap（null 时 panic）
        if (src_meta.type_desc.is_ref) {
            const nullable_chan = try self.channels.allocNullable(type_descriptor_mod.ref_descriptor);
            try self.emit(Node.makeUnary(.nullable_make, nullable_chan, 0, src_chan));
            const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
            try self.emit(Node.makeUnary(.nullable_unwrap, out, 0, nullable_chan));
            return out;
        }

        // 其他类型：直接传递（不可能为 null）
        return src_chan;
    }

    /// 编译 safe_access (obj?.field)：null 时返回 null，否则访问字段
    pub fn compileSafeAccess(self: *IRBuilder, object: *const ast.Expr, field: []const u8, safe_access_expr: *const ast.Expr) BuildError!u16 {
        const obj_chan = try self.compileExpr(object);
        const obj_meta = self.channels.get(obj_chan);

        // 从 sema 查询 safe_access 表达式的字段类型
        // safe_access 的 chan_type 是 nullable_chan，inner_type 是字段的实际类型
        const sema_field_ct: ?*const type_descriptor_mod.TypeDescriptor = blk: {
            { const sr = self.sema_result;
                if (sr.getExpr(@intFromPtr(safe_access_expr))) |info| {
                    if (info.type_desc.is_nullable and info.inner_type_desc != null) {
                        break :blk info.inner_type_desc.?;
                    }
                    if (info.type_desc != type_descriptor_mod.null_descriptor and !info.type_desc.is_nullable) {
                        break :blk info.type_desc;
                    }
                }
            }
            break :blk null;
        };

        // null_literal：直接返回 null_chan（结果确定为 null）
        if (obj_meta.type_desc.is_null_type) {
            const null_result = try self.allocChannel(type_descriptor_mod.null_descriptor);
            try self.emit(Node.makeSink(.const_null, null_result, 0));
            return null_result;
        }

        // 如果是 ref_chan，先包装为 nullable
        const nullable_chan = if (obj_meta.type_desc.is_nullable)
            obj_chan
        else if (obj_meta.type_desc.is_ref) blk: {
            const nc = try self.channels.allocNullable(type_descriptor_mod.ref_descriptor);
            try self.emit(Node.makeUnary(.nullable_make, nc, 0, obj_chan));
            break :blk nc;
        } else obj_chan;

        // 如果不是 nullable（例如基本类型），直接做字段访问
        if (!obj_meta.type_desc.is_nullable and !obj_meta.type_desc.is_ref and !obj_meta.type_desc.is_null_type) {
            return self.compileFieldAccessOnChan(obj_chan, field, object, sema_field_ct);
        }

        // 检查是否为 null
        const is_null_chan = try self.allocChannel(type_descriptor_mod.bool_descriptor);
        try self.emit(Node.makeUnary(.nullable_is_null, is_null_chan, 0, nullable_chan));

        // unwrap 后访问字段（null 时 unwrap 写零，record_get 需安全处理）
        const inner_type = if (obj_meta.type_desc.is_nullable) (obj_meta.inner_type_desc orelse type_descriptor_mod.i64_descriptor) else obj_meta.type_desc;
        const unwrapped_chan = try self.allocChannel(inner_type);
        try self.emit(Node.makeUnary(.nullable_unwrap, unwrapped_chan, 0, nullable_chan));

        // 在 unwrapped 上做字段访问
        const field_chan = self.compileFieldAccessOnChan(unwrapped_chan, field, object, sema_field_ct);
        const field_meta = self.channels.get(field_chan);
        const field_ct = field_meta.type_desc;

        // 结果为 nullable<field_type>
        const result_chan = try self.channels.allocNullable(field_ct);

        // null 分支：nullable_make(null_chan) → null flag = 1
        const null_input = try self.allocChannel(type_descriptor_mod.null_descriptor);
        try self.emit(Node.makeSink(.const_null, null_input, 0));
        const null_nullable_chan = try self.channels.allocNullable(field_ct);
        try self.emit(Node.makeUnary(.nullable_make, null_nullable_chan, 0, null_input));

        // field 分支：nullable_make(field_chan) → null flag = 0
        const field_nullable_chan = try self.channels.allocNullable(field_ct);
        try self.emit(Node.makeUnary(.nullable_make, field_nullable_chan, 0, field_chan));

        // vec_select: inputs[0]=then_val(cond=true→is_null→null), inputs[1]=else_val(cond=false→not null→field), inputs[2]=cond
        const sel_inputs: [4]u16 = .{ null_nullable_chan, field_nullable_chan, is_null_chan, 0 };
        try self.emit(Node{
            .op = .vec_select,
            .input_count = 3,
            .output = result_chan,
            .meta_index = 0,
            .inputs = sel_inputs,
        });

        return result_chan;
    }

    /// 在已有通道上编译字段访问（复用 record_get 逻辑）
    pub fn compileFieldAccessOnChan(self: *IRBuilder, obj_chan: u16, field: []const u8, object: *const ast.Expr, sema_chan_type: ?*const type_descriptor_mod.TypeDescriptor) u16 {
        // 解析 field_id（与 compileFieldAccess 相同逻辑）
        const field_id: u16 = blk: {
            if (std.mem.eql(u8, field, "__tag")) break :blk 0;
            if (self.inferTypeNameFromExpr(object)) |type_name| {
                if (self.lookupFieldId(type_name, field)) |id| break :blk id;
            }
            if (self.lookupFieldId("", field)) |id| break :blk id;
            // 未注册字段：回退 0（safe_access 场景，报错会破坏 ?. 链）
            // TODO: 这里静默回退 0 会访问 __tag，但 safe_access 路径较难报错
            break :blk 0;
        };
        const meta_idx = self.addFieldIdMeta(field_id) catch return obj_chan;
        // 优先使用调用方传入的 sema chan_type（来自 field_access 或 safe_access 的 inner_type）
        const chan_type: *const type_descriptor_mod.TypeDescriptor = sema_chan_type orelse self.inferFieldType(object, field) orelse type_descriptor_mod.i64_descriptor;
        const out = self.allocChannel(chan_type) catch return obj_chan;
        self.emit(Node.makeUnary(.record_get, out, meta_idx, obj_chan)) catch return obj_chan;
        return out;
    }

    /// 从 TypeNode 提取简单类型名（不构造泛型字符串）。
    /// 用于参数/字段的类型标注 → 类型名映射（dispatchMethodCall 用）。
    /// .named → n.name；.generic → g.name（去掉泛型参数）；
    /// .nullable → 递归 inner；.self_type → "Self"；其他返回 null。
    pub fn typeNameFromTypeNodeSimple(self: *IRBuilder, tn: *const ast.TypeNode) ?[]const u8 {
        return switch (tn.*) {
            .named => |n| n.name,
            .self_type => "Self",
            .generic => |g| g.name,
            .nullable => |nb| self.typeNameFromTypeNodeSimple(nb.inner),
            .kind_annotated => |ka| self.typeNameFromTypeNodeSimple(ka.inner),
            else => null,
        };
    }

    /// 判断表达式是否为字符串类型（直接字面量或绑定了字符串字面量的变量）
    pub fn isStringExpr(self: *IRBuilder, expr: *const ast.Expr) bool {
        switch (expr.*) {
            .string_literal, .string_interpolation => return true,
            .identifier => |id| {
                if (self.lookupVar(id.name)) |binding| {
                    if (binding.ast_expr) |var_expr| {
                        return self.isStringExpr(var_expr);
                    }
                    // 检查类型标注
                    if (binding.type_annotation) |tn| {
                        return isStringTypeNode(tn);
                    }
                }
                return false;
            },
            .field_access => |fa| {
                // base 是 record_literal（直接或通过变量绑定），查字段的值是否为字符串
                const base_expr: ?*const ast.Expr = switch (fa.object.*) {
                    .record_literal => fa.object,
                    .identifier => |id| blk: {
                        if (self.lookupVar(id.name)) |binding| {
                            if (binding.ast_expr) |var_expr| {
                                if (var_expr.* == .record_literal) break :blk var_expr;
                            }
                        }
                        break :blk null;
                    },
                    else => null,
                };
                if (base_expr) |be| {
                    for (be.record_literal.fields) |rf| {
                        if (std.mem.eql(u8, rf.name, fa.field)) {
                            return self.isStringExpr(rf.value);
                        }
                    }
                }
                return false;
            },
            .binary => |b| {
                // 字符串拼接：+ 或 ++ 且至少一侧为字符串
                if (b.op == .add or b.op == .concat_list) {
                    return self.isStringExpr(b.left) or self.isStringExpr(b.right);
                }
                return false;
            },
            .block => |blk| {
                if (blk.trailing_expr) |te| return self.isStringExpr(te);
                return false;
            },
            .if_expr => |ie| {
                // if-else 两侧都为字符串时结果为字符串
                if (ie.else_branch) |else_b| {
                    return self.isStringExpr(ie.then_branch) and self.isStringExpr(else_b);
                }
                return false;
            },
            .match => |m| {
                // 所有 arm 都为字符串时结果为字符串
                for (m.arms) |arm| {
                    if (!self.isStringExpr(arm.body)) return false;
                }
                return true;
            },
            .call => |c| {
                // 检查是否为返回 str 的函数调用
                switch (c.callee.*) {
                    .identifier => |id| {
                        // built-in str(x) 返回 str
                        if (std.mem.eql(u8, id.name, "str")) return true;
                        return self.func_returns_str.contains(id.name);
                    },
                    else => return false,
                }
            },
            .method_call => {
                // 通过方法返回类型推断：inferTypeNameFromExpr 返回 "str" 时视为字符串
                if (self.inferTypeNameFromExpr(expr)) |tn| {
                    return std.mem.eql(u8, tn, "str");
                }
                return false;
            },
            .type_cast => |tc| {
                // str(x) 被解析为 type_cast，目标类型为 str 时结果为字符串
                return isStringTypeNode(tc.target_type);
            },
            .cast_builder => |cb| {
                // cast(x).to(str) / cast(x).try_to(str) 的目标类型为 str 时结果为字符串
                return isStringTypeNode(cb.target_type);
            },
            else => return false,
        }
    }

    /// 检查表达式是否为字符串（通过变量绑定的类型标注推断）
    /// 用于处理函数参数带 str 类型标注的情况
    pub fn isStringParam(self: *IRBuilder, expr: *const ast.Expr) bool {
        switch (expr.*) {
            .identifier => |id| {
                if (self.lookupVar(id.name)) |binding| {
                    if (binding.type_annotation) |tn| {
                        return isStringTypeNode(tn);
                    }
                }
                return false;
            },
            else => return false,
        }
    }

    /// 编译 Reflect 方法调用：r.field_value(i) / r.field_name(i) / r.deref() / ...
    /// obj_chan 是 reflect(x) 返回的 Reflect RecordValue 通道
    /// 根据 method 名生成对应 IR 节点
    pub fn compileReflectMethod(self: *IRBuilder, obj_chan: u16, method: []const u8, arguments: []*ast.Expr, object: *const ast.Expr) BuildError!u16 {
        // r.field_value(i) → builtin_reflect_field (inputs=[obj, idx_chan], meta_index=0)
        // 索引 i 为运行时值（while 循环变量），通过 inputs[1] 传递
        if (std.mem.eql(u8, method, "field_value")) {
            if (arguments.len != 1) return error.UnsupportedExpr;
            const idx_chan = try self.compileExpr(arguments[0]);
            // 标量单态化优化：尝试从 current_type_args 解析 T 的类型结构
            // 如果 T 是 newtype/nullable 且 inner 是标量，输出通道用标量通道（避免 ref_chan 位模式中转）
            const out_chan_type = self.resolveFieldValueChanType();
            const out = try self.allocChannel(out_chan_type);
            try self.emit(Node.makeBinary(.builtin_reflect_field, out, 0, obj_chan, idx_chan));
            return out;
        }
        // r.field_name(i) → builtin_reflect_field_name (inputs=[obj, idx_chan], meta_index=0)
        if (std.mem.eql(u8, method, "field_name")) {
            if (arguments.len != 1) return error.UnsupportedExpr;
            const idx_chan = try self.compileExpr(arguments[0]);
            const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
            try self.emit(Node.makeBinary(.builtin_reflect_field_name, out, 0, obj_chan, idx_chan));
            return out;
        }
        // r.deref() → builtin_reflect_deref
        if (std.mem.eql(u8, method, "deref")) {
            if (arguments.len != 0) return error.UnsupportedExpr;
            const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
            try self.emit(Node.makeUnary(.builtin_reflect_deref, out, 0, obj_chan));
            return out;
        }
        // r.type_name() → builtin_reflect_meta (meta_index=0)
        if (std.mem.eql(u8, method, "type_name")) {
            if (arguments.len != 0) return error.UnsupportedExpr;
            const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
            try self.emit(Node.makeUnary(.builtin_reflect_meta, out, 0, obj_chan));
            return out;
        }
        // r.kind() → builtin_reflect_meta (meta_index=1)
        if (std.mem.eql(u8, method, "kind")) {
            if (arguments.len != 0) return error.UnsupportedExpr;
            const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
            try self.emit(Node.makeUnary(.builtin_reflect_meta, out, 1, obj_chan));
            return out;
        }
        // r.field_count() / r.array_len() → builtin_reflect_meta (meta_index=2)
        // field_count 和 array_len 都读 Reflect.field_count（field 2）
        if (std.mem.eql(u8, method, "field_count") or std.mem.eql(u8, method, "array_len")) {
            if (arguments.len != 0) return error.UnsupportedExpr;
            const out = try self.allocChannel(type_descriptor_mod.usize_descriptor);
            try self.emit(Node.makeUnary(.builtin_reflect_meta, out, 2, obj_chan));
            return out;
        }
        // r.adt_tag() → builtin_reflect_field (meta_index=0xFFFE，特殊编码读 target.__tag)
        if (std.mem.eql(u8, method, "adt_tag")) {
            if (arguments.len != 0) return error.UnsupportedExpr;
            const out = try self.allocChannel(type_descriptor_mod.usize_descriptor);
            try self.emit(Node.makeUnary(.builtin_reflect_field, out, 0xFFFE, obj_chan));
            return out;
        }
        // r.adt_constructor() → builtin_reflect_field_name (meta_index = 0xFFFF，特殊编码)
        if (std.mem.eql(u8, method, "adt_constructor")) {
            if (arguments.len != 0) return error.UnsupportedExpr;
            const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
            try self.emit(Node.makeUnary(.builtin_reflect_field_name, out, 0xFFFF, obj_chan));
            return out;
        }
        // r.field_type(i) → 暂返回占位 TypeInfo（builtin_typeof meta_index=0）
        if (std.mem.eql(u8, method, "field_type")) {
            if (arguments.len != 1) return error.UnsupportedExpr;
            _ = try self.resolveConstIndex(arguments[0]);
            const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
            try self.emit(Node.makeSink(.builtin_typeof, out, 0));
            return out;
        }
        _ = object;
        return error.UnsupportedExpr;
    }

    /// 从常量表达式解析 usize 索引（用于 Reflect 方法参数）
    pub fn resolveConstIndex(self: *IRBuilder, arg: *const ast.Expr) BuildError!u16 {
        // 尝试从 sema 获取编译期常量值
        { const sr = self.sema_result;
            if (sr.getExpr(@intCast(@intFromPtr(arg)))) |info| {
                if (info.const_val) |cv| {
                    if (cv == .int_val) {
                        return @intCast(cv.int_val);
                    }
                }
            }
        }
        // 回退：字面量解析
        switch (arg.*) {
            .int_literal => |i| {
                const v = std.fmt.parseInt(u64, i.raw, 10) catch return 0;
                return @intCast(v);
            },
            else => return 0,
        }
    }

    /// 编译方法调用：obj.method(args)
    /// safe=true 时为 obj?.method(args)，先做 null 检查
    pub fn compileMethodCall(self: *IRBuilder, object: *ast.Expr, method: []const u8, arguments: []*ast.Expr, safe: bool, call_expr: *const ast.Expr) BuildError!u16 {
        // 模块引用方法调用：Module.Sub.method(args) → 直接调用模块函数，不需要 obj_chan
        if (!safe and self.isModuleReference(object) != null) {
            return try self.dispatchMethodCall(0, object, method, arguments, call_expr);
        }

        const obj_chan = try self.compileExpr(object);

        // safe_method_call：obj?.method(args) — obj 为 null 时返回 null
        if (safe) {
            return try self.compileSafeMethodCall(obj_chan, object, method, arguments, call_expr);
        }

        return try self.dispatchMethodCall(obj_chan, object, method, arguments, call_expr);
    }

    /// 安全方法调用：obj?.method(args)
    /// obj 为 null 时返回 null，否则调用方法
    pub fn compileSafeMethodCall(self: *IRBuilder, obj_chan: u16, object: *ast.Expr, method: []const u8, arguments: []*ast.Expr, call_expr: *const ast.Expr) BuildError!u16 {
        const obj_meta = self.channels.get(obj_chan);
        // 非 nullable/ref 直接调用
        if (!obj_meta.type_desc.is_nullable and !obj_meta.type_desc.is_ref) {
            return try self.dispatchMethodCall(obj_chan, object, method, arguments, call_expr);
        }
        // 包装为 nullable
        const nullable_chan = if (obj_meta.type_desc.is_nullable)
            obj_chan
        else blk: {
            const nc = try self.channels.allocNullable(type_descriptor_mod.ref_descriptor);
            try self.emit(Node.makeUnary(.nullable_make, nc, 0, obj_chan));
            break :blk nc;
        };
        const is_null_chan = try self.allocChannel(type_descriptor_mod.bool_descriptor);
        try self.emit(Node.makeUnary(.nullable_is_null, is_null_chan, 0, nullable_chan));
        const unwrapped_chan = try self.allocChannel(type_descriptor_mod.ref_descriptor);
        try self.emit(Node.makeUnary(.nullable_unwrap, unwrapped_chan, 0, nullable_chan));

        // then 子图：unwrapped.method(args)
        const else_start: u32 = @intCast(self.nodes.items.len);
        const null_out = try self.allocChannel(type_descriptor_mod.null_descriptor);
        try self.emit(Node.makeSink(.const_null, null_out, 0));
        const else_len: u32 = @intCast(self.nodes.items.len - else_start);

        const then_start: u32 = @intCast(self.nodes.items.len);
        const then_out = try self.dispatchMethodCall(unwrapped_chan, object, method, arguments, call_expr);
        if (self.nodes.items.len == then_start) {
            const load_chan = try self.allocChannel(self.channels.get(then_out).type_desc);
            try self.emit(Node.makeUnary(.load, load_chan, 0, then_out));
        }
        const then_len: u32 = @intCast(self.nodes.items.len - then_start);

        const winner_chan = try self.allocChannel(type_descriptor_mod.i64_descriptor);
        const cast_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64 });
        try self.emit(Node.makeUnary(.cast, winner_chan, cast_meta, is_null_chan));

        const arena_alloc = self.arena.allocator();
        const body_starts = try arena_alloc.alloc(u32, 2);
        const body_lens = try arena_alloc.alloc(u32, 2);
        body_starts[0] = else_start;
        body_lens[0] = else_len;
        body_starts[1] = then_start;
        body_lens[1] = then_len;

        const result_type = self.channels.get(self.nodes.items[then_start + then_len - 1].output).type_desc;
        const result_out = try self.allocChannel(result_type);
        const route_meta_idx = try self.addRouteMeta(.{
            .trait_id = 0,
            .method_id = 0,
            .target_count = 2,
            .body_starts = body_starts,
            .body_lens = body_lens,
        });
        try self.emit(Node.makeUnary(.route_dispatch, result_out, route_meta_idx, winner_chan));
        return result_out;
    }

    /// 检查表达式是否为模块引用，递归收集多层 field_access 路径
    /// 支持：
    ///   - identifier(已导入模块名)                          → "Module"
    ///   - field_access(模块引用, sub)                        → "Module.Sub"
    ///   - field_access(field_access(模块引用, a), b)          → "Module.a.b"
    ///   - 任意深度嵌套（如 std.time.Calendar）                → "std.time.Calendar"
    /// safe_access 不进入模块路径（保持 `foo?.bar` 的常规语义）
    pub fn isModuleReference(self: *IRBuilder, expr: *const ast.Expr) ?ModuleRef {
        switch (expr.*) {
            .identifier => |id| {
                // 基础情况：顶层模块名必须在 imported_modules 中登记
                if (self.imported_modules.contains(id.name)) {
                    // 短名别名优先：返回完整路径
                    if (self.module_alias_map.get(id.name)) |full_path| {
                        return .{ .full_path = full_path };
                    }
                    // 首段名：原逻辑
                    return .{ .full_path = id.name };
                }
                return null;
            },
            .field_access => |fa| {
                // 递归：object 必须先识别为模块引用，再拼接当前字段名
                const base = self.isModuleReference(fa.object) orelse return null;
                const arena_alloc = self.arena.allocator();
                const full = std.fmt.allocPrint(arena_alloc, "{s}.{s}", .{ base.full_path, fa.field }) catch return null;
                return .{ .full_path = full };
            },
            else => return null,
        }
    }

    /// 按方法名分派：用户自定义方法优先，其次内置方法
    pub fn dispatchMethodCall(self: *IRBuilder, obj_chan: u16, object: *ast.Expr, method: []const u8, arguments: []*ast.Expr, call_expr: *const ast.Expr) BuildError!u16 {
        // ── 模块引用方法调用：Module.Sub.method(args) → call("Module.Sub.method", args) ──
        // 支持任意深度：std.time.Calendar.weekday_of → "std.time.Calendar.weekday_of"
        if (self.isModuleReference(object)) |mod_ref| {
            const arena_alloc = self.arena.allocator();
            const mangled = try std.fmt.allocPrint(arena_alloc, "{s}.{s}", .{ mod_ref.full_path, method });
            if (self.func_table.get(mangled)) |func_idx| {
                const func = self.functions.items[func_idx];
                var arg_chans = try arena_alloc.alloc(u16, arguments.len);
                for (arguments, 0..) |arg, i| {
                    arg_chans[i] = try self.compileExpr(arg);
                }
                // async 函数：发射 orbit_async_create 返回 AsyncHandle（不自动 await）
                if (func.is_async) {
                    const async_type_args = try self.typeArgsFromCallExpr(call_expr);
                    return try self.emitOrbitCreate(func_idx, arg_chans, func, async_type_args);
                }
                // 返回 nullable_chan 时传播 inner_type
                const ret_meta = self.channels.get(func.return_channel);
                const out = if (ret_meta.type_desc.is_nullable)
                    try self.channels.allocNullable(ret_meta.inner_type_desc orelse type_descriptor_mod.i64_descriptor)
                else
                    try self.allocChannel(ret_meta.type_desc);
                // 从形参通道提取引用位图
                var arg_ref_bits: u16 = 0;
                for (func.param_channels, 0..) |pc, i| {
                    if (i >= 16) break;
                    if (self.channels.get(pc).type_desc.is_ref) {
                        arg_ref_bits |= @as(u16, 1) << @intCast(i);
                    }
                }
                const ret_is_ref = self.channels.get(func.return_channel).type_desc.is_ref;
                // 计算泛型类型实参（type_args）用于 typeof(T)/reflect(T) 运行时查表
                // sema 已预先收集所有泛型调用点，IR 直接消费 sema call_instantiations
                const type_args = try self.typeArgsFromCallExpr(call_expr);
                // 单态化：泛型函数实例化为特化版本
                const mono_func_idx = if (type_args.len > 0)
                    try self.instantiateFunction(mangled, type_args)
                else
                    func_idx;
                const call_meta_idx = try self.addCallMeta(.{
                    .func_index = mono_func_idx,
                    .arg_count = @intCast(arg_chans.len),
                    .arg_ref_bits = arg_ref_bits,
                    .ret_is_ref = ret_is_ref,
                    .type_args = type_args,
                });
                var inputs: [4]u16 = .{ 0, 0, 0, 0 };
                for (arg_chans, 0..) |ch, i| {
                    if (i < 4) inputs[i] = ch;
                }
                try self.emit(Node{
                    .op = .call,
                    .input_count = @intCast(@min(arg_chans.len, 4)),
                    .output = out,
                    .meta_index = call_meta_idx,
                    .inputs = inputs,
                });
                return out;
            }
            // 构造器调用：Module.Sub.TypeName(args) → 查 ctor_def_index
            // 类型即模块：当 method 是类型/构造器名，走构造器路径
            if (self.sema_result.getCtorDef(method)) |ctor| {
                return try self.compileConstructorCall(ctor, arguments);
            }
        }

        // ── 用户自定义方法优先：obj.method(args) → call("TypeName.method", [obj, ...args]) ──
        if (self.inferTypeNameFromExpr(object)) |type_name| {
            // Reflect 方法分派：obj 是 reflect(x) 返回的 Reflect<T> 时，生成对应 IR
            if (std.mem.eql(u8, type_name, "Reflect")) {
                return try self.compileReflectMethod(obj_chan, method, arguments, object);
            }
            const arena_alloc = self.arena.allocator();
            const mangled = try std.fmt.allocPrint(arena_alloc, "{s}.{s}", .{ type_name, method });
            // 先尝试短名查找（如 "DateTime.to_components"），失败则用后缀扫描
            // stdlib 中 func_table 存的是 mangled name（如 "std.time.DateTime.to_components"），
            // 短名 "DateTime" 找不到时扫描 func_table 寻找以 ".DateTime.to_components" 结尾的键
            if (self.func_table.get(mangled)) |func_idx| {
                return try self.emitUserMethodCall(obj_chan, arguments, func_idx, arena_alloc, mangled, call_expr);
            }
            if (self.lookupMethodBySuffix(type_name, method)) |func_idx| {
                return try self.emitUserMethodCall(obj_chan, arguments, func_idx, arena_alloc, mangled, call_expr);
            }
        }

        // ── Trait 值方法分派：obj.method(args) → array_get(obj, method_idx) + call_indirect ──
        // 一等 Trait 值（inline_trait_value）编译为闭包数组，按方法索引存储
        if (self.inferTraitNameFromExpr(object)) |trait_name| {
            if (self.sema_result.getTraitDef(trait_name)) |_| {
                const trait_methods = self.findTraitMethodsAst(trait_name);
                if (trait_methods) |methods| {
                    // 查找方法在 trait 中的索引
                    var method_idx: ?usize = null;
                    for (methods, 0..) |m, i| {
                        if (std.mem.eql(u8, m.name, method)) {
                            method_idx = i;
                            break;
                        }
                    }
                    if (method_idx) |idx| {
                        const arena_alloc = self.arena.allocator();
                        // array_get(obj_chan, idx) → closure_chan
                        const idx_chan = try self.allocChannel(type_descriptor_mod.i64_descriptor);
                        const idx_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = @intCast(idx) } });
                        try self.emit(Node.makeSink(.const_i, idx_chan, idx_meta));
                        const closure_chan = try self.allocChannel(type_descriptor_mod.ref_descriptor);
                        try self.emit(Node.makeBinary(.array_get, closure_chan, 0, obj_chan, idx_chan));

                        // call_indirect(closure_chan, args)
                        var arg_chans = try arena_alloc.alloc(u16, arguments.len);
                        for (arguments, 0..) |arg, i| {
                            arg_chans[i] = try self.compileExpr(arg);
                        }

                        // 结果类型：从 trait 方法返回类型推断
                        const ret_chan_type = if (methods[idx].return_type) |rt|
                            self.chanTypeFromTypeNodeBound(rt) orelse type_descriptor_mod.i64_descriptor
                        else
                            type_descriptor_mod.i64_descriptor;
                        const out = try self.allocChannel(ret_chan_type);
                        const call_meta_idx = try self.addCallMeta(.{
                            .func_index = 0,
                            .arg_count = @intCast(arguments.len + 1),
                        });

                        var inputs: [4]u16 = .{ 0, 0, 0, 0 };
                        inputs[0] = closure_chan;
                        for (arg_chans, 0..) |ch, i| {
                            if (i + 1 < 4) inputs[i + 1] = ch;
                        }
                        try self.emit(Node{
                            .op = .call_indirect,
                            .input_count = @intCast(@min(arguments.len + 1, 4)),
                            .output = out,
                            .meta_index = call_meta_idx,
                            .inputs = inputs,
                        });
                        return out;
                    }
                }
            }
        }

        // ── 内置方法（按名称分派） ──
        if (std.mem.eql(u8, method, "await")) {
            // obj.await() → orbit_async_join
            // 通过 async_handle_meta 查询 handle_chan 关联的 orbit_meta_idx，
            // 获取正确的 result_type（ref_chan 用于 Throw/record 等堆对象结果）
            if (self.async_handle_meta.get(obj_chan)) |orbit_meta_idx| {
                return try self.emitOrbitJoin(obj_chan, orbit_meta_idx);
            }
            // 回退：无法关联 orbit_meta（如跨函数传递的 handle），使用 i64_chan
            const out = try self.allocChannel(type_descriptor_mod.i64_descriptor);
            try self.emit(Node.makeUnary(.orbit_async_join, out, 0, obj_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "status")) {
            // obj.status() → orbit_async_status，返回 i64
            const out = try self.allocChannel(type_descriptor_mod.i64_descriptor);
            try self.emit(Node.makeUnary(.orbit_async_status, out, 0, obj_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "send")) {
            // ch.send(v) → orbit_chan_send
            if (arguments.len != 1) return error.UnsupportedExpr;
            const val_chan = try self.compileExpr(arguments[0]);
            return try self.emitOrbitSend(obj_chan, val_chan);
        }
        if (std.mem.eql(u8, method, "recv")) {
            // ch.recv() → orbit_chan_recv，结果类型默认 i64
            return try self.emitOrbitRecv(obj_chan, type_descriptor_mod.i64_descriptor);
        }
        if (std.mem.eql(u8, method, "tryRecv")) {
            // ch.tryRecv() → orbit_chan_try_recv，返回 nullable
            return try self.emitOrbitTryRecv(obj_chan, type_descriptor_mod.i64_descriptor);
        }
        if (std.mem.eql(u8, method, "close")) {
            // ch.close() → channel_close，返回 unit
            const out = try self.allocChannel(type_descriptor_mod.unit_descriptor);
            try self.emit(Node.makeUnary(.channel_close, out, 0, obj_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "swap")) {
            // atm.swap(v) → atomic_swap，返回旧值（内部标量类型，非 ref_chan）
            if (arguments.len != 1) return error.UnsupportedExpr;
            const val_chan = try self.compileExpr(arguments[0]);
            const val_meta = self.channels.get(val_chan);
            const out = try self.allocChannel(val_meta.type_desc);
            try self.emit(Node.makeBinary(.atomic_swap, out, 0, obj_chan, val_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "cas")) {
            // atm.cas(expected, new) → atomic_cas，返回 bool
            if (arguments.len != 2) return error.UnsupportedExpr;
            const expected_chan = try self.compileExpr(arguments[0]);
            const new_chan = try self.compileExpr(arguments[1]);
            const out = try self.allocChannel(type_descriptor_mod.bool_descriptor);
            try self.emit(Node.makeTernary(.atomic_cas, out, 0, obj_chan, expected_chan, new_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "len")) {
            // obj.len() → string_len 或 array_len（按 AST 推断 + 参数类型标注）
            // Phase 5: 返回类型从 i64 改为 usize（spec §8.1）
            const is_string = self.isStringExpr(object) or self.isStringParam(object);
            if (is_string) {
                const out = try self.allocChannel(type_descriptor_mod.usize_descriptor);
                try self.emit(Node.makeUnary(.string_len, out, 0, obj_chan));
                return out;
            }
            const out = try self.allocChannel(type_descriptor_mod.usize_descriptor);
            try self.emit(Node.makeUnary(.array_len, out, 0, obj_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "push")) {
            // arr.push(v) → array_push，返回数组引用（支持 result = arr.push(x)）
            if (arguments.len != 1) return error.UnsupportedExpr;
            const val_chan = try self.compileExpr(arguments[0]);
            const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
            try self.emit(Node.makeBinary(.array_push, out, 0, obj_chan, val_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "pop")) {
            // arr.pop() → array_pop，返回弹出的元素（ref）
            const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
            try self.emit(Node.makeUnary(.array_pop, out, 0, obj_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "first")) {
            // arr.first() → array_first，返回 nullable i64（可能为空数组）
            const out = try self.channels.allocNullable(type_descriptor_mod.i64_descriptor);
            try self.emit(Node.makeUnary(.array_first, out, 0, obj_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "last")) {
            // arr.last() → array_last，返回 nullable i64（可能为空数组）
            const out = try self.channels.allocNullable(type_descriptor_mod.i64_descriptor);
            try self.emit(Node.makeUnary(.array_last, out, 0, obj_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "is_empty")) {
            // arr.is_empty() / s.is_empty() → len == 0 → bool
            const is_string = self.isStringExpr(object);
            const len_op: NodeOp = if (is_string) .string_len else .array_len;
            // Phase 5: len 返回 usize
            const len_chan = try self.allocChannel(type_descriptor_mod.usize_descriptor);
            try self.emit(Node.makeUnary(len_op, len_chan, 0, obj_chan));
            // 创建常量 0 通道用于比较
            const zero_chan = try self.allocChannel(type_descriptor_mod.usize_descriptor);
            const zero_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .usize, .const_val = .{ .int_val = 0 } });
            try self.emit(Node.makeSink(.const_i, zero_chan, zero_meta));
            const out = try self.allocChannel(type_descriptor_mod.bool_descriptor);
            try self.emit(Node.makeBinary(.cmp_eq, out, 0, len_chan, zero_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "contains")) {
            // arr.contains(v) / s.contains(ch) → array_contains / string_contains
            if (arguments.len != 1) return error.UnsupportedExpr;
            const val_chan = try self.compileExpr(arguments[0]);
            const out = try self.allocChannel(type_descriptor_mod.bool_descriptor);
            const is_string = self.isStringExpr(object);
            const op: NodeOp = if (is_string) .string_contains else .array_contains;
            try self.emit(Node.makeBinary(op, out, 0, obj_chan, val_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "bytes")) {
            // s.bytes() → string_bytes，返回 u8[] 数组（UTF-8 编码）
            if (arguments.len != 0) return error.UnsupportedExpr;
            const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
            try self.emit(Node.makeUnary(.string_bytes, out, 0, obj_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "drop_last")) {
            // arr.drop_last() → array_drop_last，返回新数组（ref）
            const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
            try self.emit(Node.makeUnary(.array_drop_last, out, 0, obj_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "get")) {
            // arr.get(i) → array_get_safe，返回 nullable（安全索引）
            if (arguments.len != 1) return error.UnsupportedExpr;
            const idx_chan = try self.compileExpr(arguments[0]);
            const out = try self.channels.allocNullable(type_descriptor_mod.ref_descriptor);
            try self.emit(Node.makeBinary(.array_get_safe, out, 0, obj_chan, idx_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "message")) {
            // e.message() → error_message，返回 str ref
            const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
            try self.emit(Node.makeUnary(.error_message, out, 0, obj_chan));
            return out;
        }
        if (std.mem.eql(u8, method, "type_name")) {
            // obj.type_name() → obj_type_name，返回 str ref
            const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
            try self.emit(Node.makeUnary(.obj_type_name, out, 0, obj_chan));
            return out;
        }

        return error.UnsupportedExpr;
    }

    /// 在 func_table 中后缀扫描方法：查找以 ".{type_name}.{method}" 结尾的键。
    /// 用于 stdlib：func_table 存的是 mangled name（如 "std.time.DateTime.to_components"），
    /// 当对象类型只能推断出短名（如 "DateTime"）时，通过后缀匹配定位 mangled 函数。
    /// 若后缀匹配失败，回退到参数类型匹配：扫描所有函数，检查函数名以 ".{method}" 结尾
    /// 且第一个参数的类型名与 type_name 一致（处理类型名与模块名不同的情况，
    /// 如 BufReader 类型定义在 std.io.Buffered 模块中）。
    /// 返回 func_idx 或 null（未找到）。
    pub fn lookupMethodBySuffix(self: *IRBuilder, type_name: []const u8, method: []const u8) ?u16 {
        const arena_alloc = self.arena.allocator();
        const suffix = std.fmt.allocPrint(arena_alloc, ".{s}.{s}", .{ type_name, method }) catch return null;
        for (self.func_table.keys.items, self.func_table.values.items) |k, v| {
            if (std.mem.endsWith(u8, k, suffix)) return v;
        }
        // 回退：按方法名后缀 + 第一个参数类型名匹配
        const method_suffix = std.fmt.allocPrint(arena_alloc, ".{s}", .{method}) catch return null;
        for (self.func_table.keys.items, self.func_table.values.items) |k, v| {
            if (!std.mem.endsWith(u8, k, method_suffix)) continue;
            if (self.sema_result.getFuncSig(k)) |sig| {
                if (sig.param_type_names.len > 0) {
                    if (sig.param_type_names[0]) |param_tn| {
                        if (std.mem.eql(u8, param_tn, type_name)) return v;
                    }
                }
            }
        }
        return null;
    }

    /// 发射用户自定义方法调用节点：call("Type.method", [obj, ...args])
    /// 已知 func_idx 时构造 call node，obj_chan 作为第一个参数。
    pub fn emitUserMethodCall(
        self: *IRBuilder,
        obj_chan: u16,
        arguments: []*ast.Expr,
        func_idx: u16,
        arena_alloc: std.mem.Allocator,
        method_name: []const u8,
        call_expr: *const ast.Expr,
    ) BuildError!u16 {
        _ = method_name; // sema 已预先收集类型实参，IR 通过 call_expr 查 sema call_instantiations
        const func = self.functions.items[func_idx];
        var arg_chans = try arena_alloc.alloc(u16, arguments.len + 1);
        arg_chans[0] = obj_chan;
        for (arguments, 0..) |arg, i| {
            arg_chans[i + 1] = try self.compileExpr(arg);
        }
        // async 函数：发射 orbit_async_create 返回 AsyncHandle（不自动 await）
        // 与 dispatchMethodCall 中模块引用 async 路径一致
        if (func.is_async) {
            const async_type_args = try self.typeArgsFromCallExpr(call_expr);
            return try self.emitOrbitCreate(func_idx, arg_chans, func, async_type_args);
        }
        // 函数返回 nullable_chan 时，传播 inner_type（否则 nullable_is_null 读错字节）
        const ret_meta = self.channels.get(func.return_channel);
        const out = if (ret_meta.type_desc.is_nullable)
            try self.channels.allocNullable(ret_meta.inner_type_desc orelse type_descriptor_mod.i64_descriptor)
        else
            try self.allocChannel(ret_meta.type_desc);
        // 从形参通道提取引用位图（self + 显式参数）
        var arg_ref_bits: u16 = 0;
        for (func.param_channels, 0..) |pc, i| {
            if (i >= 16) break;
            if (self.channels.get(pc).type_desc.is_ref) {
                arg_ref_bits |= @as(u16, 1) << @intCast(i);
            }
        }
        // 返回值引用标记
        const ret_is_ref = self.channels.get(func.return_channel).type_desc.is_ref;
        const call_meta_idx = try self.addCallMeta(.{
            .func_index = func_idx,
            .arg_count = @intCast(arg_chans.len),
            .arg_ref_bits = arg_ref_bits,
            .ret_is_ref = ret_is_ref,
        });
        var inputs: [4]u16 = .{ 0, 0, 0, 0 };
        for (arg_chans, 0..) |ch, i| {
            if (i < 4) inputs[i] = ch;
        }
        try self.emit(Node{
            .op = .call,
            .input_count = @intCast(@min(arg_chans.len, 4)),
            .output = out,
            .meta_index = call_meta_idx,
            .inputs = inputs,
        });
        return out;
    }

    /// 收集表达式中的自由变量（不在 param_names 中的标识符）
    pub fn collectFreeVars(self: *IRBuilder, expr: *const ast.Expr, param_names: []const []const u8, out: *std.StringHashMap(void)) void {
        switch (expr.*) {
            .identifier => |id| {
                // 排除 lambda 参数
                for (param_names) |pn| {
                    if (std.mem.eql(u8, pn, id.name)) return;
                }
                // 只收集当前作用域中存在的变量（可捕获的）
                if (self.lookupVar(id.name) != null) {
                    out.put(id.name, {}) catch {};
                }
            },
            .binary => |b| {
                self.collectFreeVars(b.left, param_names, out);
                self.collectFreeVars(b.right, param_names, out);
            },
            .unary => |u| self.collectFreeVars(u.operand, param_names, out),
            .ref_of => |r| self.collectFreeVars(r.operand, param_names, out),
            .deref => |d| self.collectFreeVars(d.operand, param_names, out),
            .call => |c| {
                self.collectFreeVars(c.callee, param_names, out);
                for (c.arguments) |a| self.collectFreeVars(a, param_names, out);
            },
            .if_expr => |ie| {
                self.collectFreeVars(ie.condition, param_names, out);
                self.collectFreeVars(ie.then_branch, param_names, out);
                if (ie.else_branch) |eb| self.collectFreeVars(eb, param_names, out);
            },
            .block => |blk| {
                for (blk.statements) |s| self.collectFreeVarsStmt(s, param_names, out);
                if (blk.trailing_expr) |te| self.collectFreeVars(te, param_names, out);
            },
            .method_call => |mc| {
                self.collectFreeVars(mc.object, param_names, out);
                for (mc.arguments) |a| self.collectFreeVars(a, param_names, out);
            },
            .field_access => |fa| self.collectFreeVars(fa.object, param_names, out),
            .index => |idx| {
                self.collectFreeVars(idx.object, param_names, out);
                self.collectFreeVars(idx.index, param_names, out);
            },
            .slice => |sl| {
                self.collectFreeVars(sl.object, param_names, out);
                self.collectFreeVars(sl.start, param_names, out);
                self.collectFreeVars(sl.end, param_names, out);
            },
            .match => |m| {
                self.collectFreeVars(m.scrutinee, param_names, out);
                for (m.arms) |arm| self.collectFreeVars(arm.body, param_names, out);
            },
            .propagate => |p| self.collectFreeVars(p.expr, param_names, out),
            .non_null_assert => |nn| self.collectFreeVars(nn.expr, param_names, out),
            .safe_access => |sa| self.collectFreeVars(sa.object, param_names, out),
            .safe_method_call => |mc| {
                self.collectFreeVars(mc.object, param_names, out);
                for (mc.arguments) |a| self.collectFreeVars(a, param_names, out);
            },
            .assignment_expr => |a| {
                self.collectFreeVars(a.target, param_names, out);
                self.collectFreeVars(a.value, param_names, out);
            },
            .compound_assign => |ca| {
                self.collectFreeVars(ca.target, param_names, out);
                self.collectFreeVars(ca.value, param_names, out);
            },
            .string_interpolation => |si| {
                for (si.parts) |part| {
                    if (part == .expression) self.collectFreeVars(part.expression, param_names, out);
                }
            },
            else => {},
        }
    }

    pub fn collectFreeVarsStmt(self: *IRBuilder, stmt: *const ast.Stmt, param_names: []const []const u8, out: *std.StringHashMap(void)) void {
        switch (stmt.*) {
            .val_decl => |vd| self.collectFreeVars(vd.value, param_names, out),
            .var_decl => |vd| self.collectFreeVars(vd.value, param_names, out),
            .expression => |es| self.collectFreeVars(es.expr, param_names, out),
            .defer_stmt => |ds| self.collectFreeVars(ds.expr, param_names, out),
            else => {},
        }
    }

    /// 编译 lambda 表达式为匿名函数 + closure_make 节点
    /// 1. 收集自由变量（捕获上值）
    /// 2. 注册匿名函数（params = lambda参数 + 上值参数）
    /// 3. 编译函数体
    /// 4. 发射 closure_make 节点（携带上值通道）
    pub fn compileLambda(self: *IRBuilder, lam: anytype) BuildError!u16 {
        const arena_alloc = self.arena.allocator();

        // 提前分配 closure_make 的输出通道，以便预声明递归 lambda 名
        const closure_out_chan = try self.allocChannel(type_descriptor_mod.ref_descriptor);
        // 如果有预声明的 lambda 名（val name = fun(...) { ... } 形式），先绑定到输出通道
        // 这样 lambda body 内可以递归引用自身
        var pre_decl_name: ?[]const u8 = null;
        if (self.pre_declared_lambda_names.items.len > 0) {
            pre_decl_name = self.pre_declared_lambda_names.items[self.pre_declared_lambda_names.items.len - 1];
            // 将 lambda 返回类型作为 type_annotation 存储，供 compileCall 推断间接调用返回类型
            try self.scopeVarTyped(pre_decl_name.?, closure_out_chan, false, null, lam.return_type);
            // 如果 lambda 返回 Throw，记录到持久集合（跨作用域有效，供 exprIsThrowValue 查询）
            if (isThrowType(lam.return_type)) {
                try self.lambda_returns_throw.put(pre_decl_name.?, {});
            }
        }

        // 1. 收集自由变量
        var free_vars = std.StringHashMap(void).init(arena_alloc);
        defer free_vars.deinit();
        const body_expr: *const ast.Expr = switch (lam.body) {
            .block => |b| b,
            .expression => |e| e,
        };
        // 构造参数名列表
        var param_names = std.ArrayList([]const u8).empty;
        defer param_names.deinit(arena_alloc);
        for (lam.params) |p| param_names.append(arena_alloc, p.name) catch return error.OutOfMemory;
        self.collectFreeVars(body_expr, param_names.items, &free_vars);

        // 2. 收集上值通道（按插入顺序）
        var upvalue_names = std.ArrayList([]const u8).empty;
        defer upvalue_names.deinit(arena_alloc);
        var upvalue_chans = std.ArrayList(u16).empty;
        defer upvalue_chans.deinit(arena_alloc);
        var fv_it = free_vars.iterator();
        while (fv_it.next()) |entry| {
            if (self.lookupVar(entry.key_ptr.*)) |binding| {
                upvalue_names.append(arena_alloc, entry.key_ptr.*) catch return error.OutOfMemory;
                upvalue_chans.append(arena_alloc, binding.chan) catch return error.OutOfMemory;
            }
        }

        // 3. 注册匿名函数
        const lambda_counter = self.lambda_counter;
        self.lambda_counter += 1;
        const func_name = std.fmt.allocPrint(arena_alloc, "__lambda_{d}", .{lambda_counter}) catch return error.OutOfMemory;
        const func_idx: u16 = @intCast(self.functions.items.len);
        try self.func_table.put(func_name, func_idx);

        // 返回类型
        const return_type = self.chanTypeFromTypeNodeBound(lam.return_type) orelse type_descriptor_mod.i64_descriptor;
        const placeholder_return_chan = try self.allocChannel(return_type);
        try self.functions.append(arena_alloc, .{
            .name = func_name,
            .node_start = 0,
            .node_count = 0,
            .param_channels = &.{},
            .return_channel = placeholder_return_chan,
            .is_entry = false,
            .is_async = lam.is_async,
        });

        // 4. 编译函数体（params = lambda参数 + 上值参数）
        const saved_return_chan = self.current_return_chan;
        const saved_returns_throw = self.current_returns_throw;
        const saved_throw_ok_chan_type = self.current_throw_ok_type_desc;
        const lambda_body_start: u32 = @intCast(self.nodes.items.len);
        const node_start: u32 = lambda_body_start;
        const chan_start: u16 = self.channels.count();

        try self.pushScope();
        // 分配参数通道
        var all_param_chans = try arena_alloc.alloc(u16, lam.params.len + upvalue_names.items.len);
        for (lam.params, 0..) |param, i| {
            const chan_type = if (param.type_annotation) |tn|
                self.chanTypeFromTypeNodeBound(tn) orelse type_descriptor_mod.i64_descriptor
            else
                type_descriptor_mod.i64_descriptor;
            const chan = try self.allocChannel(chan_type);
            all_param_chans[i] = chan;
            try self.defineVar(param.name, chan, false);
        }
        // 上值参数通道
        for (upvalue_names.items, 0..) |name, i| {
            const idx = lam.params.len + i;
            const upval_chan_type = self.channels.get(upvalue_chans.items[i]).type_desc;
            const chan = try self.allocChannel(upval_chan_type);
            all_param_chans[idx] = chan;
            // 从原始绑定继承类型标注与 ast_expr（用于 isStringExpr 等类型推断）
            const orig_binding = self.lookupVar(name);
            try self.scopeVarTyped(name, chan, false, if (orig_binding) |b| b.ast_expr else null, if (orig_binding) |b| b.type_annotation else null);
        }
        const return_chan = placeholder_return_chan;
        self.current_return_chan = return_chan;
        // async lambda 返回 Async<T>，但体产出 T：throw/Ok 语义按 T 处理
        const lam_effective_return_type = unwrapAsyncType(lam.return_type);
        self.current_returns_throw = isThrowType(lam_effective_return_type);
        if (self.current_returns_throw) {
            self.current_throw_ok_type_desc = throwOkChanType(lam_effective_return_type) orelse type_descriptor_mod.i64_descriptor;
        }

        // 编译函数体
        const body_chan = try self.compileExpr(body_expr);
        const final_chan = if (self.current_returns_throw and !self.exprIsThrowValue(body_expr)) blk: {
            const wrap_out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
            const meta_idx = try self.addGateMeta(.{ .gate_kind = .make_ok });
            try self.emit(Node.makeUnary(.gate_make_ok, wrap_out, meta_idx, body_chan));
            break :blk wrap_out;
        } else body_chan;
        try self.emit(Node.makeUnary(.halt_return, return_chan, 0, final_chan));

        self.current_return_chan = saved_return_chan;
        self.current_returns_throw = saved_returns_throw;
        self.current_throw_ok_type_desc = saved_throw_ok_chan_type;
        self.popScope();

        const node_count: u32 = @intCast(self.nodes.items.len - node_start);
        const chan_end: u16 = self.channels.count();
        self.functions.items[func_idx].node_start = node_start;
        self.functions.items[func_idx].node_count = node_count;
        self.functions.items[func_idx].param_channels = all_param_chans;
        self.functions.items[func_idx].local_chan_start = chan_start;
        self.functions.items[func_idx].local_chan_count = chan_end - chan_start;

        // 5. 发射 closure_make 节点
        // 标记哪些 upvalue 是 cell 通道（var 变量，引用语义）
        var cell_upvalues: u8 = 0;
        var upvalue_ref_bits: u8 = 0;
        for (upvalue_chans.items, 0..) |ch, i| {
            if (i >= 8) break;
            const meta = self.channels.get(ch);
            if (meta.is_cell) cell_upvalues |= @as(u8, 1) << @intCast(i);
            if (meta.type_desc.is_ref) upvalue_ref_bits |= @as(u8, 1) << @intCast(i);
        }
        const closure_meta_idx = try self.addClosureMeta(.{
            .func_index = func_idx,
            .upvalue_count = @intCast(upvalue_chans.items.len),
            .result_type_desc = return_type,
            .body_start = lambda_body_start,
            .body_len = node_count,
            .cell_upvalues = cell_upvalues,
            .upvalue_ref_bits = upvalue_ref_bits,
        });

        var inputs: [4]u16 = .{ 0, 0, 0, 0 };
        for (upvalue_chans.items, 0..) |ch, i| {
            if (i < 4) inputs[i] = ch;
        }
        try self.emit(Node{
            .op = .closure_make,
            .input_count = @intCast(@min(upvalue_chans.items.len, 4)),
            .output = closure_out_chan,
            .meta_index = closure_meta_idx,
            .inputs = inputs,
        });
        return closure_out_chan;
    }

    /// 编译间接调用（通过 closure 值调用）
    /// inputs[0] = closure_chan, inputs[1..M] = arg_channels
    pub fn compileCallIndirect(self: *IRBuilder, closure_chan: u16, arguments: []*ast.Expr, ret_chan_type: *const type_descriptor_mod.TypeDescriptor) BuildError!u16 {
        const arena_alloc = self.arena.allocator();
        var arg_chans = try arena_alloc.alloc(u16, arguments.len);
        var arg_ref_bits: u16 = 0;
        for (arguments, 0..) |arg, i| {
            if (i >= 16) break;
            if (self.isRefExpr(arg)) {
                arg_ref_bits |= @as(u16, 1) << @intCast(i);
            }
            arg_chans[i] = try self.compileExpr(arg);
        }

        // 使用传入的返回类型分配输出通道
        const out = try self.allocChannel(ret_chan_type);
        const call_meta_idx = try self.addCallMeta(.{
            .func_index = 0, // 运行时从 closure 值读取
            .arg_count = @intCast(arguments.len + 1), // +1 for closure_chan
            .arg_ref_bits = arg_ref_bits,
            .ret_is_ref = false,
        });

        var inputs: [4]u16 = .{ 0, 0, 0, 0 };
        inputs[0] = closure_chan;
        for (arg_chans, 0..) |ch, i| {
            if (i + 1 < 4) inputs[i + 1] = ch;
        }
        try self.emit(Node{
            .op = .call_indirect,
            .input_count = @intCast(@min(arguments.len + 1, 4)),
            .output = out,
            .meta_index = call_meta_idx,
            .inputs = inputs,
        });
        return out;
    }

    /// 编译 atomic 表达式：atomic value → AtomicValue 堆对象（ref_chan 指针）
    /// 跨线程共享，所有操作通过 mutex 保护
    pub fn compileAtomicExpr(self: *IRBuilder, value_expr: *const ast.Expr) BuildError!u16 {
        const val_chan = try self.compileExpr(value_expr);
        const out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
        try self.emit(Node.makeUnary(.atomic_make, out, 0, val_chan));
        return out;
    }

    /// 编译 lazy 表达式：lazy expr → LazyValue（包装无参 thunk 闭包）
    /// thunk 捕获 lazy 表达式所在作用域的自由变量，body 直接返回 expr 的值。
    pub fn compileLazyExpr(self: *IRBuilder, expr: *const ast.Expr) BuildError!u16 {
        // 构造无参 lambda：fun() -> expr.type { expr }
        const arena_alloc = self.arena.allocator();
        const thunk_expr = try arena_alloc.create(ast.Expr);
        thunk_expr.* = expr.*;
        const thunk = ast.Expr{
            .lambda = .{
                .params = &.{},
                .return_type = null,
                .body = .{ .expression = thunk_expr },
                .is_async = false,
            },
        };
        const closure_chan = try self.compileLambda(thunk.lambda);
        const lazy_out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
        try self.emit(Node.makeUnary(.lazy_make, lazy_out, 0, closure_chan));
        return lazy_out;
    }

    /// 编译 spawn 表达式：spawn expr → orbit_async_create（不自动 await）
    /// expr 应为 async 函数调用或 lambda
    pub fn compileSpawnExpr(self: *IRBuilder, expr: *const ast.Expr) BuildError!u16 {
        // 如果是函数调用，编译为 async create（不 join）
        switch (expr.*) {
            .call => |c| {
                // 检查是否为已注册的 async 函数
                const func_name = switch (c.callee.*) {
                    .identifier => |id| id.name,
                    else => {
                        // 非函数名调用：先编译为 lambda 变量，然后 spawn
                        const lambda_chan = try self.compileExpr(expr);
                        return lambda_chan;
                    },
                };

                if (self.func_table.get(func_name)) |func_idx| {
                    const func = self.functions.items[func_idx];
                    if (func.is_async) {
                        // 编译参数为通道
                        var arg_chans_buf: [4]u16 = .{ 0, 0, 0, 0 };
                        const arg_count = @min(c.arguments.len, 4);
                        for (0..arg_count) |ai| {
                            arg_chans_buf[ai] = try self.compileExpr(c.arguments[ai]);
                        }
                        return try self.emitOrbitCreate(func_idx, arg_chans_buf[0..arg_count], func, try self.typeArgsFromCallExpr(expr));
                    }
                    // 非 async 函数：包装为 async lambda 后 spawn
                    // 简化：直接调用（同步执行）
                    return try self.compileCallWithTypeArgs(c.callee, c.arguments, c.type_args, expr);
                }

                // 未知函数：尝试构造器或内置
                return try self.compileCallWithTypeArgs(c.callee, c.arguments, c.type_args, expr);
            },
            .lambda => |lam| {
                // 编译 lambda 为 async 闭包，然后 spawn
                const lambda_chan = try self.compileLambda(lam);
                // 对于 spawn，直接返回 lambda 通道
                // 完整实现需要将 lambda 包装为 async task
                return lambda_chan;
            },
            else => {
                // 其他表达式：直接编译（可能只是引用一个已有的 async handle）
                return try self.compileExpr(expr);
            },
        }
    }

    /// 编译 inline_trait_value：trait { methods } → record of closures
    /// 每个方法编译为闭包，存储在 record 字段中
    pub fn compileInlineTraitValue(self: *IRBuilder, methods: []ast.MethodDecl) BuildError!u16 {
        // 创建一个 record，每个方法作为一个字段
        const field_count = methods.len;
        const len_chan = try self.allocChannel(type_descriptor_mod.i64_descriptor);
        const len_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = @intCast(field_count) } });
        try self.emit(Node.makeSink(.const_i, len_chan, len_meta));

        const record_chan = try self.allocChannel(type_descriptor_mod.ref_descriptor);
        try self.emit(Node.makeUnary(.array_make, record_chan, 0, len_chan));

        // 为每个方法创建闭包并存储到 record
        for (methods, 0..) |*method, i| {
            // 编译方法体为 lambda
            const method_chan = blk: {
                if (method.body) |body| {
                    // 有方法体：构造 lambda Expr 并编译
                    const lam_expr = self.arena.allocator().create(ast.Expr) catch return error.OutOfMemory;
                    lam_expr.* = .{ .lambda = .{
                        .params = method.params,
                        .body = .{ .block = body },
                        .is_async = false,
                        .return_type = method.return_type,
                    } };
                    break :blk try self.compileExpr(lam_expr);
                } else {
                    // 无方法体：存储 unit
                    const ch = try self.allocChannel(type_descriptor_mod.unit_descriptor);
                    try self.emit(Node.makeSink(.const_unit, ch, 0));
                    break :blk ch;
                }
            };

            const idx_chan = try self.allocChannel(type_descriptor_mod.i64_descriptor);
            const idx_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = @intCast(i) } });
            try self.emit(Node.makeSink(.const_i, idx_chan, idx_meta));
            try self.emit(Node.makeTernary(.array_set, record_chan, 0, record_chan, idx_chan, method_chan));
        }

        return record_chan;
    }

    /// 编译模块引用为 trait 值：Module.Sub → record of closures
    /// 按 trait 方法顺序，为每个方法创建闭包包装对应的模块函数
    /// 支持任意深度路径：std.time.Calendar → 为 "std.time.Calendar.<method>" 创建包装器
    pub fn compileModuleTraitValue(self: *IRBuilder, mod_ref: ModuleRef, trait_name: []const u8) BuildError!u16 {
        const arena_alloc = self.arena.allocator();
        if (self.sema_result.getTraitDef(trait_name) == null) return error.UndefinedFunction;
        const trait_methods = self.findTraitMethodsAst(trait_name) orelse return error.UndefinedFunction;
        const method_count = trait_methods.len;

        // 创建数组：array_make(count)
        const len_chan = try self.allocChannel(type_descriptor_mod.i64_descriptor);
        const len_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = @intCast(method_count) } });
        try self.emit(Node.makeSink(.const_i, len_chan, len_meta));

        const record_chan = try self.allocChannel(type_descriptor_mod.ref_descriptor);
        try self.emit(Node.makeUnary(.array_make, record_chan, 0, len_chan));

        // 为每个 trait 方法创建闭包包装器
        for (trait_methods, 0..) |method, i| {
            // 查找模块函数（完整路径 + "." + 方法名）
            const mangled = try std.fmt.allocPrint(arena_alloc, "{s}.{s}", .{ mod_ref.full_path, method.name });
            const target_func_idx = self.func_table.get(mangled) orelse return error.UndefinedFunction;
            const target_func = self.functions.items[target_func_idx];

            // 创建匿名包装函数
            const wrapper_name = try std.fmt.allocPrint(arena_alloc, "__mod_trait_{d}", .{self.lambda_counter});
            self.lambda_counter += 1;
            const wrapper_idx: u16 = @intCast(self.functions.items.len);
            try self.func_table.put(wrapper_name, wrapper_idx);

            const return_type = self.chanTypeFromTypeNodeBound(method.return_type) orelse type_descriptor_mod.i64_descriptor;
            const wrapper_return_chan = try self.allocChannel(return_type);
            try self.functions.append(arena_alloc, .{
                .name = wrapper_name,
                .node_start = 0,
                .node_count = 0,
                .param_channels = &.{},
                .return_channel = wrapper_return_chan,
                .is_entry = false,
                .is_async = false,
            });

            // 编译函数体
            const saved_return_chan = self.current_return_chan;
            const saved_returns_throw = self.current_returns_throw;
            const saved_throw_ok_chan_type = self.current_throw_ok_type_desc;
            const node_start: u32 = @intCast(self.nodes.items.len);
            const chan_start: u16 = self.channels.count();

            try self.pushScope();

            // 分配参数通道（匹配 trait 方法签名）
            var param_chans = try arena_alloc.alloc(u16, method.params.len);
            for (method.params, 0..) |param, j| {
                const chan_type = if (param.type_annotation) |tn|
                    self.chanTypeFromTypeNodeBound(tn) orelse type_descriptor_mod.i64_descriptor
                else
                    type_descriptor_mod.i64_descriptor;
                const chan = try self.allocChannel(chan_type);
                param_chans[j] = chan;
                try self.defineVar(param.name, chan, false);
            }

            self.current_return_chan = wrapper_return_chan;
            self.current_returns_throw = isThrowType(method.return_type);
            if (self.current_returns_throw) {
                self.current_throw_ok_type_desc = throwOkChanType(method.return_type) orelse type_descriptor_mod.i64_descriptor;
            }

            // 发射 call 节点：调用模块函数
            const target_ret_type = self.channels.get(target_func.return_channel).type_desc;
            const call_out = try self.allocChannel(target_ret_type);
            const call_meta_idx = try self.addCallMeta(.{
                .func_index = target_func_idx,
                .arg_count = @intCast(param_chans.len),
            });
            var call_inputs: [4]u16 = .{ 0, 0, 0, 0 };
            for (param_chans, 0..) |ch, j| {
                if (j < 4) call_inputs[j] = ch;
            }
            try self.emit(Node{
                .op = .call,
                .input_count = @intCast(@min(param_chans.len, 4)),
                .output = call_out,
                .meta_index = call_meta_idx,
                .inputs = call_inputs,
            });

            // 处理 Throw 返回类型
            const final_chan = if (self.current_returns_throw) blk: {
                const wrap_out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
                const meta_idx = try self.addScalarMeta(.{ .kind = .ref });
                try self.emit(Node.makeUnary(.gate_make_ok, wrap_out, meta_idx, call_out));
                break :blk wrap_out;
            } else call_out;

            // 发射 halt_return
            try self.emit(Node.makeUnary(.halt_return, wrapper_return_chan, 0, final_chan));

            self.current_return_chan = saved_return_chan;
            self.current_returns_throw = saved_returns_throw;
            self.current_throw_ok_type_desc = saved_throw_ok_chan_type;
            self.popScope();

            const node_count: u32 = @intCast(self.nodes.items.len - node_start);
            const chan_end: u16 = self.channels.count();
            self.functions.items[wrapper_idx].node_start = node_start;
            self.functions.items[wrapper_idx].node_count = node_count;
            self.functions.items[wrapper_idx].param_channels = param_chans;
            self.functions.items[wrapper_idx].local_chan_start = chan_start;
            self.functions.items[wrapper_idx].local_chan_count = chan_end - chan_start;

            // 发射 closure_make（无上值）
            const closure_meta_idx = try self.addClosureMeta(.{
                .func_index = wrapper_idx,
                .upvalue_count = 0,
                .result_type_desc = return_type,
                .body_start = node_start,
                .body_len = node_count,
                .cell_upvalues = 0,
            });

            const closure_chan = try self.allocChannel(type_descriptor_mod.ref_descriptor);
            try self.emit(Node{
                .op = .closure_make,
                .input_count = 0,
                .output = closure_chan,
                .meta_index = closure_meta_idx,
                .inputs = .{ 0, 0, 0, 0 },
            });

            // 存入数组：array_set(record, idx, closure)
            const idx_chan = try self.allocChannel(type_descriptor_mod.i64_descriptor);
            const idx_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = @intCast(i) } });
            try self.emit(Node.makeSink(.const_i, idx_chan, idx_meta));
            try self.emit(Node.makeTernary(.array_set, record_chan, 0, record_chan, idx_chan, closure_chan));
        }

        return record_chan;
    }

    /// 编译 Elvis 操作符 (left ?? right)：left 非 null 取 left，否则取 right
    /// 等价于 nullable_unwrap_or
    pub fn compileElvis(self: *IRBuilder, left: *const ast.Expr, right: *const ast.Expr) BuildError!u16 {
        const left_chan = try self.compileExpr(left);
        const right_chan = try self.compileExpr(right);
        const left_meta = self.channels.get(left_chan);

        // null_literal：直接返回 right（值确定为 null）
        if (left_meta.type_desc.is_null_type) {
            return right_chan;
        }

        // 如果 left 不是 nullable/ref，直接返回 left（不可能为 null）
        if (!left_meta.type_desc.is_nullable and !left_meta.type_desc.is_ref) {
            return left_chan;
        }

        // 如果是 ref_chan，包装为 nullable
        const nullable_chan = if (left_meta.type_desc.is_nullable)
            left_chan
        else blk: {
            const nc = try self.channels.allocNullable(left_meta.type_desc);
            try self.emit(Node.makeUnary(.nullable_make, nc, 0, left_chan));
            break :blk nc;
        };

        // nullable_unwrap_or(nullable_chan, right_chan)
        const inner_type = if (left_meta.type_desc.is_nullable) (left_meta.inner_type_desc orelse type_descriptor_mod.i64_descriptor) else left_meta.type_desc;
        const out = try self.allocChannel(inner_type);
        try self.emit(Node.makeBinary(.nullable_unwrap_or, out, 0, nullable_chan, right_chan));
        return out;
    }

    /// 判断表达式是否直接产生 ThrowValue（无需再包装）
    /// Ok(...) / Error(...) 内建构造器产生 ThrowValue；throw 语句本身是 halt 不返回值
    /// 调用返回 Throw 的函数/lambda 也产生 ThrowValue
    pub fn exprIsThrowValue(self: *IRBuilder, expr: *const ast.Expr) bool {
        return switch (expr.*) {
            .call => |c| switch (c.callee.*) {
                .identifier => |id| blk: {
                    if (std.mem.eql(u8, id.name, "Ok") or std.mem.eql(u8, id.name, "Error")) break :blk true;
                    // 检查是否为返回 Throw 的函数调用
                    if (self.findFuncReturnTypeAst(id.name)) |rt| {
                        if (isThrowType(rt)) break :blk true;
                    }
                    // 检查是否为返回 Throw 的 lambda 变量调用（跨作用域持久集合）
                    if (self.lambda_returns_throw.contains(id.name)) break :blk true;
                    // 也检查当前作用域中的变量绑定（同作用域内有效）
                    if (self.lookupVar(id.name)) |binding| {
                        if (binding.type_annotation) |ta| {
                            if (isThrowType(ta)) break :blk true;
                        }
                    }
                    break :blk false;
                },
                else => false,
            },
            // 块表达式：检查 trailing_expr 或最后一条语句是否为 throw
            .block => |b| blk: {
                if (b.trailing_expr) |te| {
                    if (self.exprIsThrowValue(te)) break :blk true;
                }
                // 检查最后一条语句是否为 throw_stmt
                if (b.statements.len > 0) {
                    if (b.statements[b.statements.len - 1].* == .throw_stmt) break :blk true;
                }
                break :blk false;
            },
            // if 表达式：任一分支产生 ThrowValue 则整体为 ThrowValue
            .if_expr => |ie| blk: {
                if (self.exprIsThrowValue(ie.then_branch)) break :blk true;
                if (ie.else_branch) |eb| {
                    if (self.exprIsThrowValue(eb)) break :blk true;
                }
                break :blk false;
            },
            // match 表达式：任一 arm 的 body 产生 ThrowValue 则整体为 ThrowValue
            .match => |m| blk: {
                for (m.arms) |arm| {
                    if (self.exprIsThrowValue(arm.body)) break :blk true;
                }
                break :blk false;
            },
            // propagate (? 操作符)：内部表达式为 ThrowValue
            .propagate => |p| self.exprIsThrowValue(p.expr),
            else => false,
        };
    }

    /// 解析 type alias 后再推导类型描述符
    /// 委托 sema type_resolver.resolveTypeNodeResolved，传入当前实例的 type_args
    /// 和 sema_result（用于 alias/newtype 链展开）。
    /// 替代原 IR 侧 pending_alias_targets + type_binding_stack 双轨实现。
    pub fn chanTypeFromTypeNodeResolved(self: *IRBuilder, type_node: ?*ast.TypeNode) ?*const type_descriptor_mod.TypeDescriptor {
        return sema_type_resolver.resolveTypeNodeResolved(
            type_node,
            self.current_type_args,
            self.sema_result,
        );
    }

    /// 单态化：带类型绑定的 TypeNode → TypeDescriptor 解析
    /// 委托 sema type_resolver.chanTypeFromTypeNodeBound，传入 current_type_args。
    /// sema 已是类型绑定的权威来源（instance.type_args），IR 不再维护独立绑定栈。
    pub fn chanTypeFromTypeNodeBound(self: *IRBuilder, type_node: ?*ast.TypeNode) ?*const type_descriptor_mod.TypeDescriptor {
        return sema_type_resolver.chanTypeFromTypeNodeBound(
            type_node,
            self.current_type_args,
            null,
        );
    }

    /// field_value 标量单态化：从当前实例 type_args 解析 T 的标量 inner 类型
    /// 遍历 current_type_args，若存在 newtype/nullable 且 inner 为标量，返回具体标量 TypeDescriptor
    /// 否则返回 ref_descriptor（运行时通过 Cell 装箱中转标量引用）
    pub fn resolveFieldValueChanType(self: *IRBuilder) *const type_descriptor_mod.TypeDescriptor {
        for (self.current_type_args) |ta| {
            // newtype/nullable：查 sema type_defs 获取 inner 类型
            if (self.sema_result.getTypeDef(ta.type_name)) |td_info| {
                if (td_info.target_type_desc) |inner_td| {
                    if (!inner_td.is_ref) return inner_td;
                }
            }
        }
        return type_descriptor_mod.ref_descriptor;
    }

    /// 单态化：type_id → TypeDescriptor
    /// 委托 sema type_resolver.chanTypeFromTypeId，查 sema_result.type_descriptors 全局表。
    /// type_id 0 = 未知/泛型参数，返回 ref_descriptor。
    pub fn chanTypeFromTypeId(self: *IRBuilder, type_id: u16) *const type_descriptor_mod.TypeDescriptor {
        return sema_type_resolver.chanTypeFromTypeId(self.sema_result, type_id);
    }

    /// 单态化：TypeDescriptor → type_id（反查 type_name_to_id）
    /// 用于从实参的 sema chan_type 直接推导 type_id，处理 int_literal 等无 type_name 的表达式
    pub fn chanTypeToTypeId(self: *IRBuilder, ct: *const type_descriptor_mod.TypeDescriptor) u16 {
        const name = ct.type_name;
        // 标量类型直接使用 type_name 查询；非标量类型（ref/null/mask/nullable）无对应 type_id
        if (ct.isInt() or ct.isFloat() or
            ct == type_descriptor_mod.bool_descriptor or
            ct == type_descriptor_mod.char_descriptor or
            ct == type_descriptor_mod.unit_descriptor)
        {
            return self.type_name_to_id.get(name) orelse 0;
        }
        return 0;
    }

};
