//! AST 模块调用重写：把同模块短名调用改写为 mangled name。
//!
//! 当子模块 pub 函数被 mangle 为 "Module.Sub.method" 后，函数体内部对同模块
//! 其他函数的短名调用（如 `to_julian_day(...)`）需要同步重写为
//! "Module.Sub.to_julian_day"，否则 sema 会报 undefined variable。
//!
//! renames: 同模块 pub 函数短名 → mangled name 的映射
//!   例: {"to_julian_day": "std.time.Calendar.to_julian_day", ...}
//!
//! sibling_modules: 同 pack 内其他子模块短名 → 完整模块路径的映射
//!   例: {"Calendar": "std.time.Calendar", "Duration": "std.time.Duration", ...}
//!   用于重写跨子模块调用，如 DateTime.add_days 内部的 `Calendar.add_days(...)`
//!   会被重写为 `std.time.Calendar.add_days(...)`。
//!
//! 仅重写 .call 节点中 callee 为 identifier 且 name 命中 renames 的情况，
//! 以及 callee 为 field_access(identifier(short_mod), method) 且 short_mod 命中
//! sibling_modules 的情况。方法调用（method_call）的 method 字段、字段访问
//! （field_access）的 field 字段不需要重写——它们的语义由对象类型决定，
//! 不属于模块函数调用。
//!
//! v3 阶段 16：采用 AstVisitor 模式，仅 4 个特化 hook（call/method_call/
//! field_access/identifier），其余变体走 walkExprChildrenMut 默认递归。
//! 新增 AST 变体只需在 walkExprChildrenMut 补一行子节点遍历。

const std = @import("std");
const ast = @import("ast");

/// 重写上下文：封装 renames/sibling_modules/arena，避免 4 参数透传。
const RewriteCtx = struct {
    renames: *const std.StringHashMap([]const u8),
    sibling_modules: *const std.StringHashMap([]const u8),
    arena: std.mem.Allocator,
};

/// 递归重写表达式 AST 中对同模块函数的短名调用为 mangled name。
pub fn rewriteModuleCalls(
    expr: *ast.Expr,
    renames: *const std.StringHashMap([]const u8),
    sibling_modules: *const std.StringHashMap([]const u8),
    arena: std.mem.Allocator,
) void {
    const ctx = RewriteCtx{
        .renames = renames,
        .sibling_modules = sibling_modules,
        .arena = arena,
    };
    rewriteExprWithCtx(expr, &ctx);
}

/// 递归重写语句 AST 中的子表达式。
pub fn rewriteStmt(
    stmt: *ast.Stmt,
    renames: *const std.StringHashMap([]const u8),
    sibling_modules: *const std.StringHashMap([]const u8),
    arena: std.mem.Allocator,
) void {
    const ctx = RewriteCtx{
        .renames = renames,
        .sibling_modules = sibling_modules,
        .arena = arena,
    };
    rewriteStmtWithCtx(stmt, &ctx);
}

/// 表达式重写核心：4 个特化 hook + 其余走 walkExprChildrenMut 默认递归。
fn rewriteExprWithCtx(expr: *ast.Expr, ctx: *const RewriteCtx) void {
    switch (expr.*) {
        // ── 特化 1: .call ──
        // callee 为 identifier 命中 renames → 替换为 mangled name
        // callee 为 field_access(identifier(sibling_mod), method) → 替换为 mangled identifier
        // callee 为 field_access(非 identifier object) → 递归 callee
        // callee 为其他 → 递归 callee
        // 始终递归 arguments
        .call => |c| {
            if (c.callee.* == .identifier) {
                if (ctx.renames.get(c.callee.identifier.name)) |mangled| {
                    c.callee.* = .{ .identifier = .{ .name = mangled } };
                }
            } else if (c.callee.* == .field_access) {
                const fa = c.callee.field_access;
                if (fa.object.* == .identifier) {
                    if (ctx.sibling_modules.get(fa.object.identifier.name)) |mod_path| {
                        const mangled = std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ mod_path, fa.field }) catch null;
                        if (mangled) |m| {
                            c.callee.* = .{ .identifier = .{ .name = m } };
                        }
                    }
                    // object 是 identifier 但非 sibling_module：不递归 callee（保留变量语义）
                } else {
                    // object 非 identifier：递归 callee（如嵌套 field_access a.b.c）
                    rewriteExprWithCtx(c.callee, ctx);
                }
            } else {
                // callee 非简单 identifier（如嵌套调用 f()(x)）：递归 callee
                rewriteExprWithCtx(c.callee, ctx);
            }
            for (c.arguments) |arg| {
                rewriteExprWithCtx(arg, ctx);
            }
        },

        // ── 特化 2: .method_call ──
        // object 为 identifier 命中 sibling_modules → 转换为 call(identifier(mangled), ...)
        // 否则：递归 object + arguments
        .method_call => |mc| {
            if (mc.object.* == .identifier) {
                if (ctx.sibling_modules.get(mc.object.identifier.name)) |mod_path| {
                    const mangled = std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ mod_path, mc.method }) catch null;
                    if (mangled) |m| {
                        const callee_ptr = ctx.arena.create(ast.Expr) catch {
                            // 分配失败时退回原 method_call 递归（保留旧行为）
                            rewriteExprWithCtx(mc.object, ctx);
                            for (mc.arguments) |arg| {
                                rewriteExprWithCtx(arg, ctx);
                            }
                            return;
                        };
                        expr.* = .{ .call = .{
                            .callee = callee_ptr,
                            .arguments = mc.arguments,
                            .type_args = mc.type_args,
                        } };
                        expr.call.callee.* = .{ .identifier = .{ .name = m } };
                        // arguments 虽然转移到 call，但其内部仍可能含跨模块短名调用
                        for (expr.call.arguments) |arg| {
                            rewriteExprWithCtx(arg, ctx);
                        }
                        return;
                    }
                }
            }
            rewriteExprWithCtx(mc.object, ctx);
            for (mc.arguments) |arg| {
                rewriteExprWithCtx(arg, ctx);
            }
        },

        // ── 特化 3: .field_access ──
        // object 为 identifier 命中 sibling_modules → 重写为 identifier(mangled)
        // 否则：递归 object
        .field_access => |fa| {
            if (fa.object.* == .identifier) {
                if (ctx.sibling_modules.get(fa.object.identifier.name)) |mod_path| {
                    const mangled = std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ mod_path, fa.field }) catch null;
                    if (mangled) |m| {
                        expr.* = .{ .identifier = .{ .name = m } };
                        return;
                    }
                }
            }
            rewriteExprWithCtx(fa.object, ctx);
        },

        // ── 特化 4: .identifier ──
        // 裸标识符命中 renames → 替换为 mangled name
        .identifier => |id| {
            if (ctx.renames.get(id.name)) |mangled| {
                expr.* = .{ .identifier = .{ .name = mangled } };
            }
        },

        // ── 默认：走 walkExprChildrenMut 递归子节点 ──
        else => walkExprChildrenMut(expr, ctx),
    }
}

/// 遍历表达式的所有子节点并递归重写（不含 expr 自身）。
/// 镜像 sema/static_analysis/ast_visitor.walkExprChildren 的结构，
/// 但使用可变指针以支持 AST 就地变换。
fn walkExprChildrenMut(expr: *ast.Expr, ctx: *const RewriteCtx) void {
    switch (expr.*) {
        // 单子节点
        .unary => |u| rewriteExprWithCtx(u.operand, ctx),
        .ref_of => |r| rewriteExprWithCtx(r.operand, ctx),
        .deref => |d| rewriteExprWithCtx(d.operand, ctx),
        .non_null_assert => |n| rewriteExprWithCtx(n.expr, ctx),
        .propagate => |p| rewriteExprWithCtx(p.expr, ctx),
        .safe_access => |s| rewriteExprWithCtx(s.object, ctx),
        .type_cast => |tc| rewriteExprWithCtx(tc.expr, ctx),
        .cast_builder => |cb| rewriteExprWithCtx(cb.expr, ctx),
        .atomic_expr => |ae| rewriteExprWithCtx(ae.value, ctx),
        .lazy => |l| rewriteExprWithCtx(l.expr, ctx),
        .spawn_expr => |se| rewriteExprWithCtx(se.expr, ctx),

        // 双子节点
        .assignment_expr => |a| {
            rewriteExprWithCtx(a.target, ctx);
            rewriteExprWithCtx(a.value, ctx);
        },
        .compound_assign => |c| {
            rewriteExprWithCtx(c.target, ctx);
            rewriteExprWithCtx(c.value, ctx);
        },
        .binary => |b| {
            rewriteExprWithCtx(b.left, ctx);
            rewriteExprWithCtx(b.right, ctx);
        },
        .index => |i| {
            rewriteExprWithCtx(i.object, ctx);
            rewriteExprWithCtx(i.index, ctx);
        },
        .slice => |s| {
            rewriteExprWithCtx(s.object, ctx);
            rewriteExprWithCtx(s.start, ctx);
            rewriteExprWithCtx(s.end, ctx);
        },
        .if_expr => |i| {
            rewriteExprWithCtx(i.condition, ctx);
            rewriteExprWithCtx(i.then_branch, ctx);
            if (i.else_branch) |e| rewriteExprWithCtx(e, ctx);
        },

        // 多子节点
        .safe_method_call => |smc| {
            rewriteExprWithCtx(smc.object, ctx);
            for (smc.arguments) |arg| rewriteExprWithCtx(arg, ctx);
        },
        .array_literal => |al| {
            for (al.elements) |e| rewriteExprWithCtx(e, ctx);
            if (al.fill_value) |fv| rewriteExprWithCtx(fv, ctx);
            if (al.fill_count) |fc| rewriteExprWithCtx(fc, ctx);
        },
        .record_literal => |rl| {
            for (rl.fields) |f| rewriteExprWithCtx(f.value, ctx);
        },
        .record_extend => |re| {
            rewriteExprWithCtx(re.base, ctx);
            for (re.updates) |u| rewriteExprWithCtx(u.value, ctx);
        },
        .string_interpolation => |si| {
            for (si.parts) |p| switch (p) {
                .expression => |e| rewriteExprWithCtx(e, ctx),
                .literal => {},
            };
        },

        // 含语句的表达式
        .block => |blk| {
            for (blk.statements) |s| rewriteStmtWithCtx(s, ctx);
            if (blk.trailing_expr) |te| rewriteExprWithCtx(te, ctx);
        },

        // match：scrutinee + arms（guard + body）
        .match => |m| {
            rewriteExprWithCtx(m.scrutinee, ctx);
            for (m.arms) |arm| {
                if (arm.guard) |g| rewriteExprWithCtx(g, ctx);
                rewriteExprWithCtx(arm.body, ctx);
            }
        },

        // lambda：body
        .lambda => |l| switch (l.body) {
            .block => |b| rewriteExprWithCtx(b, ctx),
            .expression => |e| rewriteExprWithCtx(e, ctx),
        },

        // select：arms 的 channel_expr + body
        .select => |sel| {
            for (sel.arms) |arm| switch (arm) {
                .receive => |r| {
                    rewriteExprWithCtx(r.channel_expr, ctx);
                    rewriteExprWithCtx(r.body, ctx);
                },
                .timeout => |t| {
                    rewriteExprWithCtx(t.duration, ctx);
                    rewriteExprWithCtx(t.body, ctx);
                },
            };
        },

        .inline_trait_value => |itv| {
            for (itv.methods) |m| {
                if (m.body) |b| rewriteExprWithCtx(b, ctx);
            }
        },

        // 叶子节点：无子表达式
        .int_literal, .float_literal, .bool_literal, .char_literal,
        .string_literal, .null_literal, .unit_literal,
        => {},

        // 特化变体（call/method_call/field_access/identifier）由 rewriteExprWithCtx
        // 处理，不会到达此函数。列出以保持 exhaustive switch 的编译期安全。
        .call, .method_call, .field_access, .identifier => {},
    }
}

/// 语句重写：遍历所有子表达式并递归重写。
/// 语句层无特化需求，全部委托给表达式重写器。
fn rewriteStmtWithCtx(stmt: *ast.Stmt, ctx: *const RewriteCtx) void {
    switch (stmt.*) {
        .val_decl => |v| rewriteExprWithCtx(v.value, ctx),
        .var_decl => |v| rewriteExprWithCtx(v.value, ctx),
        .assignment => |a| {
            rewriteExprWithCtx(a.target, ctx);
            rewriteExprWithCtx(a.value, ctx);
        },
        .field_assignment => |f| {
            rewriteExprWithCtx(f.object, ctx);
            rewriteExprWithCtx(f.value, ctx);
        },
        .compound_assignment => |c| {
            rewriteExprWithCtx(c.target, ctx);
            rewriteExprWithCtx(c.value, ctx);
        },
        .expression => |e| rewriteExprWithCtx(e.expr, ctx),
        .return_stmt => |r| {
            if (r.value) |v| rewriteExprWithCtx(v, ctx);
        },
        .defer_stmt => |d| rewriteExprWithCtx(d.expr, ctx),
        .throw_stmt => |t| rewriteExprWithCtx(t.expr, ctx),
        .for_stmt => |f| {
            rewriteExprWithCtx(f.iterable, ctx);
            rewriteExprWithCtx(f.body, ctx);
        },
        .while_stmt => |w| {
            rewriteExprWithCtx(w.condition, ctx);
            rewriteExprWithCtx(w.body, ctx);
        },
        .loop_stmt => |l| rewriteExprWithCtx(l.body, ctx),
        .break_stmt, .continue_stmt => {},
    }
}
