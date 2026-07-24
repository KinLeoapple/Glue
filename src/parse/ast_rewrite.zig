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
//! 纯 AST 变换，无副作用，可独立单测。

const std = @import("std");
const ast = @import("ast");

/// 递归重写表达式 AST 中对同模块函数的短名调用为 mangled name。
pub fn rewriteModuleCalls(
    expr: *ast.Expr,
    renames: *const std.StringHashMap([]const u8),
    sibling_modules: *const std.StringHashMap([]const u8),
    arena: std.mem.Allocator,
) void {
    switch (expr.*) {
        .call => |c| {
            // callee 是 identifier 且短名命中 renames → 替换为 mangled name
            if (c.callee.* == .identifier) {
                const short_name = c.callee.identifier.name;
                if (renames.get(short_name)) |mangled| {
                    c.callee.* = .{ .identifier = .{ .name = mangled } };
                }
            } else if (c.callee.* == .field_access) {
                // callee 是 field_access：可能是跨子模块调用 Calendar.add_days(...)
                const fa = c.callee.field_access;
                if (fa.object.* == .identifier) {
                    const mod_name = fa.object.identifier.name;
                    if (sibling_modules.get(mod_name)) |mod_path| {
                        // 重写 Calendar.add_days → std.time.Calendar.add_days（作为单一 identifier）
                        const mangled = std.fmt.allocPrint(arena, "{s}.{s}", .{ mod_path, fa.field }) catch null;
                        if (mangled) |m| {
                            c.callee.* = .{ .identifier = .{ .name = m } };
                        }
                    }
                } else {
                    // object 非 identifier 时仍需递归
                    rewriteModuleCalls(c.callee, renames, sibling_modules, arena);
                }
            } else {
                // callee 非简单 identifier 时仍需递归（如嵌套调用 f()(x)）
                rewriteModuleCalls(c.callee, renames, sibling_modules, arena);
            }
            for (c.arguments) |arg| {
                rewriteModuleCalls(arg, renames, sibling_modules, arena);
            }
        },
        .method_call => |mc| {
            // 跨子模块调用：Calendar.add_days(...) → 转换为 call(identifier("std.time.Calendar.add_days"), ...)
            if (mc.object.* == .identifier) {
                const mod_name = mc.object.identifier.name;
                if (sibling_modules.get(mod_name)) |mod_path| {
                    const mangled = std.fmt.allocPrint(arena, "{s}.{s}", .{ mod_path, mc.method }) catch null;
                    if (mangled) |m| {
                        // 将 method_call 转换为 call，callee 为单一 identifier
                        const callee_ptr = arena.create(ast.Expr) catch {
                            // 分配失败时退回原 method_call 递归（保留旧行为）
                            rewriteModuleCalls(mc.object, renames, sibling_modules, arena);
                            for (mc.arguments) |arg| {
                                rewriteModuleCalls(arg, renames, sibling_modules, arena);
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
                        // （如 File.open(path, File.read_only()) 的第二个参数 File.read_only()），
                        // 必须递归重写
                        for (expr.call.arguments) |arg| {
                            rewriteModuleCalls(arg, renames, sibling_modules, arena);
                        }
                        return;
                    }
                }
            }
            rewriteModuleCalls(mc.object, renames, sibling_modules, arena);
            for (mc.arguments) |arg| {
                rewriteModuleCalls(arg, renames, sibling_modules, arena);
            }
        },
        .field_access => |fa| {
            // 跨子模块常量值引用：File.DEFAULT_BUF_SIZE → identifier("std.io.File.DEFAULT_BUF_SIZE")
            // 仅当 fa.object 为 identifier 且命中 sibling_modules 时执行重写；
            // 否则按一般表达式递归处理 object（保留对 a.b.c 等链式访问的语义）。
            if (fa.object.* == .identifier) {
                const mod_name = fa.object.identifier.name;
                if (sibling_modules.get(mod_name)) |mod_path| {
                    const mangled = std.fmt.allocPrint(arena, "{s}.{s}", .{ mod_path, fa.field }) catch null;
                    if (mangled) |m| {
                        expr.* = .{ .identifier = .{ .name = m } };
                        return;
                    }
                }
            }
            rewriteModuleCalls(fa.object, renames, sibling_modules, arena);
        },
        .safe_access => |sa| rewriteModuleCalls(sa.object, renames, sibling_modules, arena),
        .safe_method_call => |smc| {
            rewriteModuleCalls(smc.object, renames, sibling_modules, arena);
            for (smc.arguments) |arg| {
                rewriteModuleCalls(arg, renames, sibling_modules, arena);
            }
        },
        .binary => |b| {
            rewriteModuleCalls(b.left, renames, sibling_modules, arena);
            rewriteModuleCalls(b.right, renames, sibling_modules, arena);
        },
        .unary => |u| rewriteModuleCalls(u.operand, renames, sibling_modules, arena),
        .ref_of => |r| rewriteModuleCalls(r.operand, renames, sibling_modules, arena),
        .deref => |d| rewriteModuleCalls(d.operand, renames, sibling_modules, arena),
        .assignment_expr => |ae| {
            rewriteModuleCalls(ae.target, renames, sibling_modules, arena);
            rewriteModuleCalls(ae.value, renames, sibling_modules, arena);
        },
        .compound_assign => |ca| {
            rewriteModuleCalls(ca.target, renames, sibling_modules, arena);
            rewriteModuleCalls(ca.value, renames, sibling_modules, arena);
        },
        .non_null_assert => |nna| rewriteModuleCalls(nna.expr, renames, sibling_modules, arena),
        .propagate => |p| rewriteModuleCalls(p.expr, renames, sibling_modules, arena),
        .index => |idx| {
            rewriteModuleCalls(idx.object, renames, sibling_modules, arena);
            rewriteModuleCalls(idx.index, renames, sibling_modules, arena);
        },
        .slice => |sl| {
            rewriteModuleCalls(sl.object, renames, sibling_modules, arena);
            rewriteModuleCalls(sl.start, renames, sibling_modules, arena);
            rewriteModuleCalls(sl.end, renames, sibling_modules, arena);
        },
        .array_literal => |al| {
            for (al.elements) |e| rewriteModuleCalls(e, renames, sibling_modules, arena);
            if (al.fill_value) |fv| rewriteModuleCalls(fv, renames, sibling_modules, arena);
            if (al.fill_count) |fc| rewriteModuleCalls(fc, renames, sibling_modules, arena);
        },
        .record_literal => |rl| {
            for (rl.fields) |f| rewriteModuleCalls(f.value, renames, sibling_modules, arena);
        },
        .record_extend => |re| {
            rewriteModuleCalls(re.base, renames, sibling_modules, arena);
            for (re.updates) |u| rewriteModuleCalls(u.value, renames, sibling_modules, arena);
        },
        .string_interpolation => |si| {
            for (si.parts) |p| switch (p) {
                .expression => |e| rewriteModuleCalls(e, renames, sibling_modules, arena),
                .literal => {},
            };
        },
        .type_cast => |tc| rewriteModuleCalls(tc.expr, renames, sibling_modules, arena),
        .cast_builder => |cb| rewriteModuleCalls(cb.expr, renames, sibling_modules, arena),
        .atomic_expr => |ae| rewriteModuleCalls(ae.value, renames, sibling_modules, arena),
        .lazy => |l| rewriteModuleCalls(l.expr, renames, sibling_modules, arena),
        .spawn_expr => |se| rewriteModuleCalls(se.expr, renames, sibling_modules, arena),
        .if_expr => |ie| {
            rewriteModuleCalls(ie.condition, renames, sibling_modules, arena);
            rewriteModuleCalls(ie.then_branch, renames, sibling_modules, arena);
            if (ie.else_branch) |eb| rewriteModuleCalls(eb, renames, sibling_modules, arena);
        },
        .block => |blk| {
            for (blk.statements) |s| rewriteStmt(s, renames, sibling_modules, arena);
            if (blk.trailing_expr) |te| rewriteModuleCalls(te, renames, sibling_modules, arena);
        },
        .match => |m| {
            rewriteModuleCalls(m.scrutinee, renames, sibling_modules, arena);
            for (m.arms) |arm| {
                if (arm.guard) |g| rewriteModuleCalls(g, renames, sibling_modules, arena);
                rewriteModuleCalls(arm.body, renames, sibling_modules, arena);
            }
        },
        .lambda => |l| switch (l.body) {
            .block => |b| rewriteModuleCalls(b, renames, sibling_modules, arena),
            .expression => |e| rewriteModuleCalls(e, renames, sibling_modules, arena),
        },
        .select => |sel| {
            for (sel.arms) |arm| switch (arm) {
                .receive => |r| {
                    rewriteModuleCalls(r.channel_expr, renames, sibling_modules, arena);
                    rewriteModuleCalls(r.body, renames, sibling_modules, arena);
                },
                .timeout => |t| {
                    rewriteModuleCalls(t.duration, renames, sibling_modules, arena);
                    rewriteModuleCalls(t.body, renames, sibling_modules, arena);
                },
            };
        },
        .inline_trait_value => |itv| {
            for (itv.methods) |m| {
                if (m.body) |b| rewriteModuleCalls(b, renames, sibling_modules, arena);
            }
        },
        .identifier => |id| {
            // 同模块 pub val 常量值引用：O_RDONLY → std.io.File.O_RDONLY
            // 仅当裸标识符命中 renames（同模块 pub fun/val）时执行重写
            if (renames.get(id.name)) |mangled| {
                expr.* = .{ .identifier = .{ .name = mangled } };
            }
        },
        .int_literal,
        .float_literal,
        .bool_literal,
        .char_literal,
        .string_literal,
        .null_literal,
        .unit_literal,
        => {},
    }
}

pub fn rewriteStmt(
    stmt: *ast.Stmt,
    renames: *const std.StringHashMap([]const u8),
    sibling_modules: *const std.StringHashMap([]const u8),
    arena: std.mem.Allocator,
) void {
    switch (stmt.*) {
        .val_decl => |vd| rewriteModuleCalls(vd.value, renames, sibling_modules, arena),
        .var_decl => |vd| rewriteModuleCalls(vd.value, renames, sibling_modules, arena),
        .assignment => |a| {
            rewriteModuleCalls(a.target, renames, sibling_modules, arena);
            rewriteModuleCalls(a.value, renames, sibling_modules, arena);
        },
        .field_assignment => |fa| {
            rewriteModuleCalls(fa.object, renames, sibling_modules, arena);
            rewriteModuleCalls(fa.value, renames, sibling_modules, arena);
        },
        .compound_assignment => |ca| {
            rewriteModuleCalls(ca.target, renames, sibling_modules, arena);
            rewriteModuleCalls(ca.value, renames, sibling_modules, arena);
        },
        .expression => |e| rewriteModuleCalls(e.expr, renames, sibling_modules, arena),
        .return_stmt => |r| {
            if (r.value) |v| rewriteModuleCalls(v, renames, sibling_modules, arena);
        },
        .defer_stmt => |d| rewriteModuleCalls(d.expr, renames, sibling_modules, arena),
        .throw_stmt => |t| rewriteModuleCalls(t.expr, renames, sibling_modules, arena),
        .for_stmt => |f| {
            rewriteModuleCalls(f.iterable, renames, sibling_modules, arena);
            rewriteModuleCalls(f.body, renames, sibling_modules, arena);
        },
        .while_stmt => |w| {
            rewriteModuleCalls(w.condition, renames, sibling_modules, arena);
            rewriteModuleCalls(w.body, renames, sibling_modules, arena);
        },
        .loop_stmt => |l| rewriteModuleCalls(l.body, renames, sibling_modules, arena),
        .break_stmt, .continue_stmt => {},
    }
}
