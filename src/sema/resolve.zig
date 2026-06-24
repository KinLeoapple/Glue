//! Resolve 预pass：单线程遍历 AST，做两件事：
//! 1. intern：把变量/参数/字段名 intern 成 u32 id，写进 AST 节点的 name_id 字段。
//! 2. De Bruijn 词法地址（任务#2）：对可证明正确的局部变量，在 identifier.resolved 填
//!    .local + (depth, slot)，求值器据此走数组快路径;其余留 .unresolved（回退到 name_id 哈希）。
//!
//! 关键：本 pass 必须在对应模块求值开始前跑完（单线程），求值期 interner 只读——
//! spawn 在独立 Heap 并发求值，求值期写 interner 会数据竞争。
//!
//! 安全核心（见 plans/fluffy-riding-snowflake.md 风险表）：scope 栈**当且仅当 evaluator 调
//! createChild 时压一层**——函数体是两帧（call_env 参数 + block_env 体）。任何 off-by-one
//! 会被 env.getLocal 的 name_id 断言在首次错读时响亮 panic。不确定一律留 .unresolved。

const std = @import("std");
const ast = @import("ast");
const intern = @import("intern");

/// 一个 scope 对应运行时一个 createChild 帧。
const Scope = struct {
    /// 本帧的绑定：name_id -> slot 索引。
    bindings: std.AutoHashMap(u32, u16),
    /// 是否函数边界（参数帧）。解析引用时跨过它即说明变量是 upvalue/global（被 buildCaptureEnv
    /// 压平进 capture_env），不能用 (depth,slot)。
    is_function_boundary: bool,
    /// 本帧是否支持 slot 快路径（block 帧与参数帧支持;match/select/spawn 等不支持）。
    slottable: bool,
    /// 下一个可分配 slot。
    next_slot: u16 = 0,
};

const Resolver = struct {
    interner: *intern.Interner,
    allocator: std.mem.Allocator,
    scopes: std.ArrayList(Scope),
    /// 进入 spawn body 后置 true：其内引用全部留 unresolved（deepCopy 重构帧链，depth 模型失效）。
    in_spawn: bool = false,

    fn pushScope(self: *Resolver, is_fn_boundary: bool, slottable: bool) !void {
        try self.scopes.append(self.allocator, .{
            .bindings = std.AutoHashMap(u32, u16).init(self.allocator),
            .is_function_boundary = is_fn_boundary,
            .slottable = slottable,
        });
    }

    fn popScope(self: *Resolver) void {
        var s = self.scopes.pop().?;
        s.bindings.deinit();
    }

    fn topScope(self: *Resolver) *Scope {
        return &self.scopes.items[self.scopes.items.len - 1];
    }

    /// 在当前 scope 注册一个绑定，返回分配的 slot。重复同名 → 返回 null（调用方据此把
    /// 该名引用降级 unresolved,因 evaluator 的 map 覆盖语义与 slot 不一致）。
    /// 无 scope（模块顶层,绑定进 global_env）→ 返回 null,不参与 slot 快路径。
    fn bind(self: *Resolver, id: u32) !?u16 {
        if (self.scopes.items.len == 0) return null; // 顶层绑定:全局,无 slot
        const top = self.topScope();
        if (top.bindings.contains(id)) {
            return null; // 同帧重复同名:不可靠,降级
        }
        const slot = top.next_slot;
        top.next_slot += 1;
        try top.bindings.put(id, slot);
        return slot;
    }

    /// 解析一个引用 id：从内向外扫 scope 栈。跨函数边界前在某 slottable 帧找到 → .local。
    /// 找不到/跨边界/in_spawn/帧不可 slot → .unresolved（求值器回退 map）。
    fn resolveRef(self: *Resolver, id: u32) ast.ResolvedRef {
        if (self.in_spawn) return .{ .kind = .unresolved };
        var depth: u16 = 0;
        var i: usize = self.scopes.items.len;
        var crossed_boundary = false;
        while (i > 0) {
            i -= 1;
            const sc = &self.scopes.items[i];
            if (sc.bindings.get(id)) |slot| {
                // 跨过函数边界后找到 → 是 upvalue（capture_env 压平,按 id 查）,不能用 depth/slot。
                if (crossed_boundary) return .{ .kind = .unresolved };
                if (!sc.slottable) return .{ .kind = .unresolved };
                return .{ .kind = .local, .depth = depth, .slot = slot };
            }
            // 经过这一帧未命中:depth +1（每个 scope=一个运行时帧）。
            depth += 1;
            if (sc.is_function_boundary) crossed_boundary = true;
        }
        return .{ .kind = .unresolved };
    }
};

pub fn resolveModule(module: *const ast.Module, interner: *intern.Interner) !void {
    var r = Resolver{
        .interner = interner,
        .allocator = interner.allocator,
        .scopes = std.ArrayList(Scope).empty,
    };
    defer r.scopes.deinit(r.allocator);
    for (module.declarations) |*decl| {
        try resolveDecl(&r, decl);
    }
}

fn resolveDecl(r: *Resolver, decl: *ast.Decl) !void {
    switch (decl.*) {
        .fun_decl => |*f| {
            f.name_id = try r.interner.intern(f.name);
            try resolveFnLike(r, f.params, f.body);
        },
        .impl_decl => |id| {
            for (id.methods) |m| {
                if (m.body) |b| try resolveFnLike(r, m.params, b);
            }
        },
        .trait_decl => |td| {
            for (td.methods) |m| {
                if (m.body) |b| try resolveFnLike(r, m.params, b);
            }
        },
        .type_decl, .import_decl, .pack_decl => {},
        .expr_decl => |ed| {
            try resolveExpr(r, ed.expr);
            if (ed.stmt) |s| try resolveStmt(r, s);
        },
    }
}

/// 函数/方法/lambda：参数帧（call_env，函数边界）+ 函数体（body 是 block → block_env）。
/// 这是运行时两帧的精确镜像（eval.zig callFunction 建 call_env，evalExpr(body) 建 block_env）。
fn resolveFnLike(r: *Resolver, params: []ast.Param, body: *ast.Expr) !void {
    try r.pushScope(true, true); // 参数帧（函数边界,可 slot）
    for (params, 0..) |*p, i| {
        p.name_id = try r.interner.intern(p.name);
        p.slot = @intCast(i);
        _ = try r.bind(p.name_id);
    }
    // body 是 block：resolveExpr(.block) 会自己再 pushScope（body block_env），构成第二帧。
    try resolveExpr(r, body);
    r.popScope();
}

fn resolveStmt(r: *Resolver, stmt: *ast.Stmt) anyerror!void {
    switch (stmt.*) {
        .val_decl => |*v| {
            v.name_id = try r.interner.intern(v.name);
            try resolveExpr(r, v.value); // 先解析 RHS（此时绑定尚未生效,符合 let 语义）
            const slot = try r.bind(v.name_id);
            v.slot = if (slot) |s| s else 0;
        },
        .var_decl => |*v| {
            v.name_id = try r.interner.intern(v.name);
            try resolveExpr(r, v.value);
            const slot = try r.bind(v.name_id);
            v.slot = if (slot) |s| s else 0;
        },
        .assignment => |a| {
            try resolveExpr(r, a.target);
            try resolveExpr(r, a.value);
        },
        .field_assignment => |fa| {
            try resolveExpr(r, fa.object);
            try resolveExpr(r, fa.value);
        },
        .compound_assignment => |ca| {
            try resolveExpr(r, ca.target);
            try resolveExpr(r, ca.value);
        },
        .expression => |e| try resolveExpr(r, e.expr),
        .return_stmt => |rs| {
            if (rs.value) |v| try resolveExpr(r, v);
        },
        .defer_stmt => |d| try resolveExpr(r, d.expr),
        .throw_stmt => |t| try resolveExpr(r, t.expr),
        .break_stmt, .continue_stmt => {},
        .for_stmt => |*fs| {
            fs.name_id = try r.interner.intern(fs.name);
            try resolveExpr(r, fs.iterable);
            // for 每轮建 loop_env（1 个 slot:循环变量）+ body block_env。Stage 1 暂不给 loop 变量
            // slot 快路径,但**必须压一层 scope** 保持 depth 模型正确（body 内引用外层变量的 depth）。
            try r.pushScope(false, false); // loop_env:不可 slot（Stage 3 再开）
            _ = try r.bind(fs.name_id);
            try resolveExpr(r, fs.body);
            r.popScope();
        },
        .while_stmt => |ws| {
            try resolveExpr(r, ws.condition);
            try resolveExpr(r, ws.body); // body 是 block,自己 pushScope
        },
        .loop_stmt => |ls| try resolveExpr(r, ls.body),
    }
}

fn resolvePattern(r: *Resolver, pat: *ast.Pattern) anyerror!void {
    switch (pat.*) {
        .wildcard, .literal => {},
        .variable => |*v| {
            v.name_id = try r.interner.intern(v.name);
        },
        .constructor => |c| {
            for (c.patterns) |p| try resolvePattern(r, p);
        },
        .record => |rec| {
            for (rec.fields) |f| try resolvePattern(r, f.pattern);
        },
        .or_pattern => |o| {
            try resolvePattern(r, o.left);
            try resolvePattern(r, o.right);
        },
        .guard => |g| {
            try resolvePattern(r, g.pattern);
            try resolveExpr(r, g.condition);
        },
    }
}

fn resolveExpr(r: *Resolver, expr: *ast.Expr) anyerror!void {
    switch (expr.*) {
        .int_literal,
        .float_literal,
        .string_literal,
        .char_literal,
        .bool_literal,
        .null_literal,
        .unit_literal,
        => {},

        .string_interpolation => |si| {
            for (si.parts) |part| {
                switch (part) {
                    .literal => {},
                    .expression => |e| try resolveExpr(r, e),
                }
            }
        },

        .identifier => |*id| {
            id.name_id = try r.interner.intern(id.name);
            id.resolved = r.resolveRef(id.name_id);
        },

        .assignment_expr => |ae| {
            try resolveExpr(r, ae.target);
            try resolveExpr(r, ae.value);
        },
        .compound_assign => |ca| {
            try resolveExpr(r, ca.target);
            try resolveExpr(r, ca.value);
        },
        .binary => |b| {
            try resolveExpr(r, b.left);
            try resolveExpr(r, b.right);
        },
        .unary => |u| try resolveExpr(r, u.operand),
        .call => |c| {
            try resolveExpr(r, c.callee);
            for (c.arguments) |a| try resolveExpr(r, a);
        },
        .method_call => |mc| {
            try resolveExpr(r, mc.object);
            for (mc.arguments) |a| try resolveExpr(r, a);
        },
        .field_access => |fa| try resolveExpr(r, fa.object),
        .safe_access => |sa| try resolveExpr(r, sa.object),
        .safe_method_call => |smc| {
            try resolveExpr(r, smc.object);
            for (smc.arguments) |a| try resolveExpr(r, a);
        },
        .non_null_assert => |n| try resolveExpr(r, n.expr),
        .propagate => |p| try resolveExpr(r, p.expr),
        .index => |ix| {
            try resolveExpr(r, ix.object);
            try resolveExpr(r, ix.index);
        },
        .array_literal => |al| {
            for (al.elements) |e| try resolveExpr(r, e);
        },
        .record_literal => |rl| {
            for (rl.fields) |f| try resolveExpr(r, f.value);
        },
        .record_extend => |re| {
            try resolveExpr(r, re.base);
            for (re.updates) |f| try resolveExpr(r, f.value);
        },
        .lambda => |*lam| {
            switch (lam.body) {
                .block => |b| try resolveFnLike(r, lam.params, b),
                .expression => |e| {
                    // 表达式体 lambda：参数帧 + body 直接是表达式（无 block_env）。
                    try r.pushScope(true, true);
                    for (lam.params, 0..) |*p, i| {
                        p.name_id = try r.interner.intern(p.name);
                        p.slot = @intCast(i);
                        _ = try r.bind(p.name_id);
                    }
                    try resolveExpr(r, e);
                    r.popScope();
                },
            }
        },
        .if_expr => |ie| {
            try resolveExpr(r, ie.condition);
            try resolveExpr(r, ie.then_branch); // 分支体是 block,自己 pushScope
            if (ie.else_branch) |e| try resolveExpr(r, e);
        },
        .block => |*blk| {
            try r.pushScope(false, true); // block_env（非函数边界,可 slot）
            for (blk.statements) |s| try resolveStmt(r, s);
            if (blk.trailing_expr) |te| try resolveExpr(r, te);
            // 块内 val/var 声明数 = 本帧分配的 slot 数,填进 AST 供 createChildSized 预分配。
            blk.slot_count = r.topScope().next_slot;
            r.popScope();
        },
        .match => |m| {
            try resolveExpr(r, m.scrutinee);
            for (m.arms) |arm| {
                // match arm 建 match_env（pattern 变量绑入）。Stage 1 不给 match 变量 slot 快路径：
                // 压一层不可 slot 的 scope 保持 depth 正确,arm body 内引用模式变量 → unresolved。
                try r.pushScope(false, false);
                try resolvePattern(r, arm.pattern);
                if (arm.guard) |g| try resolveExpr(r, g);
                try resolveExpr(r, arm.body);
                r.popScope();
            }
        },
        .type_cast => |tc| try resolveExpr(r, tc.expr),
        .spawn => |sp| {
            // spawn body 经 deepCopy 重构帧链,depth 模型失效 → 内部全 unresolved。
            const saved = r.in_spawn;
            r.in_spawn = true;
            try resolveExpr(r, sp.body);
            r.in_spawn = saved;
        },
        .atomic_expr => |ae| try resolveExpr(r, ae.value),
        .lazy => |lz| try resolveExpr(r, lz.expr),
        .select => |sel| {
            for (sel.arms) |*arm| {
                switch (arm.*) {
                    .receive => |*rec| {
                        if (rec.binding) |b| rec.binding_id = try r.interner.intern(b);
                        try resolveExpr(r, rec.channel_expr);
                        // select 接收绑定定义进非子帧（eval.zig:5116）,depth 模型不适用 → body 内
                        // 对该绑定的引用必须回退。简单起见整个 select body 不参与 slot（不 push 帧,
                        // 但 receive 绑定也不进任何 scope → 对它的引用自然 unresolved）。
                        try resolveExpr(r, rec.body);
                    },
                    .timeout => |t| {
                        try resolveExpr(r, t.duration);
                        try resolveExpr(r, t.body);
                    },
                }
            }
        },
        .monad_comprehension => |mc| {
            for (mc.bindings) |b| try resolveExpr(r, b.expr);
            try resolveExpr(r, mc.result);
        },
        .inline_trait_value => |itv| {
            for (itv.methods) |m| {
                if (m.body) |b| try resolveFnLike(r, m.params, b);
            }
        },
    }
}
