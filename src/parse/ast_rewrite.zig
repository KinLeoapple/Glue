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
//! field_access/identifier），其余变体委托 sema/ast_visitor.walkExprChildrenMut
//! 默认递归。新增 AST 变体只需在 sema/ast_visitor.zig 的 walkExprChildrenMut
//! 补一行子节点遍历，parse 层无需改动。

const std = @import("std");
const ast = @import("ast");
const ast_visitor = @import("ast_visitor");

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

/// walkExprChildrenMut 的 callback 适配器：把 (*anyopaque, *Expr) 转发回 rewriteExprWithCtx。
/// rewriteExprWithCtx 内部无抛错路径（allocPrint 用 catch null），故此处永远返回成功。
fn rewriteExprCb(opaque_ctx: *anyopaque, expr: *ast.Expr) anyerror!void {
    const c: *const RewriteCtx = @ptrCast(@alignCast(opaque_ctx));
    rewriteExprWithCtx(expr, c);
}

/// 表达式重写核心：4 个特化 hook + 其余委托 sema/ast_visitor.walkExprChildrenMut 默认递归。
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

        // ── 默认：委托 sema/ast_visitor.walkExprChildrenMut 递归子节点 ──
        else => ast_visitor.walkExprChildrenMut(@constCast(@ptrCast(ctx)), expr, rewriteExprCb) catch {},
    }
}

/// 语句重写：遍历所有子表达式并递归重写。
/// 语句层无特化需求，全部委托 sema/ast_visitor.walkStmtChildrenMut。
fn rewriteStmtWithCtx(stmt: *ast.Stmt, ctx: *const RewriteCtx) void {
    ast_visitor.walkStmtChildrenMut(@constCast(@ptrCast(ctx)), stmt, rewriteExprCb) catch {};
}
