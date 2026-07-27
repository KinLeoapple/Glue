//! Statement 编译器（v3 阶段 4：从 builder.zig 物理拆分）
//!
//! 包含 block/stmt/for/while/loop/defer/throw/select 等语句相关的编译方法。
//! 通过 pub const 别名注入 IRBuilder（Zig 0.16 已移除 usingnamespace）。

const std = @import("std");
const ast = @import("ast");
const node_mod = @import("node.zig");
const builder_mod = @import("builder.zig");

const IRBuilder = builder_mod.IRBuilder;
const BuildError = builder_mod.BuildError;
const Node = node_mod.Node;
const NodeOp = node_mod.NodeOp;
const ScalarKind = builder_mod.ScalarKind;

pub const Methods = struct {
    // ════════════════════════════════════════════
    // 语句编译
    // ════════════════════════════════════════════

    /// compound_assignment op → BinaryOp 映射（v3 阶段 14：消除 4 处重复 switch）
    pub fn compoundAssignOpToBinaryOp(op: ast.CompoundAssignOp) ast.BinaryOp {
        return switch (op) {
            .add_assign => .add,
            .sub_assign => .sub,
            .mul_assign => .mul,
            .div_assign => .div,
            .mod_assign => .mod,
            .bit_and_assign => .bit_and,
            .bit_or_assign => .bit_or,
            .bit_xor_assign => .bit_xor,
            .shl_assign => .shl,
            .shr_assign => .shr,
        };
    }

    pub fn compileBlock(self: *IRBuilder, statements: []*ast.Stmt, trailing_expr: ?*ast.Expr) BuildError!u16 {
        try self.pushScope();
        defer self.popScope();

        // statements 不在尾位置：防止 val_decl 中的函数调用被错误标记为 tail_call
        // 只有 trailing_expr 继承尾位置
        const saved_tail = self.in_tail_position;
        self.in_tail_position = false;
        var last_stmt_chan: ?u16 = null;
        for (statements) |stmt| {
            last_stmt_chan = try self.compileStmt(stmt);
        }
        self.in_tail_position = saved_tail;

        if (trailing_expr) |te| {
            return self.compileExpr(te);
        }
        // 无尾表达式：如果最后一条语句产生了值（for/while），使用它
        if (last_stmt_chan) |ch| return ch;
        // 否则返回 unit
        const out = try self.allocChannel(.unit_chan);
        try self.emit(Node.makeSink(.const_unit, out, 0));
        return out;
    }

    pub fn compileStmt(self: *IRBuilder, stmt: *const ast.Stmt) BuildError!?u16 {
        switch (stmt.*) {
            .val_decl => |vd| {
                // 对于 lambda 值，预声明名字以支持递归引用
                if (vd.value.* == .lambda) {
                    self.pre_declared_lambda_names.append(self.allocator, vd.name) catch return error.OutOfMemory;
                    const chan = try self.compileExpr(vd.value);
                    _ = self.pre_declared_lambda_names.pop();
                    // lambda 编译时已在 compileLambda 中预声明了名字，
                    // 但仍需确保 binding 存储了 ast_expr（用于类型推断）
                    // 查找已有 binding 并更新 ast_expr
                    self.updateVarAstExpr(vd.name, vd.value);
                    _ = chan;
                } else {
                    var chan = try self.compileExpr(vd.value);
                    // 类型标注为 nullable 时，将值包装为 nullable_chan
                    if (vd.type_annotation) |tn| {
                        if (tn.* == .nullable) {
                            const value_meta = self.channels.get(chan);
                            if (value_meta.chan_type == .null_chan) {
                                // null_literal → 分配 nullable 通道，nullable_make 会写入 null flag
                                const inner_ct = builder_mod.chanTypeFromTypeNode(tn.nullable.inner) orelse .ref_chan;
                                const nc = try self.channels.allocNullable(inner_ct);
                                try self.emit(Node.makeUnary(.nullable_make, nc, 0, chan));
                                chan = nc;
                            } else if (value_meta.chan_type != .nullable_chan) {
                                // 非 null 值 → 包装为 nullable
                                const nc = try self.channels.allocNullable(value_meta.chan_type);
                                try self.emit(Node.makeUnary(.nullable_make, nc, 0, chan));
                                chan = nc;
                            }
                        } else {
                            // 标量类型标注：字面量默认 i64 与标注类型（如 i32）不匹配时，
                            // 插入 cast 节点将值转换为标注类型，避免后续二元运算跨宽度读取
                            const dst_ct = self.chanTypeFromTypeNodeResolved(tn);
                            if (dst_ct) |ct| {
                                const src_meta = self.channels.get(chan);
                                // 仅在 src 和 dst 都是标量类型（int/float）时才插入 cast；
                                // 否则（如 dst 为 ref_chan/Lazy 等堆引用）跳过 cast，避免把
                                // 整数值误转换为 f64 位模式后存入 ref_chan 导致 readStr 误读为指针
                                if (src_meta.chan_type != ct and (src_meta.chan_type.isInt() or src_meta.chan_type.isFloat()) and (ct.isInt() or ct.isFloat())) {
                                    const cast_chan = try self.allocChannel(ct);
                                    const kind: ScalarKind = if (ct.isInt()) .int else .float;
                                    const meta_idx = try self.addScalarMeta(.{
                                        .kind = kind,
                                        .int_kind = ct.toIntKind() orelse .i64,
                                        .float_kind = ct.toFloatKind() orelse .f64,
                                    });
                                    try self.emit(Node.makeUnary(.cast, cast_chan, meta_idx, chan));
                                    chan = cast_chan;
                                }
                            }
                        }
                    }
                    // val 绑定也遵循值语义：复合类型值深拷贝后绑定到独立通道
                    // 例外：AsyncHandle 是共享引用（类似 Arc），深拷贝会破坏 orbit 句柄
                    // 与 async_handle_meta 映射，因此使用浅拷贝（_pad=1）并传播映射
                    const final_chan = blk: {
                        const src_meta = self.channels.get(chan);
                        if (src_meta.chan_type == .ref_chan and !self.isRefExpr(vd.value)) {
                            const is_async_handle = self.async_handle_meta.get(chan) != null;
                            const copy_chan = try self.allocChannel(.ref_chan);
                            var load_node = Node.makeUnary(.load, copy_chan, 0, chan);
                            load_node._pad = if (is_async_handle) 1 else 0;
                            try self.emit(load_node);
                            if (is_async_handle) {
                                if (self.async_handle_meta.get(chan)) |orbit_meta_idx| {
                                    self.async_handle_meta.put(copy_chan, orbit_meta_idx) catch return error.OutOfMemory;
                                }
                            }
                            break :blk copy_chan;
                        }
                        break :blk chan;
                    };
                    try self.scopeVarTyped(vd.name, final_chan, false, vd.value, vd.type_annotation);
                    // 传播 is_atomic：atomic_expr 或原子标识符赋值
                    if (vd.value.* == .atomic_expr) {
                        self.markLastBindingAtomic();
                    } else if (vd.value.* == .identifier) {
                        if (self.isAtomicBinding(vd.value.identifier.name)) self.markLastBindingAtomic();
                    }
                }
            },
            .var_decl => |vd| {
                var value_chan = try self.compileExpr(vd.value);
                var value_meta = self.channels.get(value_chan);
                // 类型标注为 nullable 时，将值包装为 nullable_chan
                if (vd.type_annotation) |tn| {
                    if (tn.* == .nullable) {
                        if (value_meta.chan_type == .null_chan) {
                            const inner_ct = builder_mod.chanTypeFromTypeNode(tn.nullable.inner) orelse .ref_chan;
                            const nc = try self.channels.allocNullable(inner_ct);
                            try self.emit(Node.makeUnary(.nullable_make, nc, 0, value_chan));
                            value_chan = nc;
                            value_meta = self.channels.get(value_chan);
                        } else if (value_meta.chan_type != .nullable_chan) {
                            const nc = try self.channels.allocNullable(value_meta.chan_type);
                            try self.emit(Node.makeUnary(.nullable_make, nc, 0, value_chan));
                            value_chan = nc;
                            value_meta = self.channels.get(value_chan);
                        }
                    }
                }
                // 标量类型标注：值类型（如 usize）与标注类型（如 i32）不匹配时，
                // 插入 cast 节点将值转换为标注类型（与 val_decl 一致）
                if (vd.type_annotation) |tn| {
                    if (tn.* != .nullable) {
                        const dst_ct = self.chanTypeFromTypeNodeResolved(tn);
                        if (dst_ct) |ct| {
                            const src_meta = self.channels.get(value_chan);
                            if (src_meta.chan_type != ct and (src_meta.chan_type.isInt() or src_meta.chan_type.isFloat()) and (ct.isInt() or ct.isFloat())) {
                                const cast_chan = try self.allocChannel(ct);
                                const kind: ScalarKind = if (ct.isInt()) .int else .float;
                                const meta_idx = try self.addScalarMeta(.{
                                    .kind = kind,
                                    .int_kind = ct.toIntKind() orelse .i64,
                                    .float_kind = ct.toFloatKind() orelse .f64,
                                });
                                try self.emit(Node.makeUnary(.cast, cast_chan, meta_idx, value_chan));
                                value_chan = cast_chan;
                                value_meta = self.channels.get(value_chan);
                            }
                        }
                    }
                }
                // 优先使用类型标注的 chan_type 作为 cell 类型；
                // 这避免了字面量默认类型（如 usize）与标注类型（如 i32）不匹配时
                // 引发的跨通道字节宽度错误（execCmp 读取超过源通道实际宽度）。
                const cell_ct = blk: {
                    if (vd.type_annotation) |tn| {
                        if (tn.* != .nullable) {
                            if (self.chanTypeFromTypeNodeResolved(tn)) |ct| break :blk ct;
                        }
                    }
                    break :blk value_meta.chan_type;
                };
                const cell_chan = try self.allocCellChannel(cell_ct);
                var load_node = Node.makeUnary(.load, cell_chan, 0, value_chan);
                // 源表达式为 &T / *T 或 AsyncHandle 时标记为引用，运行时 load 不深拷贝
                // AsyncHandle 是共享引用，深拷贝会破坏 orbit 句柄
                const var_is_async_handle = self.async_handle_meta.get(value_chan) != null;
                load_node._pad = if (self.isRefExpr(vd.value) or var_is_async_handle) 1 else 0;
                try self.emit(load_node);
                if (var_is_async_handle) {
                    if (self.async_handle_meta.get(value_chan)) |orbit_meta_idx| {
                        self.async_handle_meta.put(cell_chan, orbit_meta_idx) catch return error.OutOfMemory;
                    }
                }
                try self.scopeVarTyped(vd.name, cell_chan, true, vd.value, vd.type_annotation);
                // atomic 表达式 → 标记绑定为 Atomic
                if (vd.value.* == .atomic_expr) self.markLastBindingAtomic();
            },
            .assignment => |as| {
                switch (as.target.*) {
                    .identifier => |id| {
                        // _ = expr：丢弃表达式结果（常用于 ? 传播不需要 Ok 值时）
                        if (std.mem.eql(u8, id.name, "_")) {
                            _ = try self.compileExpr(as.value);
                        } else {
                            const binding = self.lookupVar(id.name) orelse return error.UnboundVariable;
                            const value_chan = try self.compileExpr(as.value);
                            var store_node = Node.makeUnary(.store, binding.chan, 0, value_chan);
                            store_node._pad = if (self.isRefExpr(as.value)) 1 else 0;
                            try self.emit(store_node);
                        }
                    },
                    .field_access => |fa| {
                        // obj.field = value → record_set(obj, field_id, value)
                        const obj_chan = try self.compileExpr(fa.object);
                        const value_chan = try self.compileExpr(as.value);
                        const field_id: u16 = blk: {
                            if (std.mem.eql(u8, fa.field, "__tag")) break :blk 0;
                            if (self.inferTypeNameFromExpr(fa.object)) |type_name| {
                                if (self.lookupFieldId(type_name, fa.field)) |id| break :blk id;
                            }
                            if (self.lookupFieldId("", fa.field)) |id| break :blk id;
                            break :blk 0;
                        };
                        const field_idx_meta = try self.addFieldIdMeta(field_id);
                        try self.emit(Node.makeBinary(.record_set, obj_chan, field_idx_meta, obj_chan, value_chan));
                    },
                    .index => |idx| {
                        // arr[i] = value → array_set(arr, idx, value)
                        const obj_chan = try self.compileExpr(idx.object);
                        const idx_chan = try self.compileExpr(idx.index);
                        const value_chan = try self.compileExpr(as.value);
                        try self.emit(Node.makeTernary(.array_set, obj_chan, 0, obj_chan, idx_chan, value_chan));
                    },
                    .deref => |d| {
                        // *ref = value → ref_set(ref, value)
                        const ref_chan = try self.compileExpr(d.operand);
                        const value_chan = try self.compileExpr(as.value);
                        const meta_idx = try self.addScalarMeta(.{ .kind = .ref });
                        try self.emit(Node.makeBinary(.ref_set, 0, meta_idx, ref_chan, value_chan));
                    },
                    else => return error.UnsupportedExpr,
                }
            },
            .compound_assignment => |ca| {
                switch (ca.target.*) {
                    .identifier => |id| {
                        const binding = self.lookupVar(id.name) orelse return error.UnboundVariable;
                        // Atomic += / -= → atomic_fetch_add（mutex 保护的原子读-改-写）
                        if (binding.is_atomic and (ca.op == .add_assign or ca.op == .sub_assign)) {
                            const val_chan = try self.compileExpr(ca.value);
                            const val_meta = self.channels.get(val_chan);
                            const out = try self.allocChannel(val_meta.chan_type);
                            var node = Node.makeBinary(.atomic_fetch_add, out, 0, binding.chan, val_chan);
                            node._pad = if (ca.op == .sub_assign) 1 else 0;
                            try self.emit(node);
                            return null;
                        }
                        const bin_op = compoundAssignOpToBinaryOp(ca.op);
                        const result_chan = try self.compileBinary(bin_op, ca.target, ca.value);
                        var store_node = Node.makeUnary(.store, binding.chan, 0, result_chan);
                        store_node._pad = if (self.isRefExpr(ca.value)) 1 else 0;
                        try self.emit(store_node);
                    },
                    .field_access => |fa| {
                        // obj.field op= value → record_get + op + record_set
                        const obj_chan = try self.compileExpr(fa.object);
                        const old_val_chan = try self.compileFieldAccess(fa.object, fa.field, ca.target);
                        const bin_op = compoundAssignOpToBinaryOp(ca.op);
                        const result_chan = try self.compileBinaryOpWithChan(bin_op, old_val_chan, ca.value);
                        // 解析 field_id
                        const field_id: u16 = blk: {
                            if (std.mem.eql(u8, fa.field, "__tag")) break :blk 0;
                            if (self.inferTypeNameFromExpr(fa.object)) |type_name| {
                                if (self.lookupFieldId(type_name, fa.field)) |id| break :blk id;
                            }
                            if (self.lookupFieldId("", fa.field)) |id| break :blk id;
                            break :blk 0;
                        };
                        const field_idx_meta = try self.addFieldIdMeta(field_id);
                        try self.emit(Node.makeBinary(.record_set, obj_chan, field_idx_meta, obj_chan, result_chan));
                    },
                    .index => |idx| {
                        // arr[i] op= value → array_get + op + array_set
                        const obj_chan = try self.compileExpr(idx.object);
                        const idx_chan = try self.compileExpr(idx.index);
                        const old_val_chan = try self.allocChannel(.ref_chan);
                        try self.emit(Node.makeBinary(.array_get, old_val_chan, 0, obj_chan, idx_chan));
                        const bin_op = compoundAssignOpToBinaryOp(ca.op);
                        const result_chan = try self.compileBinaryOpWithChan(bin_op, old_val_chan, ca.value);
                        try self.emit(Node.makeTernary(.array_set, obj_chan, 0, obj_chan, idx_chan, result_chan));
                    },
                    .deref => |d| {
                        // *ref op= value → ref_get + op + ref_set
                        const ref_chan = try self.compileExpr(d.operand);
                        const old_val_chan = try self.allocChannel(.ref_chan);
                        const get_meta = try self.addScalarMeta(.{ .kind = .ref });
                        try self.emit(Node.makeUnary(.ref_get, old_val_chan, get_meta, ref_chan));
                        const bin_op = compoundAssignOpToBinaryOp(ca.op);
                        const result_chan = try self.compileBinaryOpWithChan(bin_op, old_val_chan, ca.value);
                        const set_meta = try self.addScalarMeta(.{ .kind = .ref });
                        try self.emit(Node.makeBinary(.ref_set, 0, set_meta, ref_chan, result_chan));
                    },
                    else => return error.UnsupportedExpr,
                }
            },
            .expression => |es| {
                _ = try self.compileExpr(es.expr);
            },
            .return_stmt => |rs| {
                const ret_chan = self.current_return_chan orelse return error.UnsupportedStmt;
                const raw_chan = if (rs.value) |v| try self.compileExpr(v) else blk: {
                    const ch = try self.allocChannel(.unit_chan);
                    try self.emit(Node.makeSink(.const_unit, ch, 0));
                    break :blk ch;
                };
                const throw_wrapped = if (self.current_returns_throw and rs.value != null and !self.exprIsThrowValue(rs.value.?)) blk: {
                    const wrap_out = try self.allocChannel(.ref_chan);
                    const meta_idx = try self.addGateMeta(.{ .gate_kind = .make_ok });
                    try self.emit(Node.makeUnary(.gate_make_ok, wrap_out, meta_idx, raw_chan));
                    break :blk wrap_out;
                } else raw_chan;
                // 若返回通道为 nullable，包装返回值
                const ret_meta = self.channels.get(ret_chan);
                const value_chan = if (ret_meta.chan_type == .nullable_chan) blk: {
                    const body_meta = self.channels.get(throw_wrapped);
                    if (body_meta.chan_type == .nullable_chan) break :blk throw_wrapped;
                    const nc = try self.channels.allocNullable(ret_meta.inner_type);
                    try self.emit(Node.makeUnary(.nullable_make, nc, 0, throw_wrapped));
                    break :blk nc;
                } else throw_wrapped;
                try self.emit(Node.makeUnary(.halt_return, ret_chan, 0, value_chan));
            },
            .for_stmt => |fs| return try self.compileFor(fs),
            .while_stmt => |ws| return try self.compileWhile(ws),
            .loop_stmt => |ls| return try self.compileLoop(ls),
            .break_stmt => {
                const out = try self.allocChannel(.unit_chan);
                try self.emit(Node.makeSink(.halt_break, out, 0));
                return out;
            },
            .continue_stmt => {
                const out = try self.allocChannel(.unit_chan);
                try self.emit(Node.makeSink(.halt_continue, out, 0));
                return out;
            },
            .defer_stmt => |ds| try self.compileDefer(ds),
            .throw_stmt => |ts| return try self.compileThrow(ts),
            .field_assignment => |fa| {
                const obj_chan = try self.compileExpr(fa.object);
                const val_chan = try self.compileExpr(fa.value);
                // 解析 field_id
                const field_id: u16 = blk: {
                    if (std.mem.eql(u8, fa.field, "__tag")) break :blk 0;
                    if (self.inferTypeNameFromExpr(fa.object)) |type_name| {
                        if (self.lookupFieldId(type_name, fa.field)) |id| break :blk id;
                    }
                    if (self.lookupFieldId("", fa.field)) |id| break :blk id;
                    break :blk 0;
                };
                const field_meta_idx = try self.addFieldIdMeta(field_id);
                const out = try self.allocChannel(.unit_chan);
                try self.emit(Node.makeBinary(.record_set, out, field_meta_idx, obj_chan, val_chan));
            },
        }
        return null;
    }

    pub fn compileFor(self: *IRBuilder, fs: anytype) BuildError!u16 {
        // 含 break/continue 时尝试数据化（纯函数条件转 take_while/filter）
        if (self.containsBreakOrContinue(fs.body)) {
            if (try self.tryCompileForDataflow(fs)) |result| {
                return result;
            }
            return try self.compileForScalar(fs);
        }

        // 编译 iterable → vec_source 节点
        const src_vec_chan = try self.compileVecSource(fs.iterable);

        // 记录循环体起始位置
        const body_start: u32 = @intCast(self.nodes.items.len);

        // 在新作用域中编译循环体，绑定循环变量
        try self.pushScope();
        defer self.popScope();
        // 循环变量绑定到 vec_source 的元素通道
        // 推断元素类型名：从 iterable 类型名剥离 "[]"（如 "DirEntry[]" → "DirEntry"）
        // 使循环体内 `e.field` 能解析 field_id
        var elem_type_node: ?*ast.TypeNode = null;
        if (self.inferTypeNameFromExpr(fs.iterable)) |iter_ty| {
            if (IRBuilder.arrayElemTypeName(iter_ty)) |elem_ty| {
                elem_type_node = self.makeNamedTypeNode(elem_ty) catch null;
            }
        }
        try self.scopeVarTyped(fs.name, src_vec_chan, false, null, elem_type_node);

        // 编译循环体（结果通道由 body 子图的最后一个节点决定）
        _ = try self.compileExpr(fs.body);

        const body_len: u32 = @intCast(self.nodes.items.len - body_start);

        // 发射 vec_map 节点（引用循环体子图）
        const map_meta_idx = try self.addVectorMeta(.{
            .inner_op = .const_i, // 占位，实际由 body_start/body_len 决定
            .body_start = body_start,
            .body_len = body_len,
            .elem_type = self.channels.get(src_vec_chan).chan_type,
        });

        const map_out = try self.allocChannel(self.channels.get(src_vec_chan).chan_type);
        try self.emit(Node.makeUnary(.vec_map, map_out, map_meta_idx, src_vec_chan));

        // 发射 vec_sink 节点（取最后一个元素作为 for 表达式的值）
        const sink_meta_idx = try self.addVectorMeta(.{
            .vec_op = .sink_last,
            .elem_type = self.channels.get(src_vec_chan).chan_type,
        });
        const sink_out = try self.allocChannel(self.channels.get(src_vec_chan).chan_type);
        try self.emit(Node.makeUnary(.vec_sink, sink_out, sink_meta_idx, map_out));

        return sink_out;
    }

    /// 尝试将含 break/continue 的 for 循环编译为数据流 IR
    ///
    /// 支持形式：
    ///   for i in iterable {
    ///       if cond_break { break }
    ///       if cond_continue { continue }
    ///       body
    ///   }
    ///
    /// 转换为：vec_source |> [vec_take_while(¬cond_break)] |> [vec_filter(¬cond_continue)] |> vec_map(body) |> vec_sink
    ///
    /// 条件：break/continue 条件必须是纯函数（只引用 loop_var 和外部不可变 val 变量）
    /// 不满足时返回 null，回退到标量循环
    pub fn tryCompileForDataflow(self: *IRBuilder, fs: anytype) BuildError!?u16 {
        if (fs.body.* != .block) return null;
        const block = fs.body.block;

        // 1. 扫描 statements，提取 break/continue 条件
        var break_cond: ?*const ast.Expr = null;
        var continue_cond: ?*const ast.Expr = null;
        var break_count: u32 = 0;
        var continue_count: u32 = 0;

        for (block.statements) |stmt| {
            const bc = builder_mod.tryExtractBreakContinueCond(stmt) orelse continue;
            if (bc.is_break) {
                break_count += 1;
                break_cond = bc.cond;
            } else {
                continue_count += 1;
                continue_cond = bc.cond;
            }
        }

        if (break_count == 0 and continue_count == 0) return null;
        if (break_count > 1 or continue_count > 1) return null;

        // 1.5 验证剩余 body（非 break/continue if 的语句）不含嵌套的 break/continue
        // 嵌套在其他 if/match 中的 break/continue 无法数据化，回退 scalar
        for (block.statements) |stmt| {
            if (builder_mod.tryExtractBreakContinueCond(stmt) != null) continue;
            if (builder_mod.astContainsBreakOrContinueStmt(stmt)) return null;
        }
        if (block.trailing_expr) |te| {
            if (builder_mod.astContainsBreakOrContinueExpr(te)) return null;
        }

        // 2. 验证条件是纯函数（只引用 loop_var 和外部不可变 val 变量）
        if (break_cond) |bc| {
            if (!self.isPureCondition(bc, fs.name)) return null;
        }
        if (continue_cond) |cc| {
            if (!self.isPureCondition(cc, fs.name)) return null;
        }

        // 3. 编译 vec_source
        const src_vec_chan = try self.compileVecSource(fs.iterable);
        const elem_type = self.channels.get(src_vec_chan).chan_type;
        var cur_chan = src_vec_chan;

        // 4. [可选] vec_take_while(¬break_cond)
        if (break_cond) |bc| {
            cur_chan = try self.emitTakeWhileNegCond(cur_chan, bc, fs.name);
        }

        // 5. [可选] vec_filter(¬continue_cond)
        if (continue_cond) |cc| {
            cur_chan = try self.emitFilterNegCond(cur_chan, cc, fs.name);
        }

        // 6. vec_map(pure_body) — 编译 body 语句，跳过 break/continue if
        const body_start: u32 = @intCast(self.nodes.items.len);
        try self.pushScope();
        defer self.popScope();
        // 推断元素类型名（与 compileFor 一致）
        var elem_type_node: ?*ast.TypeNode = null;
        if (self.inferTypeNameFromExpr(fs.iterable)) |iter_ty| {
            if (IRBuilder.arrayElemTypeName(iter_ty)) |elem_ty| {
                elem_type_node = self.makeNamedTypeNode(elem_ty) catch null;
            }
        }
        try self.scopeVarTyped(fs.name, cur_chan, false, null, elem_type_node);

        const saved_tail = self.in_tail_position;
        self.in_tail_position = false;
        for (block.statements) |stmt| {
            if (builder_mod.tryExtractBreakContinueCond(stmt) != null) continue;
            _ = try self.compileStmt(stmt);
        }
        if (block.trailing_expr) |te| {
            self.in_tail_position = saved_tail;
            _ = try self.compileExpr(te);
        }
        self.in_tail_position = saved_tail;

        const body_len: u32 = @intCast(self.nodes.items.len - body_start);

        // body 非空时发射 vec_map；为空（只有 break/continue if）则跳过
        if (body_len > 0) {
            const map_meta_idx = try self.addVectorMeta(.{
                .inner_op = .const_i,
                .body_start = body_start,
                .body_len = body_len,
                .elem_type = elem_type,
            });
            const map_out = try self.allocChannel(elem_type);
            try self.emit(Node.makeUnary(.vec_map, map_out, map_meta_idx, cur_chan));
            cur_chan = map_out;
        }

        // 7. vec_sink（取最后一个元素作为 for 表达式的值）
        const sink_meta_idx = try self.addVectorMeta(.{
            .vec_op = .sink_last,
            .elem_type = elem_type,
        });
        const sink_out = try self.allocChannel(elem_type);
        try self.emit(Node.makeUnary(.vec_sink, sink_out, sink_meta_idx, cur_chan));

        return sink_out;
    }

    /// 发射 vec_take_while(¬break_cond) 节点
    /// break_cond 为 true 时终止循环，取反后作为 take_while 谓词
    pub fn emitTakeWhileNegCond(
        self: *IRBuilder,
        src_chan: u16,
        break_cond: *const ast.Expr,
        loop_var: []const u8,
    ) BuildError!u16 {
        const elem_type = self.channels.get(src_chan).chan_type;

        // 编译条件体（在 loop_var 作用域中，loop_var 绑定到 src_chan 当前元素）
        const cond_start: u32 = @intCast(self.nodes.items.len);
        try self.pushScope();
        defer self.popScope();
        try self.defineVar(loop_var, src_chan, false);

        const cond_chan = try self.compileExpr(break_cond);
        // 取反：¬break_cond
        const not_chan = try self.allocChannel(.bool_chan);
        try self.emit(Node.makeUnary(.bool_not, not_chan, 0, cond_chan));

        const cond_len: u32 = @intCast(self.nodes.items.len - cond_start);

        const tw_meta_idx = try self.addVectorMeta(.{
            .body_start = cond_start,
            .body_len = cond_len,
            .elem_type = .bool_chan,
        });
        const tw_out = try self.allocChannel(elem_type);
        try self.emit(Node.makeUnary(.vec_take_while, tw_out, tw_meta_idx, src_chan));
        return tw_out;
    }

    /// 发射 vec_filter(¬continue_cond) 节点
    /// continue_cond 为 true 时跳过当前元素，取反后作为 filter 谓词
    pub fn emitFilterNegCond(
        self: *IRBuilder,
        src_chan: u16,
        continue_cond: *const ast.Expr,
        loop_var: []const u8,
    ) BuildError!u16 {
        const elem_type = self.channels.get(src_chan).chan_type;

        const cond_start: u32 = @intCast(self.nodes.items.len);
        try self.pushScope();
        defer self.popScope();
        try self.defineVar(loop_var, src_chan, false);

        const cond_chan = try self.compileExpr(continue_cond);
        const not_chan = try self.allocChannel(.bool_chan);
        try self.emit(Node.makeUnary(.bool_not, not_chan, 0, cond_chan));

        const cond_len: u32 = @intCast(self.nodes.items.len - cond_start);

        const filt_meta_idx = try self.addVectorMeta(.{
            .body_start = cond_start,
            .body_len = cond_len,
            .elem_type = .bool_chan,
        });
        const filt_out = try self.allocChannel(elem_type);
        try self.emit(Node.makeUnary(.vec_filter, filt_out, filt_meta_idx, src_chan));
        return filt_out;
    }

    /// 检查条件是否为纯函数（只引用 loop_var 和外部不可变 val 变量）
    /// 不允许 call/method_call/field_access/index/赋值等副作用操作
    pub fn isPureCondition(self: *IRBuilder, expr: *const ast.Expr, loop_var: []const u8) bool {
        switch (expr.*) {
            .int_literal, .float_literal, .bool_literal, .char_literal, .string_literal, .null_literal, .unit_literal => return true,
            .identifier => |id| {
                if (std.mem.eql(u8, id.name, loop_var)) return true;
                // 外部变量必须是 val（不可变，is_cell=false）
                if (self.lookupVar(id.name)) |binding| {
                    return !binding.is_cell;
                }
                return false;
            },
            .binary => |b| return self.isPureCondition(b.left, loop_var) and self.isPureCondition(b.right, loop_var),
            .unary => |u| return self.isPureCondition(u.operand, loop_var),
            .ref_of => |r| return self.isPureCondition(r.operand, loop_var),
            .deref => |d| return self.isPureCondition(d.operand, loop_var),
            else => return false,
        }
    }

    /// 编译 while 循环
    ///
    /// 优先尝试模式识别：`while var < end { body; var = var + 1 }` → vec_source + vec_map
    /// 不匹配时回退到标量循环
    pub fn compileWhile(self: *IRBuilder, ws: anytype) BuildError!u16 {
        if (try self.tryCompileWhileAsVecMap(ws)) |result| {
            return result;
        }
        // 分块向量化：while var < end { body 含 break/continue } → vec_source + vec_take_while + vec_filter + vec_map + vec_sink
        if (try self.tryCompileWhileChunked(ws)) |result| {
            return result;
        }
        return try self.compileWhileScalar(ws);
    }

    /// 分块向量化：while var < end { body; var += 1 }（body 含 break/continue）
    ///
    /// 条件：
    /// - condition 是 `var < end`（仅支持 <）
    /// - body 是 block，最后一条语句是 `var = var + 1` 或 `var += 1`
    /// - body 含 break/continue（否则由 tryCompileWhileAsVecMap 处理）
    /// - break/continue 条件是纯函数（仅依赖 var 和外部不可变变量）
    /// - var 是整数类型
    ///
    /// 转换为：vec_source(range, var, end) |> [vec_take_while(¬break_cond)] |> [vec_filter(¬continue_cond)] |> vec_map(body) |> vec_sink
    /// dispatch 从 O(N) 降到 O(1)（向量 op 一次 dispatch 处理整个向量）
    pub fn tryCompileWhileChunked(self: *IRBuilder, ws: anytype) BuildError!?u16 {
        // 1. 解析 condition: var < end
        if (ws.condition.* != .binary) return null;
        const bin = ws.condition.binary;
        if (bin.op != .lt) return null;
        if (bin.left.* != .identifier) return null;
        const var_name = bin.left.identifier.name;
        const end_expr = bin.right;

        // 2. 解析 body: block，最后一条是 var = var + 1 或 var += 1
        if (ws.body.* != .block) return null;
        const block = ws.body.block;
        if (block.statements.len == 0) return null;

        const last_stmt = block.statements[block.statements.len - 1];
        const body_stmts = block.statements[0 .. block.statements.len - 1];

        // 检查递增模式（与 tryCompileWhileAsVecMap 相同）
        var is_increment = false;
        if (last_stmt.* == .assignment) {
            const assign = last_stmt.assignment;
            if (assign.target.* == .identifier and
                std.mem.eql(u8, assign.target.identifier.name, var_name))
            {
                if (assign.value.* == .binary) {
                    const inc = assign.value.binary;
                    if (inc.op == .add) {
                        if (inc.left.* == .identifier and
                            std.mem.eql(u8, inc.left.identifier.name, var_name) and
                            inc.right.* == .int_literal and
                            std.mem.eql(u8, inc.right.int_literal.raw, "1"))
                        {
                            is_increment = true;
                        } else if (inc.right.* == .identifier and
                            std.mem.eql(u8, inc.right.identifier.name, var_name) and
                            inc.left.* == .int_literal and
                            std.mem.eql(u8, inc.left.int_literal.raw, "1"))
                        {
                            is_increment = true;
                        }
                    }
                }
            }
        } else if (last_stmt.* == .compound_assignment) {
            const ca = last_stmt.compound_assignment;
            if (ca.target.* == .identifier and
                std.mem.eql(u8, ca.target.identifier.name, var_name) and
                ca.op == .add_assign and
                ca.value.* == .int_literal and
                std.mem.eql(u8, ca.value.int_literal.raw, "1"))
            {
                is_increment = true;
            }
        }
        if (!is_increment) return null;

        // 3. 提取 break/continue 条件
        var break_cond: ?*const ast.Expr = null;
        var continue_cond: ?*const ast.Expr = null;
        var break_count: u32 = 0;
        var continue_count: u32 = 0;

        for (body_stmts) |stmt| {
            const bc = builder_mod.tryExtractBreakContinueCond(stmt) orelse continue;
            if (bc.is_break) {
                break_count += 1;
                break_cond = bc.cond;
            } else {
                continue_count += 1;
                continue_cond = bc.cond;
            }
        }

        // 必须含 break/continue（否则由 tryCompileWhileAsVecMap 处理）
        if (break_count == 0 and continue_count == 0) return null;
        if (break_count > 1 or continue_count > 1) return null;

        // 4. 验证剩余 body 不含嵌套 break/continue
        for (body_stmts) |stmt| {
            if (builder_mod.tryExtractBreakContinueCond(stmt) != null) continue;
            if (builder_mod.astContainsBreakOrContinueStmt(stmt)) return null;
        }
        if (block.trailing_expr) |te| {
            if (builder_mod.astContainsBreakOrContinueExpr(te)) return null;
        }

        // 5. 验证 break/continue 条件是纯函数
        if (break_cond) |bc| {
            if (!self.isPureCondition(bc, var_name)) return null;
        }
        if (continue_cond) |cc| {
            if (!self.isPureCondition(cc, var_name)) return null;
        }

        // 6. 获取 var 的当前通道（外部作用域）
        const var_binding = self.lookupVar(var_name) orelse return null;
        const start_chan = var_binding.chan;
        const var_chan = var_binding.chan;
        const elem_type = self.channels.get(start_chan).chan_type;
        if (!elem_type.isInt()) return null;

        // 7. 编译 end 表达式
        const end_chan = try self.compileExpr(end_expr);

        // 8. 生成 vec_source(range, start, end)
        var length: ?u32 = null;
        if (self.findConstVal(start_chan)) |sv| {
            if (self.findConstVal(end_chan)) |ev| {
                const s_val: i64 = @intCast(sv);
                const e_val: i64 = @intCast(ev);
                const len: i64 = e_val - s_val;
                if (len >= 0) length = @intCast(len);
            }
        }

        const source_meta_idx = try self.addVectorMeta(.{
            .vec_op = .range_source,
            .length = length,
            .elem_type = elem_type,
        });
        const src_vec_chan = try self.allocChannel(elem_type);
        try self.emit(Node.makeBinary(.vec_source, src_vec_chan, source_meta_idx, start_chan, end_chan));
        var cur_chan = src_vec_chan;

        // 9. [可选] vec_take_while(¬break_cond)
        if (break_cond) |bc| {
            cur_chan = try self.emitTakeWhileNegCond(cur_chan, bc, var_name);
        }

        // 10. [可选] vec_filter(¬continue_cond)
        if (continue_cond) |cc| {
            cur_chan = try self.emitFilterNegCond(cur_chan, cc, var_name);
        }

        // 11. vec_map(body) — 编译 body 语句，跳过 break/continue if
        try self.pushScope();
        defer self.popScope();
        try self.defineVar(var_name, cur_chan, false);

        const saved_tail = self.in_tail_position;
        self.in_tail_position = false;
        const body_start: u32 = @intCast(self.nodes.items.len);
        for (body_stmts) |stmt| {
            if (builder_mod.tryExtractBreakContinueCond(stmt) != null) continue;
            _ = try self.compileStmt(stmt);
        }
        if (block.trailing_expr) |te| {
            self.in_tail_position = saved_tail;
            _ = try self.compileExpr(te);
        }
        self.in_tail_position = saved_tail;

        const body_len: u32 = @intCast(self.nodes.items.len - body_start);

        if (body_len > 0) {
            const map_meta_idx = try self.addVectorMeta(.{
                .inner_op = .const_i,
                .body_start = body_start,
                .body_len = body_len,
                .elem_type = elem_type,
            });
            const map_out = try self.allocChannel(elem_type);
            try self.emit(Node.makeUnary(.vec_map, map_out, map_meta_idx, cur_chan));
            cur_chan = map_out;
        }

        // 12. vec_sink（取最后一个元素）
        const sink_meta_idx = try self.addVectorMeta(.{
            .vec_op = .sink_last,
            .elem_type = elem_type,
        });
        const sink_out = try self.allocChannel(elem_type);
        try self.emit(Node.makeUnary(.vec_sink, sink_out, sink_meta_idx, cur_chan));

        // 13. 循环后更新 var 通道值（语义保持：while i < N 结束后 i == N）
        try self.emit(Node.makeUnary(.store, var_chan, 0, end_chan));

        return sink_out;
    }

    /// 模式识别：while var < end { body; var = var + 1 } → vec_source(range) + vec_map(body)
    ///
    /// 条件：
    /// - condition 是 `var < end`（仅支持 <，不支持 <=）
    /// - body 是 block，最后一条语句是 `var = var + 1` 或 `var += 1`
    /// - body 不含 break/continue
    /// - var 是整数类型
    ///
    /// 转换后：dispatch 从 O(N) 降到 O(1)（vec_map 一次 dispatch 处理整个向量）
    /// 循环后更新 var = end（语义保持）
    pub fn tryCompileWhileAsVecMap(self: *IRBuilder, ws: anytype) BuildError!?u16 {
        // 1. 解析 condition: var < end
        if (ws.condition.* != .binary) return null;
        const bin = ws.condition.binary;
        if (bin.op != .lt) return null;
        if (bin.left.* != .identifier) return null;
        const var_name = bin.left.identifier.name;
        const end_expr = bin.right;

        // 2. 解析 body: block，最后一条是 var = var + 1 或 var += 1
        if (ws.body.* != .block) return null;
        const block = ws.body.block;
        if (block.statements.len == 0) return null;

        const last_stmt = block.statements[block.statements.len - 1];
        const body_stmts = block.statements[0 .. block.statements.len - 1];

        // 检查递增模式
        var is_increment = false;

        // 情况 1: assignment (var = var + 1)
        if (last_stmt.* == .assignment) {
            const assign = last_stmt.assignment;
            if (assign.target.* == .identifier and
                std.mem.eql(u8, assign.target.identifier.name, var_name))
            {
                if (assign.value.* == .binary) {
                    const inc = assign.value.binary;
                    if (inc.op == .add) {
                        // var + 1 或 1 + var
                        if (inc.left.* == .identifier and
                            std.mem.eql(u8, inc.left.identifier.name, var_name) and
                            inc.right.* == .int_literal and
                            std.mem.eql(u8, inc.right.int_literal.raw, "1"))
                        {
                            is_increment = true;
                        } else if (inc.right.* == .identifier and
                            std.mem.eql(u8, inc.right.identifier.name, var_name) and
                            inc.left.* == .int_literal and
                            std.mem.eql(u8, inc.left.int_literal.raw, "1"))
                        {
                            is_increment = true;
                        }
                    }
                }
            }
        }
        // 情况 2: compound_assignment (var += 1)
        else if (last_stmt.* == .compound_assignment) {
            const ca = last_stmt.compound_assignment;
            if (ca.target.* == .identifier and
                std.mem.eql(u8, ca.target.identifier.name, var_name) and
                ca.op == .add_assign and
                ca.value.* == .int_literal and
                std.mem.eql(u8, ca.value.int_literal.raw, "1"))
            {
                is_increment = true;
            }
        }

        if (!is_increment) return null;

        // 3. 检查 body 不含 break/continue
        for (body_stmts) |stmt| {
            if (builder_mod.astContainsBreakOrContinueStmt(stmt)) return null;
        }
        if (block.trailing_expr) |te| {
            if (builder_mod.astContainsBreakOrContinueExpr(te)) return null;
        }

        // 3.5 累加器模式检测：检测 body 是否为「纯表达式 + 单一累加器更新」结构
        // 若累加器更新是简单结合运算（acc = acc + expr / acc += expr / acc *= expr 等），
        // 则可拆分为 vec_map(expr) + vec_fold(op, init, t_vec)，实现真正的 O(1) dispatch。
        // 非简单结合运算（含 %、/ 等）或多个累加器 → 回退标量循环。
        var acc_info: ?struct { name: []const u8, op: NodeOp } = null;
        for (body_stmts) |stmt| {
            if (builder_mod.astContainsBreakOrContinueStmt(stmt)) return null;
            // 尝试匹配 acc = acc OP expr 或 acc OP= expr
            if (builder_mod.extractAccumulatorPattern(stmt, var_name)) |ap| {
                if (acc_info) |existing| {
                    if (!std.mem.eql(u8, existing.name, ap.acc_name)) return null;
                    if (existing.op != ap.fold_op) return null;
                } else {
                    acc_info = .{ .name = ap.acc_name, .op = ap.fold_op };
                }
            } else {
                // 非累加器语句：检查是否有其他外部赋值
                if (builder_mod.astContainsExternalAssignStmt(stmt, var_name)) return null;
            }
        }
        if (block.trailing_expr) |te| {
            if (builder_mod.astContainsBreakOrContinueExpr(te)) return null;
            if (builder_mod.astContainsExternalAssignExpr(te, var_name)) return null;
        }

        // 4. 获取 var 的当前通道（外部作用域）
        const var_binding = self.lookupVar(var_name) orelse return null;
        const start_chan = var_binding.chan;
        const var_chan = var_binding.chan;

        // 4.5 累加器模式：获取 init 值和拆分 body
        // 仅支持简单结合运算（add/mul/band/bor/bxor）→ vec_fold
        // 非结合运算（sub/div/mod）→ 回退标量循环（保持原行为）
        if (acc_info) |ai| {
            const fold_op = ai.op;
            // 仅 add/mul/and/or/xor 可安全 vec_fold（结合律）
            const is_associative = switch (fold_op) {
                .int_add, .int_mul, .int_and, .int_or, .int_xor => true,
                else => false,
            };
            if (!is_associative) return null;

            // 获取累加器通道和初始值
            const acc_binding = self.lookupVar(ai.name) orelse return null;
            const acc_chan = acc_binding.chan;
            const acc_type = self.channels.get(acc_chan).chan_type;

            // 5. 编译 end 表达式
            const end_chan = try self.compileExpr(end_expr);

            // 6. 获取元素类型
            const elem_type = self.channels.get(start_chan).chan_type;
            if (!elem_type.isInt()) return null;
            if (acc_type != elem_type) return null; // 类型必须一致

            // 7. 生成 vec_source(range)
            var length: ?u32 = null;
            if (self.findConstVal(start_chan)) |sv| {
                if (self.findConstVal(end_chan)) |ev| {
                    const s_val: i64 = @intCast(sv);
                    const e_val: i64 = @intCast(ev);
                    const len: i64 = e_val - s_val;
                    if (len >= 0) length = @intCast(len);
                }
            }

            const source_meta_idx = try self.addVectorMeta(.{
                .vec_op = .range_source,
                .length = length,
                .elem_type = elem_type,
            });
            const src_vec_chan = try self.allocChannel(elem_type);
            try self.emit(Node.makeBinary(.vec_source, src_vec_chan, source_meta_idx, start_chan, end_chan));

            // 8. 在新作用域中编译 body 表达式部分（排除累加器赋值语句）
            // body_expr 提取累加器更新中的右值表达式，编译为 vec_map
            try self.pushScope();
            defer self.popScope();
            try self.defineVar(var_name, src_vec_chan, false);

            const body_start: u32 = @intCast(self.nodes.items.len);
            // 编译非累加器语句
            for (body_stmts) |stmt| {
                if (builder_mod.extractAccumulatorPattern(stmt, var_name)) |ap| {
                    // 累加器语句：编译右值表达式（f(i) 部分）
                    _ = try self.compileExpr(ap.value_expr);
                } else {
                    _ = try self.compileStmt(stmt);
                }
            }
            if (block.trailing_expr) |te| {
                _ = try self.compileExpr(te);
            }
            const body_len: u32 = @intCast(self.nodes.items.len - body_start);

            // 9. 生成 vec_map（body 表达式 → t_vec）
            const map_meta_idx = try self.addVectorMeta(.{
                .inner_op = .const_i,
                .body_start = body_start,
                .body_len = body_len,
                .elem_type = elem_type,
            });
            const map_out = try self.allocChannel(elem_type);
            try self.emit(Node.makeUnary(.vec_map, map_out, map_meta_idx, src_vec_chan));

            // 10. 生成 vec_fold（init OP t_vec → result）
            // vec_fold 的 init 来自循环前的 acc 值，需要读取当前 acc 通道值
            const init_chan = try self.allocChannel(acc_type);
            try self.emit(Node.makeUnary(.load, init_chan, 0, acc_chan));

            const fold_result = try self.compileFold(fold_op, init_chan, map_out);

            // 11. 更新 acc 通道为 fold 结果（语义保持：循环后 acc = 最终累加值）
            try self.emit(Node.makeUnary(.store, acc_chan, 0, fold_result));

            // 12. 循环后更新 var 通道值（语义保持：while i < N 结束后 i == N）
            try self.emit(Node.makeUnary(.store, var_chan, 0, end_chan));

            // 13. while 表达式的值 = acc 最终值
            const result_chan = try self.allocChannel(acc_type);
            try self.emit(Node.makeUnary(.load, result_chan, 0, acc_chan));
            return result_chan;
        }

        // 5. 编译 end 表达式
        const end_chan = try self.compileExpr(end_expr);

        // 6. 获取元素类型，检查是整数
        const elem_type = self.channels.get(start_chan).chan_type;
        if (!elem_type.isInt()) return null;

        // 7. 生成 vec_source(range, start, end)
        var length: ?u32 = null;
        if (self.findConstVal(start_chan)) |sv| {
            if (self.findConstVal(end_chan)) |ev| {
                const s_val: i64 = @intCast(sv);
                const e_val: i64 = @intCast(ev);
                const len: i64 = e_val - s_val;
                if (len >= 0) length = @intCast(len);
            }
        }

        const source_meta_idx = try self.addVectorMeta(.{
            .vec_op = .range_source,
            .length = length,
            .elem_type = elem_type,
        });
        const src_vec_chan = try self.allocChannel(elem_type);
        try self.emit(Node.makeBinary(.vec_source, src_vec_chan, source_meta_idx, start_chan, end_chan));

        // 8. 在新作用域中将 var 绑定到 src_vec_chan
        try self.pushScope();
        defer self.popScope();
        try self.defineVar(var_name, src_vec_chan, false);

        // 9. 编译 body（不含最后的递增语句）
        const body_start: u32 = @intCast(self.nodes.items.len);
        for (body_stmts) |stmt| {
            _ = try self.compileStmt(stmt);
        }
        if (block.trailing_expr) |te| {
            _ = try self.compileExpr(te);
        }
        const body_len: u32 = @intCast(self.nodes.items.len - body_start);

        // 10. 生成 vec_map
        const map_meta_idx = try self.addVectorMeta(.{
            .inner_op = .const_i, // 占位
            .body_start = body_start,
            .body_len = body_len,
            .elem_type = elem_type,
        });
        const map_out = try self.allocChannel(elem_type);
        try self.emit(Node.makeUnary(.vec_map, map_out, map_meta_idx, src_vec_chan));

        // 11. 生成 vec_sink（取最后一个元素作为 while 表达式的值）
        const sink_meta_idx = try self.addVectorMeta(.{
            .vec_op = .sink_last,
            .elem_type = elem_type,
        });
        const sink_out = try self.allocChannel(elem_type);
        try self.emit(Node.makeUnary(.vec_sink, sink_out, sink_meta_idx, map_out));

        // 12. 循环后更新 var 通道值（语义保持：while i < N 结束后 i == N）
        try self.emit(Node.makeUnary(.store, var_chan, 0, end_chan));

        return sink_out;
    }

    /// 编译 loop { body } 无限循环（含 break 退出）
    pub fn compileLoop(self: *IRBuilder, ls: anytype) BuildError!u16 {
        const body_start: u32 = @intCast(self.nodes.items.len);

        try self.pushScope();
        defer self.popScope();
        _ = try self.compileExpr(ls.body);
        const body_len: u32 = @intCast(self.nodes.items.len - body_start);

        const out = try self.allocChannel(.i64_chan);
        const meta_idx = try self.addLoopMeta(.{
            .body_start = body_start,
            .body_len = body_len,
            .loop_kind = .loop,
        });
        try self.emit(Node.makeSink(.scalar_loop, out, meta_idx));
        return out;
    }

    /// 标量 for 循环（含 break/continue）
    pub fn compileForScalar(self: *IRBuilder, fs: anytype) BuildError!u16 {
        // 编译 iterable → 向量通道
        const src_vec_chan = try self.compileVecSource(fs.iterable);
        const elem_type = self.channels.get(src_vec_chan).chan_type;

        const body_start: u32 = @intCast(self.nodes.items.len);

        try self.pushScope();
        defer self.popScope();
        // 循环变量绑定到向量元素通道（engine 执行时 pin 到当前元素）
        const iter_chan = try self.allocChannel(elem_type);
        // 推断元素类型名（与 compileFor 一致，使循环体内字段访问可解析 field_id）
        var elem_type_node: ?*ast.TypeNode = null;
        if (self.inferTypeNameFromExpr(fs.iterable)) |iter_ty| {
            if (IRBuilder.arrayElemTypeName(iter_ty)) |elem_ty| {
                elem_type_node = self.makeNamedTypeNode(elem_ty) catch null;
            }
        }
        try self.scopeVarTyped(fs.name, iter_chan, false, null, elem_type_node);
        _ = try self.compileExpr(fs.body);
        const body_len: u32 = @intCast(self.nodes.items.len - body_start);

        const out = try self.allocChannel(.i64_chan);
        const meta_idx = try self.addLoopMeta(.{
            .body_start = body_start,
            .body_len = body_len,
            .loop_kind = .for_loop,
            .cond_chan = src_vec_chan,
            .iter_chan = iter_chan,
            .elem_type = elem_type,
        });
        try self.emit(Node.makeSink(.scalar_loop, out, meta_idx));
        return out;
    }

    /// 标量 while 循环（含 break/continue）
    pub fn compileWhileScalar(self: *IRBuilder, ws: anytype) BuildError!u16 {
        const body_start: u32 = @intCast(self.nodes.items.len);

        try self.pushScope();
        defer self.popScope();
        const cond_chan = try self.compileExpr(ws.condition);
        const cond_len: u32 = @intCast(self.nodes.items.len - body_start);
        _ = try self.compileExpr(ws.body);
        const body_len: u32 = @intCast(self.nodes.items.len - body_start);

        const out = try self.allocChannel(.i64_chan);
        const meta_idx = try self.addLoopMeta(.{
            .body_start = body_start,
            .body_len = body_len,
            .loop_kind = .while_loop,
            .cond_len = cond_len,
            .cond_chan = cond_chan,
        });
        try self.emit(Node.makeSink(.scalar_loop, out, meta_idx));
        return out;
    }

    pub fn compileDefer(self: *IRBuilder, ds: anytype) BuildError!void {
        const body_start: u32 = @intCast(self.nodes.items.len);

        // 编译 defer 体（表达式语句）
        _ = try self.compileExpr(ds.expr);

        const body_len: u32 = @intCast(self.nodes.items.len - body_start);

        // 发射 cleanup_register 节点
        const cleanup_meta_idx = try self.addCleanupMeta(.{
            .trigger = .any_halt,
            .body_start = body_start,
            .body_len = body_len,
            .order = @intCast(self.cleanup_metas.items.len),
        });

        // cleanup_register 不产生值，输出到 unit 通道
        const unit_chan = try self.allocChannel(.unit_chan);
        try self.emit(Node.makeSink(.cleanup_register, unit_chan, cleanup_meta_idx));
    }

    /// 编译 throw 语句
    ///
    /// 当函数返回 Throw<T, E> 时，throw expr 产生 ThrowValue(err) 并正常返回（halt_return），
    /// 调用者可通过 match 捕获。否则编译为 halt_throw，运行时返回 error.Thrown。
    pub fn compileThrow(self: *IRBuilder, ts: anytype) BuildError!?u16 {
        const err_chan = try self.compileExpr(ts.expr);

        if (self.current_returns_throw) {
            // Throw 返回函数：构造 ThrowValue 并正常返回
            const ret_chan = self.current_return_chan orelse {
                const out = try self.allocChannel(.ref_chan);
                const gate_meta_idx = try self.addGateMeta(.{ .gate_kind = .make_err });
                try self.emit(Node.makeUnary(.halt_throw, out, gate_meta_idx, err_chan));
                return out;
            };
            const value_chan = if (self.exprIsThrowValue(ts.expr)) err_chan else blk: {
                // 非 ThrowValue 输入：用 gate_make_err 构造 ThrowValue(err)
                const wrap_out = try self.allocChannel(.ref_chan);
                const meta_idx = try self.addGateMeta(.{ .gate_kind = .make_err });
                try self.emit(Node.makeUnary(.gate_make_err, wrap_out, meta_idx, err_chan));
                break :blk wrap_out;
            };
            try self.emit(Node.makeUnary(.halt_return, ret_chan, 0, value_chan));
            return ret_chan;
        } else {
            // 非 Throw 返回函数：halt_throw 运行时返回 error.Thrown
            const out = try self.allocChannel(.ref_chan);
            const gate_meta_idx = try self.addGateMeta(.{ .gate_kind = .make_err });
            try self.emit(Node.makeUnary(.halt_throw, out, gate_meta_idx, err_chan));
            return out;
        }
    }

    /// 编译 select 多路复用
    ///
    /// select { ch1.recv() => v => body1; ch2.recv() => v => body2 }
    /// 编译为竞争图：
    ///   N0: race_select(ch1, ch2) → winner  // 阻塞直到任一通道就绪
    ///   N1: route_dispatch(winner)          // 按 winner 索引执行对应 body 子图
    ///   body1 子图节点...（被 body_skip 跳过，由 route_dispatch 按需执行）
    ///   body2 子图节点...（同上）
    /// timeout 分支：时长通道追加为 race_select 的最后一个输入，
    /// 到期后 race_select 输出 timeout 分支的 arm 索引。
    pub fn compileSelect(self: *IRBuilder, arms: []const ast.SelectArm) BuildError!u16 {
        if (arms.len == 0) return error.UnsupportedExpr;

        const arena_alloc = self.arena.allocator();
        const arm_count = arms.len;

        // 1. 提取每个 receive 分支的通道（从 cha.recv() 中提取 cha），
        //    timeout 分支编译时长表达式（毫秒）
        var arm_chans = try arena_alloc.alloc(u16, arm_count);
        var timeout_arm: ?u8 = null;
        var receive_count: u8 = 0;
        for (arms, 0..) |arm, i| {
            const chan_expr = switch (arm) {
                .receive => |r| blk: {
                    // channel_expr 可能是 cha.recv() 调用，需要提取通道对象
                    switch (r.channel_expr.*) {
                        .method_call => |mc| {
                            if (std.mem.eql(u8, mc.method, "recv") or std.mem.eql(u8, mc.method, "tryRecv")) {
                                break :blk mc.object;
                            }
                            break :blk r.channel_expr;
                        },
                        .safe_method_call => |mc| {
                            if (std.mem.eql(u8, mc.method, "recv") or std.mem.eql(u8, mc.method, "tryRecv")) {
                                break :blk mc.object;
                            }
                            break :blk r.channel_expr;
                        },
                        else => break :blk r.channel_expr,
                    }
                },
                .timeout => |t| blk: {
                    if (timeout_arm != null) return error.UnsupportedExpr; // 至多一个 timeout 分支
                    timeout_arm = @intCast(i);
                    break :blk t.duration;
                },
            };
            const src_chan = try self.compileExpr(chan_expr);
            arm_chans[i] = src_chan;
            if (arm == .receive) receive_count += 1;
        }

        // race_select 输入上限 4：receive 通道 + 可选的 timeout 时长通道
        if (@as(usize, receive_count) + @intFromBool(timeout_arm != null) > 4)
            return error.UnsupportedExpr;

        // 2. 发射 race_select 节点（阻塞多路复用）
        //    inputs[0..receive_count) = receive 通道（按 arm 顺序）
        //    inputs[receive_count]    = timeout 时长通道（若有 timeout 分支）
        const select_meta_idx = try self.addRaceMeta(.{
            .source_count = receive_count,
            .timeout_ms = null,
            .timeout_arm = timeout_arm,
            .timeout_input = receive_count,
        });

        const winner_chan = try self.allocChannel(.i64_chan);
        var inputs: [4]u16 = .{ 0, 0, 0, 0 };
        {
            var slot: u8 = 0;
            for (arms, 0..) |arm, i| {
                if (arm == .receive) {
                    inputs[slot] = arm_chans[i];
                    slot += 1;
                }
            }
            if (timeout_arm) |ta| {
                inputs[slot] = arm_chans[ta];
                slot += 1;
            }
            try self.emit(Node{
                .op = .race_select,
                .input_count = slot,
                .output = winner_chan,
                .meta_index = select_meta_idx,
                .inputs = inputs,
            });
        }

        // 3. 编译每个 arm 的 body 为子图，记录起始位置和长度
        var body_starts = try arena_alloc.alloc(u32, arm_count);
        var body_lens = try arena_alloc.alloc(u32, arm_count);
        for (arms, 0..) |arm, i| {
            body_starts[i] = @intCast(self.nodes.items.len);
            if (arm == .receive) {
                // 判断 channel_expr 是否为真正的 recv()/tryRecv() 调用
                const is_chan_recv = switch (arm.receive.channel_expr.*) {
                    .method_call => |mc| std.mem.eql(u8, mc.method, "recv") or std.mem.eql(u8, mc.method, "tryRecv"),
                    .safe_method_call => |mc| std.mem.eql(u8, mc.method, "recv") or std.mem.eql(u8, mc.method, "tryRecv"),
                    else => false,
                };

                if (is_chan_recv) {
                    // 真正的通道接收：发射 orbit_chan_recv 消费值
                    const recv_out = try self.allocChannel(.i64_chan);
                    try self.emit(Node.makeUnary(.orbit_chan_recv, recv_out, 0, arm_chans[i]));

                    if (arm.receive.binding != null) {
                        try self.pushScope();
                        try self.defineVar(arm.receive.binding.?, recv_out, false);
                    }
                } else if (arm.receive.binding != null) {
                    // 非通道源（标量等）：直接绑定源值
                    try self.pushScope();
                    try self.defineVar(arm.receive.binding.?, arm_chans[i], false);
                }
            }
            const body_out = try self.compileExpr(switch (arm) {
                .receive => |r| r.body,
                .timeout => |t| t.body,
            });
            if (arm == .receive and arm.receive.binding != null) {
                self.popScope();
            }
            body_lens[i] = @intCast(self.nodes.items.len - body_starts[i]);
            _ = body_out;
        }

        // 4. 发射 route_dispatch 节点（按 winner 索引执行对应 body 子图）
        const route_meta_idx = try self.addRouteMeta(.{
            .trait_id = 0,
            .method_id = 0,
            .target_count = @intCast(arm_count),
            .body_starts = body_starts,
            .body_lens = body_lens,
        });

        const result_chan = try self.allocChannel(.ref_chan);
        try self.emit(Node.makeUnary(.route_dispatch, result_chan, route_meta_idx, winner_chan));

        return result_chan;
    }
};
