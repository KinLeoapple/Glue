//! Resolve 预pass：单线程遍历 AST，对每个变量绑定点/引用点调用 interner.intern，
//! 把返回的 u32 id 写进 AST 节点的 name_id 字段。求值器随后用整数键查环境（env.zig）。
//!
//! 关键：本 pass 必须在对应模块求值开始前跑完（单线程），求值期 interner 只读——
//! spawn 在独立 Heap 并发求值，求值期写 interner 会数据竞争（见 plans/fluffy-riding-snowflake.md）。
//!
//! 注意：本 pass 当前只做 intern（填 name_id），不做 De Bruijn (depth,slot) 寻址——
//! 后者跨闭包会被 buildCaptureEnv 单帧压平索引到错误变量，需扁平数组环境才安全。

const std = @import("std");
const ast = @import("ast");
const intern = @import("intern");

pub fn resolveModule(module: *const ast.Module, interner: *intern.Interner) !void {
    for (module.declarations) |*decl| {
        try resolveDecl(decl, interner);
    }
}

fn resolveDecl(decl: *ast.Decl, interner: *intern.Interner) !void {
    switch (decl.*) {
        .fun_decl => |*f| {
            f.name_id = try interner.intern(f.name);
            for (f.params) |*p| {
                p.name_id = try interner.intern(p.name);
            }
            try resolveExpr(f.body, interner);
        },
        .impl_decl => |id| {
            for (id.methods) |m| {
                for (m.params) |*p| {
                    p.name_id = try interner.intern(p.name);
                }
                if (m.body) |b| try resolveExpr(b, interner);
            }
        },
        .trait_decl => |td| {
            for (td.methods) |m| {
                for (m.params) |*p| {
                    p.name_id = try interner.intern(p.name);
                }
                if (m.body) |b| try resolveExpr(b, interner);
            }
        },
        // type_decl / use_decl / pack_decl：无可执行体（构造器/导入名在 eval 时按需 intern）。
        .type_decl, .use_decl, .pack_decl => {},
        // 顶层表达式声明（脚本模式）：解析其 expr 和可选 stmt。
        .expr_decl => |ed| {
            try resolveExpr(ed.expr, interner);
            if (ed.stmt) |s| try resolveStmt(s, interner);
        },
    }
}

fn resolveStmt(stmt: *ast.Stmt, interner: *intern.Interner) anyerror!void {
    switch (stmt.*) {
        .val_decl => |*v| {
            v.name_id = try interner.intern(v.name);
            try resolveExpr(v.value, interner);
        },
        .var_decl => |*v| {
            v.name_id = try interner.intern(v.name);
            try resolveExpr(v.value, interner);
        },
        .assignment => |a| {
            try resolveExpr(a.target, interner);
            try resolveExpr(a.value, interner);
        },
        .field_assignment => |fa| {
            try resolveExpr(fa.object, interner);
            try resolveExpr(fa.value, interner);
        },
        .compound_assignment => |ca| {
            try resolveExpr(ca.target, interner);
            try resolveExpr(ca.value, interner);
        },
        .expression => |e| try resolveExpr(e.expr, interner),
        .return_stmt => |r| {
            if (r.value) |v| try resolveExpr(v, interner);
        },
        .defer_stmt => |d| try resolveExpr(d.expr, interner),
        .throw_stmt => |t| try resolveExpr(t.expr, interner),
        .break_stmt, .continue_stmt => {},
        .for_stmt => |*fs| {
            fs.name_id = try interner.intern(fs.name);
            try resolveExpr(fs.iterable, interner);
            try resolveExpr(fs.body, interner);
        },
        .while_stmt => |ws| {
            try resolveExpr(ws.condition, interner);
            try resolveExpr(ws.body, interner);
        },
        .loop_stmt => |ls| try resolveExpr(ls.body, interner),
    }
}

fn resolvePattern(pat: *ast.Pattern, interner: *intern.Interner) anyerror!void {
    switch (pat.*) {
        .wildcard, .literal => {},
        .variable => |*v| {
            v.name_id = try interner.intern(v.name);
        },
        .constructor => |c| {
            for (c.patterns) |p| try resolvePattern(p, interner);
        },
        .record => |r| {
            for (r.fields) |f| try resolvePattern(f.pattern, interner);
        },
        .or_pattern => |o| {
            try resolvePattern(o.left, interner);
            try resolvePattern(o.right, interner);
        },
        .guard => |g| {
            try resolvePattern(g.pattern, interner);
            try resolveExpr(g.condition, interner);
        },
    }
}

fn resolveExpr(expr: *ast.Expr, interner: *intern.Interner) anyerror!void {
    switch (expr.*) {
        // 字面量：无子节点
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
                    .expression => |e| try resolveExpr(e, interner),
                }
            }
        },

        .identifier => |*id| {
            id.name_id = try interner.intern(id.name);
        },

        .assignment_expr => |ae| {
            try resolveExpr(ae.target, interner);
            try resolveExpr(ae.value, interner);
        },
        .compound_assign => |ca| {
            try resolveExpr(ca.target, interner);
            try resolveExpr(ca.value, interner);
        },
        .binary => |b| {
            try resolveExpr(b.left, interner);
            try resolveExpr(b.right, interner);
        },
        .unary => |u| try resolveExpr(u.operand, interner),
        .call => |c| {
            try resolveExpr(c.callee, interner);
            for (c.arguments) |a| try resolveExpr(a, interner);
        },
        .method_call => |mc| {
            try resolveExpr(mc.object, interner);
            for (mc.arguments) |a| try resolveExpr(a, interner);
        },
        .field_access => |fa| try resolveExpr(fa.object, interner),
        .safe_access => |sa| try resolveExpr(sa.object, interner),
        .safe_method_call => |smc| {
            try resolveExpr(smc.object, interner);
            for (smc.arguments) |a| try resolveExpr(a, interner);
        },
        .non_null_assert => |n| try resolveExpr(n.expr, interner),
        .propagate => |p| try resolveExpr(p.expr, interner),
        .index => |ix| {
            try resolveExpr(ix.object, interner);
            try resolveExpr(ix.index, interner);
        },
        .array_literal => |al| {
            for (al.elements) |e| try resolveExpr(e, interner);
        },
        .record_literal => |rl| {
            for (rl.fields) |f| try resolveExpr(f.value, interner);
        },
        .record_extend => |re| {
            try resolveExpr(re.base, interner);
            for (re.updates) |f| try resolveExpr(f.value, interner);
        },
        .lambda => |*lam| {
            for (lam.params) |*p| {
                p.name_id = try interner.intern(p.name);
            }
            switch (lam.body) {
                .block => |b| try resolveExpr(b, interner),
                .expression => |e| try resolveExpr(e, interner),
            }
        },
        .if_expr => |ie| {
            try resolveExpr(ie.condition, interner);
            try resolveExpr(ie.then_branch, interner);
            if (ie.else_branch) |e| try resolveExpr(e, interner);
        },
        .block => |blk| {
            for (blk.statements) |s| try resolveStmt(s, interner);
            if (blk.trailing_expr) |te| try resolveExpr(te, interner);
        },
        .match => |m| {
            try resolveExpr(m.scrutinee, interner);
            for (m.arms) |arm| {
                try resolvePattern(arm.pattern, interner);
                if (arm.guard) |g| try resolveExpr(g, interner);
                try resolveExpr(arm.body, interner);
            }
        },
        .type_cast => |tc| try resolveExpr(tc.expr, interner),
        .spawn => |sp| try resolveExpr(sp.body, interner),
        .atomic_expr => |ae| try resolveExpr(ae.value, interner),
        .lazy => |lz| try resolveExpr(lz.expr, interner),
        .select => |sel| {
            for (sel.arms) |*arm| {
                switch (arm.*) {
                    .receive => |*r| {
                        if (r.binding) |b| r.binding_id = try interner.intern(b);
                        try resolveExpr(r.channel_expr, interner);
                        try resolveExpr(r.body, interner);
                    },
                    .timeout => |t| {
                        try resolveExpr(t.duration, interner);
                        try resolveExpr(t.body, interner);
                    },
                }
            }
        },
        .monad_comprehension => |mc| {
            for (mc.bindings) |b| try resolveExpr(b.expr, interner);
            try resolveExpr(mc.result, interner);
        },
        .inline_trait_value => |itv| {
            for (itv.methods) |m| {
                for (m.params) |*p| {
                    p.name_id = try interner.intern(p.name);
                }
                if (m.body) |b| try resolveExpr(b, interner);
            }
        },
    }
}
