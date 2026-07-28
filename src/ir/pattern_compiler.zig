//! Pattern/match 编译器（v3 阶段 4：从 builder.zig 物理拆分）
//!
//! 包含 match 表达式和模式匹配相关的编译方法。
//! 通过 usingnamespace 混入 IRBuilder。

const std = @import("std");
const ast = @import("ast");
const node_mod = @import("node.zig");
const type_descriptor_mod = @import("type_descriptor.zig");
const builder_mod = @import("builder.zig");
const sema_inference = @import("sema").inference;

const IRBuilder = builder_mod.IRBuilder;
const BuildError = builder_mod.BuildError;
const Node = node_mod.Node;

pub const Methods = struct {
    // ════════════════════════════════════════════
    // match 表达式编译（P0-c）
    // ════════════════════════════════════════════

    /// 为 match arm 推送 GADT 类型绑定
    /// 已迁移至 sema.inference.pushGadtBindingsForArm（通过 GadtContext）
    pub fn pushGadtBindingsForArm(self: *IRBuilder, scrutinee: *ast.Expr, pattern: *const ast.Pattern) void {
        var ctx = self.gadtContext();
        sema_inference.pushGadtBindingsForArm(&ctx, scrutinee, pattern);
    }

    /// 弹出 GADT 类型绑定栈顶
    /// 已迁移至 sema.inference.popGadtBindings（通过 GadtContext）
    pub fn popGadtBindings(self: *IRBuilder) void {
        var ctx = self.gadtContext();
        sema_inference.popGadtBindings(&ctx);
    }

    /// 编译 match 表达式：match scrutinee { arm1 => body1, ... }
    /// 策略：转换为嵌套 if-else 链，每个 arm 用 route_dispatch 选择
    pub fn compileMatch(self: *IRBuilder, scrutinee: *ast.Expr, arms: []const ast.MatchArm) BuildError!u16 {
        const scrutinee_chan = try self.compileExpr(scrutinee);
        // 推断 scrutinee 的 Throw Ok 类型，用于 Ok(pattern) 中 ok_val_chan 的类型
        // 避免 ref 类型 Ok 值被硬编码为 i64_chan 导致指针丢失
        const saved_ok_type = self.current_throw_ok_type_desc;
        if (self.inferThrowOkChanType(scrutinee)) |ok_type| {
            self.current_throw_ok_type_desc = ok_type;
        }
        defer self.current_throw_ok_type_desc = saved_ok_type;
        return try self.compileMatchArms(scrutinee, scrutinee_chan, arms, 0);
    }

    /// 判断模式是否总是匹配（无需 route_dispatch 条件选择）
    /// wildcard/变量绑定/单构造器类型的构造器模式（含全变量子模式）总是匹配
    pub fn patternAlwaysMatches(self: *IRBuilder, pattern: *const ast.Pattern) bool {
        switch (pattern.*) {
            .wildcard => return true,
            .variable => |v| {
                const sr = self.sema_result;
                if (sr.getCtorDef(v.name)) |ctor| {
                    if (ctor.field_type_descs.len != 0) return false;
                    if (sr.getTypeDef(ctor.type_name)) |ti| {
                        return ti.constructors.len == 1;
                    }
                    return false;
                }
                return true;
            },
            .constructor => |c| {
                const sr = self.sema_result;
                const ctor = sr.getCtorDef(c.name) orelse return false;
                const ti = sr.getTypeDef(ctor.type_name) orelse return false;
                if (ti.constructors.len != 1) return false;
                for (c.patterns) |sub| {
                    if (!self.patternAlwaysMatches(sub)) return false;
                }
                return true;
            },
            else => return false,
        }
    }

    /// 跳表优化：所有 arms 都是同一 ADT 构造器模式时，用 __tag 直接索引替代线性比较
    /// 条件：arms >= 2，全部为构造器模式（或无参构造器变量），无 guard，子模式为变量/通配符
    /// 优化效果：O(N) 嵌套 route_dispatch 链 → O(1) tag 索引分派
    /// 适用场景：枚举分派（如 colorToValue、tokenWeight、exprDepth）
    pub fn tryCompileJumpTableMatch(self: *IRBuilder, scrutinee: *ast.Expr, scrutinee_chan: u16, arms: []const ast.MatchArm) BuildError!?u16 {
        // 条件 1: 至少 2 个 arms
        if (arms.len < 2) return null;

        const sr = self.sema_result;

        // 条件 2: 所有 arms 为构造器模式（或无参构造器变量），无 guard，子模式为变量/通配符
        var common_type_name: ?[]const u8 = null;
        for (arms) |arm| {
            if (arm.guard != null) return null;
            const ctor_name: ?[]const u8 = switch (arm.pattern.*) {
                .constructor => |c| blk: {
                    for (c.patterns) |sub| {
                        switch (sub.*) {
                            .wildcard, .variable => {},
                            else => break :blk null,
                        }
                    }
                    break :blk c.name;
                },
                .variable => |v| blk: {
                    if (sr.getCtorDef(v.name)) |ctor| {
                        if (ctor.field_type_descs.len == 0) break :blk v.name;
                    }
                    break :blk null;
                },
                else => null,
            };
            if (ctor_name == null) return null;

            const ctor = sr.getCtorDef(ctor_name.?) orelse return null;
            if (common_type_name) |ctn| {
                if (!std.mem.eql(u8, ctn, ctor.type_name)) return null;
            } else {
                common_type_name = ctor.type_name;
            }
        }

        const type_name = common_type_name orelse return null;
        const type_info = sr.getTypeDef(type_name) orelse return null;

        // 条件 3: ADT 有 > 1 个构造器（单构造器已有优化路径），且不超过 u8 容量
        if (type_info.constructors.len <= 1) return null;
        if (type_info.constructors.len > 255) return null;

        const arena_alloc = self.arena.allocator();
        const ctor_count = type_info.constructors.len;

        // 读取 __tag（field_id=0）一次，作为 route_dispatch 的 winner 索引
        const tag_field_meta = try self.addFieldIdMeta(0);
        const tag_chan = try self.allocChannel(type_descriptor_mod.i64_descriptor);
        try self.emit(Node.makeUnary(.record_get, tag_chan, tag_field_meta, scrutinee_chan));

        // 为每个构造器编译 body 子图（按 tag 索引）
        const body_starts = try arena_alloc.alloc(u32, ctor_count);
        const body_lens = try arena_alloc.alloc(u32, ctor_count);

        var result_type: ?*const type_descriptor_mod.TypeDescriptor = null;

        for (type_info.constructors, 0..) |ctor, tag_idx| {
            // 查找该构造器对应的 arm（线性搜索，arm 数量通常 < 10）
            var found_arm_idx: ?usize = null;
            for (arms, 0..) |arm, i| {
                const name_match = switch (arm.pattern.*) {
                    .constructor => |c| std.mem.eql(u8, c.name, ctor.name),
                    .variable => |v| std.mem.eql(u8, v.name, ctor.name),
                    else => false,
                };
                if (name_match) {
                    found_arm_idx = i;
                    break;
                }
            }

            const body_start: u32 = @intCast(self.nodes.items.len);

            if (found_arm_idx) |arm_idx| {
                const arm = arms[arm_idx];

                try self.pushScope();
                self.pushGadtBindingsForArm(scrutinee, arm.pattern);

                // 读取字段并绑定变量（子模式已确认为变量/通配符，总是匹配）
                const sub_patterns: []*ast.Pattern = switch (arm.pattern.*) {
                    .constructor => |c| c.patterns,
                    else => &.{}, // 无参构造器变量模式
                };
                const sub_count = @min(sub_patterns.len, ctor.field_type_descs.len);
                for (0..sub_count) |i| {
                    const field_meta = try self.addFieldIdMeta(@intCast(i + 1));
                    const field_type_node = self.getCtorAstFieldTypeNode(ctor.name, i);
                    const field_chan_type = self.resolveFieldTypeWithBindings(field_type_node);
                    const field_chan = try self.allocChannel(field_chan_type);
                    try self.emit(Node.makeUnary(.record_get, field_chan, field_meta, scrutinee_chan));
                    const prev_hint = self.pattern_type_hint;
                    self.pattern_type_hint = field_type_node;
                    _ = try self.compilePatternCheck(field_chan, sub_patterns[i]);
                    self.pattern_type_hint = prev_hint;
                }

                // 编译 body（追踪 body 表达式起始，若 body 无节点则补 load 确保最后节点是 body 输出）
                const body_expr_start: u32 = @intCast(self.nodes.items.len);
                const body_chan = try self.compileExpr(arm.body);
                if (self.nodes.items.len == body_expr_start) {
                    const load_chan = try self.allocChannel(self.channels.get(body_chan).type_desc);
                    try self.emit(Node.makeUnary(.load, load_chan, 0, body_chan));
                }

                self.popGadtBindings();
                self.popScope();

                // 记录结果类型（取第一个真实 arm 的 body 最后节点输出类型）
                if (result_type == null) {
                    const body_len_tmp: u32 = @intCast(self.nodes.items.len - body_start);
                    result_type = self.channels.get(self.nodes.items[body_start + body_len_tmp - 1].output).type_desc;
                }
            } else {
                // 该构造器无对应 arm — default body 返回 unit（仅非穷尽 match 触发，sema 应拒绝）
                const unit_chan = try self.allocChannel(type_descriptor_mod.unit_descriptor);
                try self.emit(Node.makeSink(.const_unit, unit_chan, 0));
            }

            const body_len: u32 = @intCast(self.nodes.items.len - body_start);
            body_starts[tag_idx] = body_start;
            body_lens[tag_idx] = body_len;
        }

        // 结果通道
        const result_chan = try self.allocChannel(result_type orelse type_descriptor_mod.unit_descriptor);

        // route_dispatch with N entries indexed by tag
        const route_meta_idx = try self.addRouteMeta(.{
            .trait_id = 0,
            .method_id = 0,
            .target_count = @intCast(ctor_count),
            .body_starts = body_starts,
            .body_lens = body_lens,
        });
        try self.emit(Node.makeUnary(.route_dispatch, result_chan, route_meta_idx, tag_chan));

        return result_chan;
    }

    /// 递归编译 match arms：当前 arm + 剩余 arms（else 分支）
    pub fn compileMatchArms(self: *IRBuilder, scrutinee: *ast.Expr, scrutinee_chan: u16, arms: []const ast.MatchArm, start_idx: usize) BuildError!u16 {
        // 跳表优化入口：首层 match 且所有 arms 为同一 ADT 构造器模式时，用 __tag 直接索引
        if (start_idx == 0) {
            if (try self.tryCompileJumpTableMatch(scrutinee, scrutinee_chan, arms)) |result_chan| {
                return result_chan;
            }
        }

        if (start_idx >= arms.len) {
            // 无匹配 arm：返回 unit（实际应由 wildcard 兜底）
            const out = try self.allocChannel(type_descriptor_mod.unit_descriptor);
            try self.emit(Node.makeSink(.const_unit, out, 0));
            return out;
        }

        const arm = arms[start_idx];

        // 单 arm 无 guard 且 pattern 总是匹配时，跳过 route_dispatch
        // 直接编译 pattern check（绑定变量）+ body，无需条件选择
        if (start_idx == arms.len - 1 and arm.guard == null and self.patternAlwaysMatches(arm.pattern)) {
            try self.pushScope();
            self.pushGadtBindingsForArm(scrutinee, arm.pattern);
            const saved_scrut = self.current_match_scrutinee;
            self.current_match_scrutinee = scrutinee;
            defer self.current_match_scrutinee = saved_scrut;
            _ = try self.compilePatternCheck(scrutinee_chan, arm.pattern);
            const then_start: u32 = @intCast(self.nodes.items.len);
            const body_chan = try self.compileExpr(arm.body);
            if (self.nodes.items.len == then_start) {
                const load_chan = try self.allocChannel(self.channels.get(body_chan).type_desc);
                try self.emit(Node.makeUnary(.load, load_chan, 0, body_chan));
            }
            self.popGadtBindings();
            self.popScope();
            return body_chan;
        }

        const arena_alloc = self.arena.allocator();

        // push scope for pattern variables（check 和 then body 共享）
        try self.pushScope();

        // GADT 类型推断：在 pattern check 之前推送类型参数绑定
        // 这样 compileConstructorPattern 中的 resolveFieldTypeWithBindings 能查到绑定
        var pushed_bindings = false;
        self.pushGadtBindingsForArm(scrutinee, arm.pattern);
        pushed_bindings = true;
        defer if (pushed_bindings) self.popGadtBindings();

        // 编译 pattern check → cond_chan（bool），同时绑定模式变量
        const saved_scrut = self.current_match_scrutinee;
        self.current_match_scrutinee = scrutinee;
        defer self.current_match_scrutinee = saved_scrut;
        const pat_cond_chan = try self.compilePatternCheck(scrutinee_chan, arm.pattern);

        // 处理 guard：cond = pattern_match AND guard
        const final_cond_chan = if (arm.guard) |guard| blk: {
            const guard_chan = try self.compileExpr(guard);
            const and_chan = try self.allocChannel(type_descriptor_mod.bool_descriptor);
            const meta_idx = try self.addScalarMeta(.{ .kind = .bool });
            try self.emit(Node.makeBinary(.bool_and, and_chan, meta_idx, pat_cond_chan, guard_chan));
            break :blk and_chan;
        } else pat_cond_chan;

        // arm 1 = then 子图（pattern 变量在作用域内）
        const then_start: u32 = @intCast(self.nodes.items.len);
        const body_chan = try self.compileExpr(arm.body);
        if (self.nodes.items.len == then_start) {
            const load_chan = try self.allocChannel(self.channels.get(body_chan).type_desc);
            try self.emit(Node.makeUnary(.load, load_chan, 0, body_chan));
        }
        const then_len: u32 = @intCast(self.nodes.items.len - then_start);

        // pop scope（pattern 变量不再按名可见）
        self.popScope();

        // arm 0 = else 子图（剩余 arms，无 pattern 变量）
        const else_start: u32 = @intCast(self.nodes.items.len);
        const else_chan = try self.compileMatchArms(scrutinee, scrutinee_chan, arms, start_idx + 1);
        if (self.nodes.items.len == else_start) {
            const load_chan = try self.allocChannel(self.channels.get(else_chan).type_desc);
            try self.emit(Node.makeUnary(.load, load_chan, 0, else_chan));
        }
        const else_len: u32 = @intCast(self.nodes.items.len - else_start);

        // winner: bool → i64（true=1→then, false=0→else）
        const winner_chan = try self.allocChannel(type_descriptor_mod.i64_descriptor);
        const cast_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64 });
        try self.emit(Node.makeUnary(.cast, winner_chan, cast_meta, final_cond_chan));

        // 结果类型统一：then/else 任一为 null_chan 而另一为值类型时，结果为 nullable_chan
        const then_meta = self.channels.get(self.nodes.items[then_start + then_len - 1].output);
        const else_meta = self.channels.get(self.nodes.items[else_start + else_len - 1].output);
        const then_type = then_meta.type_desc;
        const result_chan = blk: {
            if (then_type.isNullType() and !else_meta.type_desc.isNullType() and !else_meta.type_desc.isNullable()) {
                break :blk try self.channels.allocNullable(else_meta.type_desc);
            }
            if (else_meta.type_desc.isNullType() and !then_type.isNullType() and !then_type.isNullable()) {
                break :blk try self.channels.allocNullable(then_type);
            }
            if (then_type.isNullable()) {
                break :blk try self.channels.allocNullable(then_meta.inner_type_desc orelse type_descriptor_mod.i64_descriptor);
            }
            if (else_meta.type_desc.isNullable()) {
                break :blk try self.channels.allocNullable(else_meta.inner_type_desc orelse type_descriptor_mod.i64_descriptor);
            }
            break :blk try self.allocChannel(then_type);
        };

        const body_starts = try arena_alloc.alloc(u32, 2);
        const body_lens = try arena_alloc.alloc(u32, 2);
        body_starts[0] = else_start;
        body_lens[0] = else_len;
        body_starts[1] = then_start;
        body_lens[1] = then_len;

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

    /// 编译模式检查：返回 bool 通道（是否匹配），同时绑定模式变量到作用域
    pub fn compilePatternCheck(self: *IRBuilder, scrutinee_chan: u16, pattern: *const ast.Pattern) BuildError!u16 {
        switch (pattern.*) {
            .wildcard => {
                return try self.emitConstBool(true);
            },
            .variable => |v| {
                // 如果变量名是已知构造器（enum variant），作为无参构造器模式处理
                { const sr = self.sema_result;
                    if (sr.getCtorDef(v.name)) |ctor| {
                        if (ctor.field_type_descs.len == 0) {
                            return try self.compileConstructorPattern(scrutinee_chan, v.name, &.{});
                        }
                    }
                }
                // 绑定变量到 scrutinee
                // 对于 nullable scrutinee（如 match Path? { null => ..., p => ... }），
                // 需要 unwrap 后绑定到内部值，使 p.method() 能正确分派到 Path 方法
                const scrut_meta = self.channels.get(scrutinee_chan);
                if (scrut_meta.type_desc.isNullable()) {
                    // nullable unwrap → 内部值通道
                    const unwrapped_chan = try self.allocChannel(scrut_meta.inner_type_desc orelse type_descriptor_mod.i64_descriptor);
                    try self.emit(Node.makeUnary(.nullable_unwrap, unwrapped_chan, 0, scrutinee_chan));
                    // ast_expr 设为 current_match_scrutinee（其 inferTypeNameFromExpr 返回内部类型名，
                    // 因 typeNameFromTypeNodeSimple 会剥 nullable 包装）
                    try self.scopeVarTyped(v.name, unwrapped_chan, false, self.current_match_scrutinee, self.pattern_type_hint);
                } else {
                    // 非 nullable：直接绑定，ast_expr 设为 current_match_scrutinee 以支持类型推断
                    try self.scopeVarTyped(v.name, scrutinee_chan, false, self.current_match_scrutinee, self.pattern_type_hint);
                }
                return try self.emitConstBool(true);
            },
            .literal => |lit| {
                return try self.compileLiteralPattern(scrutinee_chan, lit);
            },
            .constructor => |c| {
                return try self.compileConstructorPattern(scrutinee_chan, c.name, c.patterns);
            },
            .record => |r| {
                return try self.compileRecordPattern(scrutinee_chan, r.fields);
            },
            .or_pattern => |op| {
                // left OR right（变量绑定在两侧都发生，应绑定同名变量）
                const left_chan = try self.compilePatternCheck(scrutinee_chan, op.left);
                const right_chan = try self.compilePatternCheck(scrutinee_chan, op.right);
                const out = try self.allocChannel(type_descriptor_mod.bool_descriptor);
                const meta = try self.addScalarMeta(.{ .kind = .bool });
                try self.emit(Node.makeBinary(.bool_or, out, meta, left_chan, right_chan));
                return out;
            },
            .guard => |g| {
                // pattern AND condition
                const pat_chan = try self.compilePatternCheck(scrutinee_chan, g.pattern);
                const cond_chan = try self.compileExpr(g.condition);
                const out = try self.allocChannel(type_descriptor_mod.bool_descriptor);
                const meta = try self.addScalarMeta(.{ .kind = .bool });
                try self.emit(Node.makeBinary(.bool_and, out, meta, pat_chan, cond_chan));
                return out;
            },
        }
    }

    /// 发射 const_bool 节点
    pub fn emitConstBool(self: *IRBuilder, val: bool) BuildError!u16 {
        const out = try self.allocChannel(type_descriptor_mod.bool_descriptor);
        const meta = try self.addScalarMeta(.{ .kind = .bool, .const_val = .{ .bool_val = val } });
        try self.emit(Node.makeSink(.const_bool, out, meta));
        return out;
    }

    /// 编译字面量模式：scrutinee == literal
    pub fn compileLiteralPattern(self: *IRBuilder, scrutinee_chan: u16, lit: ast.PatternLiteral) BuildError!u16 {
        switch (lit) {
            .int => |raw| {
                const lit_chan = try self.compileIntLiteral(raw, null, null);
                return try self.emitCmpEq(scrutinee_chan, lit_chan);
            },
            .float => |raw| {
                const lit_chan = try self.compileFloatLiteral(raw, null, null);
                return try self.emitCmpEq(scrutinee_chan, lit_chan);
            },
            .bool => |b| {
                const lit_chan = try self.emitConstBool(b);
                return try self.emitCmpEq(scrutinee_chan, lit_chan);
            },
            .char => |c| {
                const lit_chan = try self.allocChannel(type_descriptor_mod.char_descriptor);
                const meta = try self.addScalarMeta(.{ .kind = .char, .const_val = .{ .char_val = c } });
                try self.emit(Node.makeSink(.const_char, lit_chan, meta));
                return try self.emitCmpEq(scrutinee_chan, lit_chan);
            },
            .string => |s| {
                const lit_chan = try self.allocChannel(type_descriptor_mod.ref_descriptor);
                const str_idx = self.addString(s);
                const meta = try self.addScalarMeta(.{ .kind = .str, .const_val = .{ .int_val = @intCast(str_idx) } });
                try self.emit(Node.makeSink(.const_str, lit_chan, meta));
                return try self.emitCmpEq(scrutinee_chan, lit_chan);
            },
            .null => {
                // null 检查：nullable_is_null（仅对 nullable_chan 有效）
                const out = try self.allocChannel(type_descriptor_mod.bool_descriptor);
                try self.emit(Node.makeUnary(.nullable_is_null, out, 0, scrutinee_chan));
                return out;
            },
        }
    }

    /// 发射 cmp_eq 节点：left == right → mask_chan
    pub fn emitCmpEq(self: *IRBuilder, left_chan: u16, right_chan: u16) BuildError!u16 {
        const out = try self.allocChannel(type_descriptor_mod.bool_descriptor);
        const meta = try self.addScalarMeta(.{ .kind = .bool });
        try self.emit(Node.makeBinary(.cmp_eq, out, meta, left_chan, right_chan));
        return out;
    }

    /// 编译构造器模式：Ctor(sub_patterns...)
    /// 检查 __tag == ctor.tag，然后递归检查各字段子模式
    pub fn compileConstructorPattern(self: *IRBuilder, scrutinee_chan: u16, ctor_name: []const u8, sub_patterns: []*ast.Pattern) BuildError!u16 {
        // 内置构造器模式：Ok(...) / Error(...) — ThrowValue 解构
        if (std.mem.eql(u8, ctor_name, "Ok")) {
            // gate_check → is_ok
            const is_ok_chan = try self.allocChannel(type_descriptor_mod.bool_descriptor);
            try self.emit(Node.makeUnary(.gate_check, is_ok_chan, 0, scrutinee_chan));
            if (sub_patterns.len == 0) return is_ok_chan;
            // gate_get_ok → 绑定到子模式（使用 current_throw_ok_type_desc 推断类型）
            const ok_val_chan = try self.allocChannel(self.current_throw_ok_type_desc);
            try self.emit(Node.makeUnary(.gate_get_ok, ok_val_chan, 0, scrutinee_chan));
            // 设置 pattern_type_hint 为 Ok 值的类型节点，使子模式变量获得正确的 type_annotation
            // 用于 l.close() 等方法分派：inferTypeNameFromExpr 通过 type_annotation 返回 "TcpListener"
            const saved_hint = self.pattern_type_hint;
            if (self.current_match_scrutinee) |scrut| {
                if (self.inferThrowOkTypeNode(scrut)) |ok_type_node| {
                    self.pattern_type_hint = ok_type_node;
                }
            }
            const sub_check = try self.compilePatternCheck(ok_val_chan, sub_patterns[0]);
            self.pattern_type_hint = saved_hint;
            const and_chan = try self.allocChannel(type_descriptor_mod.bool_descriptor);
            const meta = try self.addScalarMeta(.{ .kind = .bool });
            try self.emit(Node.makeBinary(.bool_and, and_chan, meta, is_ok_chan, sub_check));
            return and_chan;
        }
        if (std.mem.eql(u8, ctor_name, "Error")) {
            // gate_check → is_ok, 然后 not is_ok → is_err
            const is_ok_chan = try self.allocChannel(type_descriptor_mod.bool_descriptor);
            try self.emit(Node.makeUnary(.gate_check, is_ok_chan, 0, scrutinee_chan));
            const is_err_chan = try self.allocChannel(type_descriptor_mod.bool_descriptor);
            const not_meta = try self.addScalarMeta(.{ .kind = .bool });
            try self.emit(Node.makeUnary(.bool_not, is_err_chan, not_meta, is_ok_chan));
            if (sub_patterns.len == 0) return is_err_chan;
            // gate_get_err → 绑定到子模式
            const err_val_chan = try self.allocChannel(type_descriptor_mod.ref_descriptor);
            try self.emit(Node.makeUnary(.gate_get_err, err_val_chan, 0, scrutinee_chan));
            const sub_check = try self.compilePatternCheck(err_val_chan, sub_patterns[0]);
            const and_chan = try self.allocChannel(type_descriptor_mod.bool_descriptor);
            const meta = try self.addScalarMeta(.{ .kind = .bool });
            try self.emit(Node.makeBinary(.bool_and, and_chan, meta, is_err_chan, sub_check));
            return and_chan;
        }

        const sr = self.sema_result;
        const ctor = sr.getCtorDef(ctor_name) orelse return error.UndefinedFunction;

        // 单构造器类型优化：若类型只有一个构造器，__tag 永远为 0，tag 检查恒为真
        // 跳过 record_get(__tag) + const_i + cmp_eq + cast + route_dispatch + const_bool(false)
        // 直接读取字段并 AND 子模式检查
        const is_single_ctor = blk: {
            if (sr.getTypeDef(ctor.type_name)) |type_info| {
                break :blk type_info.constructors.len == 1;
            }
            break :blk false;
        };
        if (is_single_ctor) {
            const sub_count = @min(sub_patterns.len, ctor.field_type_descs.len);
            if (sub_count == 0) return try self.emitConstBool(true);
            // 全变量/通配符子模式：跳过 AND 链，直接读取字段并绑定
            // Point(x, y) 等 destructure 模式的子模式总是变量绑定，AND 链冗余
            var all_var = true;
            for (sub_patterns[0..sub_count]) |sub| {
                switch (sub.*) {
                    .wildcard, .variable => {},
                    else => all_var = false,
                }
            }
            if (all_var) {
                for (0..sub_count) |i| {
                    const field_meta = try self.addFieldIdMeta(@intCast(i + 1));
                    const field_type_node = self.getCtorAstFieldTypeNode(ctor_name, i);
                    const field_chan_type = self.resolveFieldTypeWithBindings(field_type_node);
                    const field_chan = try self.allocChannel(field_chan_type);
                    try self.emit(Node.makeUnary(.record_get, field_chan, field_meta, scrutinee_chan));
                    const prev_hint = self.pattern_type_hint;
                    self.pattern_type_hint = field_type_node;
                    _ = try self.compilePatternCheck(field_chan, sub_patterns[i]);
                    self.pattern_type_hint = prev_hint;
                }
                return try self.emitConstBool(true);
            }
            var result_chan = try self.emitConstBool(true);
            for (0..sub_count) |i| {
                const field_meta = try self.addFieldIdMeta(@intCast(i + 1));
                const field_type_node = self.getCtorAstFieldTypeNode(ctor_name, i);
                const field_chan_type = self.resolveFieldTypeWithBindings(field_type_node);
                const field_chan = try self.allocChannel(field_chan_type);
                try self.emit(Node.makeUnary(.record_get, field_chan, field_meta, scrutinee_chan));
                const prev_hint = self.pattern_type_hint;
                self.pattern_type_hint = field_type_node;
                const sub_check_chan = try self.compilePatternCheck(field_chan, sub_patterns[i]);
                self.pattern_type_hint = prev_hint;
                const and_chan = try self.allocChannel(type_descriptor_mod.bool_descriptor);
                const and_meta = try self.addScalarMeta(.{ .kind = .bool });
                try self.emit(Node.makeBinary(.bool_and, and_chan, and_meta, result_chan, sub_check_chan));
                result_chan = and_chan;
            }
            return result_chan;
        }

        const arena_alloc = self.arena.allocator();

        // 读取 __tag 字段（field_id=0）
        const tag_field_meta = try self.addFieldIdMeta(0);
        const tag_chan = try self.allocChannel(type_descriptor_mod.i64_descriptor);
        try self.emit(Node.makeUnary(.record_get, tag_chan, tag_field_meta, scrutinee_chan));

        // 期望的 tag 值（构造器在所属类型 constructors 数组中的索引）
        const expected_tag_chan = try self.allocChannel(type_descriptor_mod.i64_descriptor);
        const ctor_tag = self.getCtorTag(ctor_name) orelse return error.UndefinedFunction;
        const expected_tag_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = @intCast(ctor_tag) } });
        try self.emit(Node.makeSink(.const_i, expected_tag_chan, expected_tag_meta));

        // 比较 tag → tag_cond
        const tag_cond = try self.emitCmpEq(tag_chan, expected_tag_chan);

        // 无子模式：直接返回 tag 检查结果（不需要读字段）
        const sub_count = @min(sub_patterns.len, ctor.field_type_descs.len);
        if (sub_count == 0) return tag_cond;

        // 有子模式：字段读取在 tag 匹配时才执行
        // 用 route_dispatch 条件执行（与 compileIf 相同的子图模式）
        const winner_chan = try self.allocChannel(type_descriptor_mod.i64_descriptor);
        const cast_meta = try self.addScalarMeta(.{ .kind = .int, .int_kind = .i64 });
        try self.emit(Node.makeUnary(.cast, winner_chan, cast_meta, tag_cond));

        // arm 0 = else 子图（tag 不匹配 → false）
        const else_start: u32 = @intCast(self.nodes.items.len);
        const false_chan = try self.emitConstBool(false);
        if (self.nodes.items.len == else_start) {
            const load_chan = try self.allocChannel(type_descriptor_mod.bool_descriptor);
            try self.emit(Node.makeUnary(.load, load_chan, 0, false_chan));
        }
        const else_len: u32 = @intCast(self.nodes.items.len - else_start);

        // arm 1 = then 子图（tag 匹配 → 读字段，检查子模式）
        const then_start: u32 = @intCast(self.nodes.items.len);
        var result_chan = try self.emitConstBool(true);
        for (0..sub_count) |i| {
            // 读取字段值（field_id = i+1，因为 0 是 __tag）
            const field_meta = try self.addFieldIdMeta(@intCast(i + 1));
            // 字段类型：用 AST type_node 推导，类型参数通过 GADT 绑定栈解析
            const field_type_node = self.getCtorAstFieldTypeNode(ctor_name, i);
            const field_chan_type = self.resolveFieldTypeWithBindings(field_type_node);
            const field_chan = try self.allocChannel(field_chan_type);
            try self.emit(Node.makeUnary(.record_get, field_chan, field_meta, scrutinee_chan));

            // 设置模式类型提示（供变量绑定使用类型注解）
            const prev_hint = self.pattern_type_hint;
            self.pattern_type_hint = field_type_node;

            // 递归检查子模式（同时绑定模式变量）
            const sub_check_chan = try self.compilePatternCheck(field_chan, sub_patterns[i]);

            // 恢复类型提示
            self.pattern_type_hint = prev_hint;

            // AND 到当前结果
            const and_chan = try self.allocChannel(type_descriptor_mod.bool_descriptor);
            const and_meta = try self.addScalarMeta(.{ .kind = .bool });
            try self.emit(Node.makeBinary(.bool_and, and_chan, and_meta, result_chan, sub_check_chan));
            result_chan = and_chan;
        }
        if (self.nodes.items.len == then_start) {
            const load_chan = try self.allocChannel(type_descriptor_mod.bool_descriptor);
            try self.emit(Node.makeUnary(.load, load_chan, 0, result_chan));
        }
        const then_len: u32 = @intCast(self.nodes.items.len - then_start);

        // route_dispatch 按 winner 索引执行对应子图
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

    /// 编译记录模式：(field1: pat1, field2: pat2, ...)
    /// 字段名通过 field_id_map 解析为 field_id（record literal 的字段按声明顺序 0..N-1）
    pub fn compileRecordPattern(self: *IRBuilder, scrutinee_chan: u16, fields: []const ast.PatternRecordField) BuildError!u16 {
        if (fields.len == 0) return try self.emitConstBool(true);

        var result_chan: ?u16 = null;
        for (fields, 0..) |field, i| {
            // 查找 field_id；若未注册（匿名 record literal 模式），按声明顺序用 i
            const field_id: u16 = self.lookupFieldId("", field.name) orelse @intCast(i);
            const field_meta = try self.addFieldIdMeta(field_id);
            const field_chan = try self.allocChannel(type_descriptor_mod.i64_descriptor);
            try self.emit(Node.makeUnary(.record_get, field_chan, field_meta, scrutinee_chan));

            const sub_check = try self.compilePatternCheck(field_chan, field.pattern);

            if (result_chan) |rc| {
                const and_chan = try self.allocChannel(type_descriptor_mod.bool_descriptor);
                const and_meta = try self.addScalarMeta(.{ .kind = .bool });
                try self.emit(Node.makeBinary(.bool_and, and_chan, and_meta, rc, sub_check));
                result_chan = and_chan;
            } else {
                result_chan = sub_check;
            }
        }
        return result_chan.?;
    }
};
