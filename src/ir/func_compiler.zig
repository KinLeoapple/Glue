//! Function 编译器（v3 阶段 4：从 builder.zig 物理拆分）
//!
//! 包含函数体编译、参数通道分配、type 方法编译、线性递归识别与编译等方法。
//! 通过 pub const 别名注入 IRBuilder（Zig 0.16 已移除 usingnamespace）。

const std = @import("std");
const ast = @import("ast");
const node_mod = @import("node.zig");
const channel_mod = @import("channel.zig");
const type_descriptor_mod = @import("type_descriptor.zig");
const builder_mod = @import("builder.zig");

const IRBuilder = builder_mod.IRBuilder;
const BuildError = builder_mod.BuildError;
const Node = node_mod.Node;
const NodeOp = builder_mod.NodeOp;
const LinearRecurrenceInfo = builder_mod.LinearRecurrenceInfo;

pub const Methods = struct {
    // ════════════════════════════════════════════
    // 函数编译
    // ════════════════════════════════════════════

    /// 编译 type_decl 的方法体（第二遍）
    pub fn compileTypeMethods(self: *IRBuilder, td: anytype) BuildError!void {
        const arena_alloc = self.arena.allocator();
        const prev_type_ctx = self.current_type_context;
        self.current_type_context = td.name;
        defer self.current_type_context = prev_type_ctx;

        for (td.methods) |method| {
            if (method.body == null) continue;
            const mangled = try std.fmt.allocPrint(arena_alloc, "{s}.{s}", .{ td.name, method.name });
            const func_idx = self.func_table.get(mangled) orelse continue;

            // 构造等价的 fun_decl 结构来复用 compileFunction（compileFunction 用 anytype）
            const fd = .{
                .params = method.params,
                .body = method.body.?,
            };
            _ = try self.compileFunction(fd, func_idx);
        }

        // 编译继承的 trait 默认方法体
        // 注意：trait default 方法体可能引用 typeof(Self)，需设置 current_self_type_name
        // 使 builder 在解析 typeof(Self) 时能查到 type_id
        const prev_self_type = self.current_self_type_name;
        self.current_self_type_name = td.name;
        defer self.current_self_type_name = prev_self_type;

        for (td.implemented_traits) |tb| {
            const trait_def = self.sema_result.getTraitDef(tb.trait_name);
            if (trait_def == null) continue;
            const trait_methods = self.findTraitMethodsAst(tb.trait_name) orelse {
                continue;
            };
            for (trait_methods) |tm| {
                if (tm.body == null) continue;
                const mangled = try std.fmt.allocPrint(arena_alloc, "{s}.{s}", .{ td.name, tm.name });
                // 仅编译未被 type 覆盖的默认方法（覆盖的已在上面编译）
                if (self.isMethodOverridden(td, tm.name)) continue;
                const func_idx = self.func_table.get(mangled) orelse {
                    continue;
                };
                const fd = .{
                    .params = tm.params,
                    .body = tm.body.?,
                };
                _ = try self.compileFunction(fd, func_idx);
            }
        }
    }

    /// 检查类型是否自己覆盖了某方法
    pub fn isMethodOverridden(self: *IRBuilder, td: anytype, method_name: []const u8) bool {
        for (td.methods) |method| {
            if (std.mem.eql(u8, method.name, method_name) and method.body != null) return true;
        }
        _ = self;
        return false;
    }

    /// 从 AST 参数列表预分配参数通道。
    /// 通道类型从参数类型注解推导，不依赖函数编译上下文。
    /// 第一遍注册时调用：为前向引用提供占位通道（compileCall 的 forceLazyArgIfNeeded
    /// 仅需通道类型判定，不需最终通道索引）。
    /// compileFunction 中再次调用：在局部通道范围内分配最终通道，
    /// 使 saveRecursiveChannels/restoreRecursiveChannels 能覆盖参数通道。
    pub fn allocParamChannels(self: *IRBuilder, params: anytype, arena_alloc: std.mem.Allocator) ![]u16 {
        var param_channels = try arena_alloc.alloc(u16, params.len);
        for (params, 0..) |param, i| {
            const chan = if (param.type_annotation) |tn| switch (tn.*) {
                .nullable => |nb| try self.channels.allocNullable(self.chanTypeFromTypeNodeBound(nb.inner) orelse unreachable),
                .ref_type, .raw_ptr => try self.channels.allocRef(type_descriptor_mod.ref_descriptor),
                else => try self.allocChannel(self.chanTypeFromTypeNodeBound(tn) orelse unreachable),
            } else try self.allocChannel(type_descriptor_mod.i64_descriptor);
            param_channels[i] = chan;
        }
        return param_channels;
    }

    pub fn compileFunction(self: *IRBuilder, fd: anytype, func_idx: u16) BuildError!u16 {
        const node_start: u32 = @intCast(self.nodes.items.len);
        const chan_start: u16 = self.channels.count();

        try self.pushScope();
        defer self.popScope();

        // 设置当前函数上下文（用于 GADT 类型推断 + typeof(T) 哨兵发射）
        // 注意：所有 current_* 字段都必须 save/restore，因为单态化可能触发
        // 嵌套 compileFunction 调用（instantiateFunction → compileFunction），
        // 若不恢复外层状态，内层清空会导致外层 return_stmt 编译失败。
        const prev_func_name = self.current_func_name;
        const prev_param_types = self.current_func_param_types;
        const prev_type_params = self.current_func_type_params;
        const prev_type_ctx = self.current_type_context;
        const prev_return_chan = self.current_return_chan;
        const prev_returns_throw = self.current_returns_throw;
        const prev_throw_ok_chan_type = self.current_throw_ok_type_desc;
        if (@hasField(@TypeOf(fd), "name")) {
            self.current_func_name = fd.name;
            self.debug_error_func_name = fd.name;
            // stdlib 方法（如 "std.time.DateTime.add_duration"）：从函数名推断类型上下文
            // 使 self 参数的方法调用（如 self.to_components()）能解析到正确的类型
            // 提取倒数第二段作为类型名：std.time.DateTime.add_duration → DateTime
            if (std.mem.lastIndexOfScalar(u8, fd.name, '.')) |last_dot| {
                if (last_dot > 0) {
                    const prefix = fd.name[0..last_dot];
                    if (std.mem.lastIndexOfScalar(u8, prefix, '.')) |prev_dot| {
                        const type_candidate = prefix[prev_dot + 1 ..];
                        if (self.sema_result.getTypeDef(type_candidate) != null) {
                            self.current_type_context = type_candidate;
                        }
                    } else {
                        // 只有一个点：TypeName.method
                        const type_candidate = prefix;
                        if (self.sema_result.getTypeDef(type_candidate) != null) {
                            self.current_type_context = type_candidate;
                        }
                    }
                }
            }
        }
        if (@hasField(@TypeOf(fd), "params")) {
            self.current_func_param_types = fd.params;
        }
        if (@hasField(@TypeOf(fd), "type_params")) {
            self.current_func_type_params = fd.type_params;
        }
        defer {
            self.current_func_name = prev_func_name;
            self.current_func_param_types = prev_param_types;
            self.current_func_type_params = prev_type_params;
            self.current_type_context = prev_type_ctx;
            self.current_return_chan = prev_return_chan;
            self.current_returns_throw = prev_returns_throw;
            self.current_throw_ok_type_desc = prev_throw_ok_chan_type;
        }

        // 在局部通道范围内重新分配参数通道（确保 recursion save/restore 覆盖参数通道）
        // 第一遍预分配的占位通道仅用于编译期前向引用（forceLazyArgIfNeeded 的类型判定），
        // 运行时使用此处分配的通道——它们位于 [local_chan_start, local_chan_start+local_chan_count)
        // 范围内，使 saveRecursiveChannels/restoreRecursiveChannels 能正确保存和恢复参数通道。
        const param_channels = try self.allocParamChannels(fd.params, self.arena.allocator());
        for (fd.params, 0..) |param, i| {
            try self.scopeVarTyped(param.name, param_channels[i], false, null, param.type_annotation);
            // Atomic<T> 参数标记为原子绑定（chan 存储的是 AtomicValue 指针）
            if (builder_mod.IRBuilder.isAtomicType(param.type_annotation)) self.markLastBindingAtomic();
        }

        // 使用第一遍预分配的返回通道（保证 compileCall 引用的是最终通道）
        const return_chan = self.functions.items[func_idx].return_channel;
        self.current_return_chan = return_chan;
        // async 函数返回 Async<T>，但函数体实际产出 T：throw/Ok 语义按 T 处理。
        // 同步函数直接用 return_type。
        const effective_return_type = if (@hasField(@TypeOf(fd), "return_type"))
            builder_mod.unwrapAsyncType(fd.return_type)
        else
            null;
        self.current_returns_throw = if (@hasField(@TypeOf(fd), "return_type")) builder_mod.isThrowType(effective_return_type) else false;
        // 提取 Throw<T, E> 的 Ok 值通道类型，供 ? 传播使用
        if (self.current_returns_throw and @hasField(@TypeOf(fd), "return_type")) {
            self.current_throw_ok_type_desc = builder_mod.throwOkChanType(effective_return_type, self.sema_result) orelse unreachable;
        }

        // 编译函数体（函数体在尾位置）
        self.in_tail_position = true;
        const body_chan = try self.compileExpr(fd.body);
        self.in_tail_position = false;

        // 若函数返回 Throw<T, E> 且函数体不是直接产生 ThrowValue 的表达式（如 Ok(...)），
        // 则包装结果为 ThrowValue(ok)
        const throw_wrapped = if (self.current_returns_throw and !self.exprIsThrowValue(fd.body)) blk: {
            const wrap_out = try self.allocChannel(type_descriptor_mod.ref_descriptor);
            const meta_idx = try self.addGateMeta(.{ .gate_kind = .make_ok });
            try self.emit(Node.makeUnary(.gate_make_ok, wrap_out, meta_idx, body_chan));
            break :blk wrap_out;
        } else body_chan;

        // 若函数返回 nullable 类型且函数体未产生 nullable_chan，则包装为 nullable
        const return_meta = self.channels.get(return_chan);
        const final_chan = if (return_meta.type_desc.isNullable()) blk: {
            const body_meta = self.channels.get(throw_wrapped);
            if (body_meta.type_desc.isNullable()) {
                break :blk throw_wrapped; // 已是 nullable
            }
            // 需要包装（null_chan 或其他类型 → nullable_make）
            const nc = try self.channels.allocNullable(return_meta.inner_type_desc orelse type_descriptor_mod.i64_descriptor);
            try self.emit(Node.makeUnary(.nullable_make, nc, 0, throw_wrapped));
            break :blk nc;
        } else throw_wrapped;

        // 发射 halt_return
        try self.emit(Node.makeUnary(.halt_return, return_chan, 0, final_chan));

        // node_count：延迟实例化确保被实例化函数的体节点不会交错到当前函数范围内，
        // 因此直接用 raw node count 即可
        const node_count: u32 = @as(u32, @intCast(self.nodes.items.len - node_start));
        const chan_end: u16 = self.channels.count();
        // 更新占位条目（保留第一遍设置的 return_channel/is_entry/is_async）
        self.functions.items[func_idx].node_start = node_start;
        self.functions.items[func_idx].node_count = node_count;
        self.functions.items[func_idx].param_channels = param_channels;
        self.functions.items[func_idx].local_chan_start = chan_start;
        self.functions.items[func_idx].local_chan_count = chan_end - chan_start;
        // 查询逃逸分析表，设置 no_escape 标记
        if (self.escape_table) |et| {
            if (@hasField(@TypeOf(fd), "name")) {
                self.functions.items[func_idx].no_escape = et.isNoEscape(fd.name);
            }
        }

        // 阶段 1：async 函数状态机变换，产出 CoroutineMeta 写入 IR
        if (self.functions.items[func_idx].is_async) {
            const func_nodes = self.nodes.items[node_start .. node_start + node_count];
            const smt = @import("state_machine_transform.zig");
            const arena_alloc = self.arena.allocator();

            // IR-1: cleanup_metas/loop_metas/route_metas store GLOBAL body_start values
            // (set during compileDefer/compileLoop/compileRoute as @intCast(self.nodes.items.len)),
            // but transformToStateMachine operates on the LOCAL func_nodes sub-slice.
            // Subtract node_start to convert global indices to local for correct segment
            // matching (buildLoopTable/buildCatchTable) and captured_locals scanning
            // (collectCapturedLocals). Without this, non-first functions never match
            // because global body_start is outside the local sub-slice range.
            const local_cleanup_metas = blk: {
                if (node_start == 0) break :blk self.cleanup_metas.items;
                const copies = try arena_alloc.alloc(builder_mod.CleanupMeta, self.cleanup_metas.items.len);
                for (self.cleanup_metas.items, 0..) |cm, i| {
                    copies[i] = cm;
                    copies[i].body_start = if (cm.body_start >= node_start) cm.body_start - node_start else 0;
                }
                break :blk copies;
            };
            const local_loop_metas = blk: {
                if (node_start == 0) break :blk self.loop_metas.items;
                const copies = try arena_alloc.alloc(builder_mod.LoopMeta, self.loop_metas.items.len);
                for (self.loop_metas.items, 0..) |lm, i| {
                    copies[i] = lm;
                    copies[i].body_start = if (lm.body_start >= node_start) lm.body_start - node_start else 0;
                }
                break :blk copies;
            };
            const local_route_metas = blk: {
                if (node_start == 0) break :blk self.route_metas.items;
                const copies = try arena_alloc.alloc(builder_mod.RouteMeta, self.route_metas.items.len);
                for (self.route_metas.items, 0..) |rm, i| {
                    copies[i] = rm;
                    if (rm.body_starts.len > 0) {
                        const new_starts = try arena_alloc.alloc(u32, rm.body_starts.len);
                        for (rm.body_starts, 0..) |bs, j| {
                            new_starts[j] = if (bs >= node_start) bs - node_start else 0;
                        }
                        copies[i].body_starts = new_starts;
                    }
                }
                break :blk copies;
            };

            var cm = smt.transformToStateMachine(
                arena_alloc,
                func_idx,
                func_nodes,
                &self.functions.items[func_idx],
                &self.channels,
                local_cleanup_metas,
                local_loop_metas,
                local_route_metas,
            ) catch return BuildError.TransformFailed;
            // 修正段的全局节点偏移：transformToStateMachine 用 func_nodes 子切片的
            // 0-based 索引生成 seg.start_node/end_node，但 runSegment 用全局 nodes 数组
            // 索引。必须加上 node_start 转换为全局偏移，否则段会引用错误函数的节点。
            for (cm.segments) |*seg| {
                seg.start_node += node_start;
                seg.end_node += node_start;
            }
            // IR-1: block_body_start/handler_body_start were computed from local-adjusted
            // metas; convert back to global for materializeCoroutineSyncFunctions (which
            // uses them as global node_start values for independent sync functions).
            for (cm.defer_table.entries) |*entry| {
                entry.block_body_start += node_start;
            }
            for (cm.catch_table.entries) |*entry| {
                entry.handler_body_start += node_start;
            }
            // 阶段 1b 完善：defer/catch 块体独立函数化，回填 func_idx
            self.materializeCoroutineSyncFunctions(&cm) catch return BuildError.TransformFailed;
            _ = self.addCoroutineMeta(cm) catch return BuildError.TransformFailed;
        }

        // current_return_chan/current_returns_throw/current_throw_ok_type_desc
        // 由函数开头的 defer 块统一恢复（支持单态化嵌套 compileFunction 调用）
        return func_idx;
    }

    // ════════════════════════════════════════════
    // 线性递归识别与编译
    // ════════════════════════════════════════════

    /// 检测线性递归模式：fun f(n: T): T { if n < 2 { n } else { f(n-1) op f(n-2) } }
    /// 支持 op ∈ {add, mul, bit_and, bit_or, bit_xor}（结合律保证 vec_scan 正确）
    /// 返回 LinearRecurrenceInfo（init_a=0, init_b=1 对应 base case f(0)=0, f(1)=1）
    pub fn tryDetectLinearRecurrence(self: *IRBuilder, func_name: []const u8, fd: anytype) !?LinearRecurrenceInfo {
        // 必须恰好 1 个参数
        if (fd.params.len != 1) return null;
        const param = fd.params[0];
        const param_name = param.name;
        // 参数必须是整数类型
        const chan_type = if (param.type_annotation) |tn|
            self.chanTypeFromTypeNodeBound(tn) orelse unreachable
        else
            type_descriptor_mod.i64_descriptor;
        if (!chan_type.isInt()) return null;

        // 函数体必须是 if_expr（允许包裹在无语句的 block 中）
        const body_expr = builder_mod.unwrapBlockExpr(fd.body);
        if (body_expr.* != .if_expr) return null;
        const ie = body_expr.if_expr;

        // 条件必须是 param < 2 或 param <= 1
        if (ie.condition.* != .binary) return null;
        const cond_bin = ie.condition.binary;
        var digit_buf: [64]u8 = undefined;
        const threshold: i64 = blk: {
            if (cond_bin.op == .lt) {
                if (cond_bin.left.* == .identifier and
                    std.mem.eql(u8, cond_bin.left.identifier.name, param_name) and
                    cond_bin.right.* == .int_literal)
                {
                    break :blk std.fmt.parseInt(i64, builder_mod.filterDigits(cond_bin.right.int_literal.raw, &digit_buf), 10) catch return null;
                }
            } else if (cond_bin.op == .lt_eq) {
                if (cond_bin.left.* == .identifier and
                    std.mem.eql(u8, cond_bin.left.identifier.name, param_name) and
                    cond_bin.right.* == .int_literal)
                {
                    const v = std.fmt.parseInt(i64, builder_mod.filterDigits(cond_bin.right.int_literal.raw, &digit_buf), 10) catch return null;
                    break :blk v + 1; // n <= 1 等价于 n < 2
                }
            }
            return null;
        };
        if (threshold != 2) return null; // 仅支持 K=2

        // then 分支必须是 identifier(param_name)（允许包裹在无语句 block 中）
        const then_expr = builder_mod.unwrapBlockExpr(ie.then_branch);
        if (then_expr.* != .identifier) return null;
        if (!std.mem.eql(u8, then_expr.identifier.name, param_name)) return null;

        // else 分支必须是 binary(op, call, call)（允许包裹在无语句 block 中）
        if (ie.else_branch == null) return null;
        const else_expr = builder_mod.unwrapBlockExpr(ie.else_branch.?);
        if (else_expr.* != .binary) return null;
        const rec_bin = else_expr.binary;

        // 映射运算符
        const node_op: NodeOp = switch (rec_bin.op) {
            .add => .int_add,
            .mul => .int_mul,
            .bit_and => .int_and,
            .bit_or => .int_or,
            .bit_xor => .int_xor,
            else => return null,
        };

        // 两个操作数必须是 f(n-1) 和 f(n-2)
        const left_is_rec = self.isSelfCallWithOffset(rec_bin.left, func_name, param_name, 1);
        const right_is_rec = self.isSelfCallWithOffset(rec_bin.right, func_name, param_name, 2);
        const left_is_rec2 = self.isSelfCallWithOffset(rec_bin.left, func_name, param_name, 2);
        const right_is_rec1 = self.isSelfCallWithOffset(rec_bin.right, func_name, param_name, 1);
        if (!((left_is_rec and right_is_rec) or (left_is_rec2 and right_is_rec1))) return null;

        return LinearRecurrenceInfo{
            .op = node_op,
            .init_a = 0, // f(0) = 0
            .init_b = 1, // f(1) = 1
            .elem_type = chan_type,
        };
    }

    /// 检查 expr 是否为 f(param - offset) 形式的自递归调用
    pub fn isSelfCallWithOffset(self: *IRBuilder, expr: *const ast.Expr, func_name: []const u8, param_name: []const u8, offset: i64) bool {
        _ = self;
        if (expr.* != .call) return false;
        const call = expr.call;
        if (call.callee.* != .identifier) return false;
        if (!std.mem.eql(u8, call.callee.identifier.name, func_name)) return false;
        if (call.arguments.len != 1) return false;
        const arg = call.arguments[0];
        if (arg.* != .binary) return false;
        const sub = arg.binary;
        if (sub.op != .sub) return false;
        // param - offset
        if (sub.left.* == .identifier and
            std.mem.eql(u8, sub.left.identifier.name, param_name) and
            sub.right.* == .int_literal)
        {
            var buf: [64]u8 = undefined;
            const v = std.fmt.parseInt(i64, builder_mod.filterDigits(sub.right.int_literal.raw, &buf), 10) catch return false;
            return v == offset;
        }
        return false;
    }

    /// 编译线性递归为迭代 scalar_loop：
    /// 状态 (a, b) 初始 (init_a, init_b)，每次 (a, b) → (b, a op b)，循环 n 次后返回 a
    pub fn compileLinearRecurrenceCall(self: *IRBuilder, info: LinearRecurrenceInfo, n_chan: u16) BuildError!u16 {
        const elem_type = info.elem_type;

        // 分配 cell 通道：a, b, i（可变状态）
        const a_chan = try self.allocCellChannel(elem_type);
        const b_chan = try self.allocCellChannel(elem_type);
        const i_chan = try self.allocCellChannel(elem_type);

        // 初始化：a = init_a, b = init_b, i = 0
        const init_a_chan = try self.emitConstInt(info.init_a, elem_type);
        try self.emit(Node.makeUnary(.store, a_chan, 0, init_a_chan));
        const init_b_chan = try self.emitConstInt(info.init_b, elem_type);
        try self.emit(Node.makeUnary(.store, b_chan, 0, init_b_chan));
        const init_i_chan = try self.emitConstInt(0, elem_type);
        try self.emit(Node.makeUnary(.store, i_chan, 0, init_i_chan));

        // 编译 1 常量（供 i += 1 使用）
        const one_chan = try self.emitConstInt(1, elem_type);

        // scalar_loop body:
        //   cond: i < n  → cond_chan (bool)
        //   body: temp = a op b; store a = b; store b = temp; i_new = i + 1; store i = i_new
        const body_start: u32 = @intCast(self.nodes.items.len);

        // 条件子图：cmp_lt(i_chan, n_chan)
        const cond_chan = try self.allocChannel(type_descriptor_mod.bool_descriptor);
        try self.emit(Node.makeBinary(.cmp_lt, cond_chan, 0, i_chan, n_chan));
        const cond_len: u32 = @intCast(self.nodes.items.len - body_start);

        // 循环体：temp = a op b
        const temp_chan = try self.allocChannel(elem_type);
        try self.emit(Node.makeBinary(info.op, temp_chan, 0, a_chan, b_chan));
        // store a = b
        try self.emit(Node.makeUnary(.store, a_chan, 0, b_chan));
        // store b = temp
        try self.emit(Node.makeUnary(.store, b_chan, 0, temp_chan));
        // i_new = i + 1
        const i_new_chan = try self.allocChannel(elem_type);
        try self.emit(Node.makeBinary(.int_add, i_new_chan, 0, i_chan, one_chan));
        // store i = i_new
        try self.emit(Node.makeUnary(.store, i_chan, 0, i_new_chan));

        const body_len: u32 = @intCast(self.nodes.items.len - body_start);

        // 发射 scalar_loop
        const loop_out = try self.allocChannel(type_descriptor_mod.i64_descriptor);
        const meta_idx = try self.addLoopMeta(.{
            .body_start = body_start,
            .body_len = body_len,
            .loop_kind = .while_loop,
            .cond_len = cond_len,
            .cond_chan = cond_chan,
        });
        try self.emit(Node.makeSink(.scalar_loop, loop_out, meta_idx));

        // 结果 = a_chan（load 到新通道）
        const result_chan = try self.allocChannel(elem_type);
        try self.emit(Node.makeUnary(.load, result_chan, 0, a_chan));

        return result_chan;
    }

    /// 单态化核心：实例化泛型函数，返回特化函数索引
    ///
    /// sema 已预先收集所有泛型调用点（collectMonomorphInstances）并产出
    /// instance_id，IR 直接消费 instance_id，不再重复哈希或反查 monomorph_index。
    ///
    /// 流程：
    /// 1. 从 sema monomorph_instances[instance_id] 取实例（func_name + type_args）
    /// 2. 查 instance_func_map：已编译则返回
    /// 3. 查 instances_in_progress：递归中则返回预占索引
    /// 4. 查找函数 AST，预占 Function 索引
    /// 5. push type binding，编译函数体，建立映射
    ///
    /// 调用方负责保证 instance_id 来自 sema call_instantiations（即泛型调用点）。
    /// 非泛型调用（instance_id 为 null）不应进入此函数。
    pub fn instantiateFunction(
        self: *IRBuilder,
        instance_id: u32,
    ) !u16 {
        // 1. 从 sema 实例表取 func_name 与 type_args（单一权威来源）
        //    instance_id 越界是 sema/IR 契约违反（不应发生），退化为 UndefinedFunction
        if (instance_id >= self.sema_result.monomorph_instances.items.len) {
            return error.UndefinedFunction;
        }
        const instance = self.sema_result.monomorph_instances.items[instance_id];
        const func_name = instance.func_name;

        // 2. 查 instance_func_map：已编译则返回
        if (self.instance_func_map.get(instance_id)) |func_idx| {
            return func_idx;
        }

        // 3. 查进行中（递归占位）
        if (self.instances_in_progress.get(instance_id)) |func_idx| {
            return func_idx;
        }

        // 4. 查找函数 AST
        const fd = self.findFunDeclAst(func_name) orelse {
            // AST 未找到（可能是类型方法或内建函数），退化为原索引
            return self.func_table.get(func_name) orelse return error.UndefinedFunction;
        };

        // 5. 预占新 Function 索引
        const new_func_idx: u16 = @intCast(self.functions.items.len);

        // 6. 写入 instances_in_progress（同时作为"已排队"标记，防止重复排队）
        //    不再用 defer remove：延迟编译完成后由 processDeferredInstantiations 移除
        try self.instances_in_progress.put(instance_id, new_func_idx);

        // 7. 预分配占位 Function（return channel 用 bound 版本解析）
        //    必须临时切换 current_type_args 到实例的 type_args，否则类型参数（如 A）
        //    会因 caller 的空 type_args 而回退到 ref_descriptor，
        //    导致 forceLazyArgIfNeeded 错误装箱标量实参。
        const instance_type_args = self.sema_result.monomorph_instances.items[instance_id].type_args;
        const saved_type_args = self.current_type_args;
        self.current_type_args = instance_type_args;
        defer self.current_type_args = saved_type_args;

        const return_chan_type = self.chanTypeFromTypeNodeBound(fd.return_type) orelse unreachable;
        // IR-3: Extract the correct inner type from the AST nullable type node instead of
        // using i64_descriptor. compileFunction reuses this placeholder return_channel
        // without re-allocating, so the inner type must be correct from the start.
        const placeholder_return_chan = if (return_chan_type.isNullable()) blk: {
            const inner_td = if (fd.return_type) |rt| switch (rt.*) {
                .nullable => |nb| self.chanTypeFromTypeNodeBound(nb.inner) orelse unreachable,
                else => type_descriptor_mod.i64_descriptor,
            } else type_descriptor_mod.i64_descriptor;
            break :blk try self.channels.allocNullable(inner_td);
        } else try self.allocChannel(return_chan_type);
        const arena_alloc = self.arena.allocator();
        const placeholder_param_channels = try self.allocParamChannels(fd.params, arena_alloc);
        try self.functions.append(arena_alloc, .{
            .name = func_name, // 特化版本用原名（不放入 func_table，仅通过 func_index 引用）
            .node_start = 0,
            .node_count = 0,
            .param_channels = placeholder_param_channels,
            .return_channel = placeholder_return_chan,
            .is_entry = false,
            .is_async = fd.is_async,
        });

        // 8. 延迟编译：将实例化请求排队，待所有顶层函数编译完成后统一处理。
        //    这避免了被实例化函数的体节点与调用者函数的体节点交错，
        //    导致调用者 node_range 错误包含被实例化函数的节点。
        try self.deferred_instantiations.append(self.allocator, .{
            .func_name = func_name,
            .instance_id = instance_id,
            .func_idx = new_func_idx,
        });

        return new_func_idx;
    }

    /// 处理延迟实例化队列：编译所有排队的泛型函数实例。
    /// 在所有顶层函数编译完成后调用，确保被实例化函数的体节点
    /// 不会与调用者函数的体节点交错。
    /// 处理过程中可能触发新的实例化请求（递归泛型），循环处理直到队列为空。
    pub fn processDeferredInstantiations(self: *IRBuilder) BuildError!void {
        while (self.deferred_instantiations.items.len > 0) {
            // 取出队首（FIFO 顺序保持实例化嵌套层次合理）
            const req = self.deferred_instantiations.orderedRemove(0);

            // 设置单态化上下文
            const instance_ptr = &self.sema_result.monomorph_instances.items[req.instance_id];
            const prev_instance_id = self.current_instance_id;
            const prev_type_args = self.current_type_args;
            self.current_instance_id = req.instance_id;
            self.current_type_args = instance_ptr.type_args;
            defer {
                self.current_instance_id = prev_instance_id;
                self.current_type_args = prev_type_args;
            }

            // 查找函数 AST
            const fd = self.findFunDeclAst(req.func_name) orelse {
                // AST 未找到，跳过（占位条目保持 node_count=0）
                _ = self.instances_in_progress.remove(req.instance_id);
                continue;
            };

            // 编译函数体（compileFunction 会更新占位条目的 node_start/node_count 等）
            _ = try self.compileFunction(fd.*, req.func_idx);

            // 标记为已编译：从 in_progress 移除，加入 instance_func_map
            _ = self.instances_in_progress.remove(req.instance_id);
            try self.instance_func_map.put(req.instance_id, req.func_idx);
        }
    }
};
