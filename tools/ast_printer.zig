//! AST 打印器（Zig 侧）
//!
//! 将 Zig 解析器产出的 AST 序列化为规范 S-表达式文本。
//! 输出格式必须与 rust/src/ast/printer.rs 完全一致，用于 diff 验证。
//!
//! 用法：ast_printer <file.glue>
//! 从 stdin 读取时：ast_printer -

const std = @import("std");
const ast = @import("ast");
const lexer_mod = @import("lexer");
const parser_mod = @import("parser");

const Printer = struct {
    buf: std.ArrayList(u8),
    indent_level: usize,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) Printer {
        return .{
            .buf = .empty,
            .indent_level = 0,
            .allocator = allocator,
        };
    }

    fn deinit(self: *Printer) void {
        self.buf.deinit(self.allocator);
    }

    fn indent(self: *Printer) void {
        self.indent_level += 1;
    }

    fn dedent(self: *Printer) void {
        if (self.indent_level > 0) self.indent_level -= 1;
    }

    fn writeLine(self: *Printer, text: []const u8) anyerror!void {
        var i: usize = 0;
        while (i < self.indent_level) : (i += 1) {
            try self.buf.appendSlice(self.allocator, "  ");
        }
        try self.buf.appendSlice(self.allocator, text);
        try self.buf.append(self.allocator, '\n');
    }

    fn writeFmt(self: *Printer, comptime fmt: []const u8, args: anytype) anyerror!void {
        var buf: [4096]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch return error.FormatTooLong;
        try self.writeLine(s);
    }

    // --- 模块 ---

    fn printModule(self: *Printer, module: *const ast.Module) anyerror!void {
        try self.writeFmt("(module \"{s}\"", .{module.name});
        self.indent();
        if (module.source_path) |path| {
            try self.writeFmt("(source_path \"{s}\")", .{path});
        }
        for (module.declarations) |*decl| {
            try self.printDecl(decl);
        }
        self.dedent();
        try self.writeLine(")");
    }

    // --- 声明 ---

    fn printDecl(self: *Printer, decl: *const ast.Decl) anyerror!void {
        switch (decl.*) {
            .fun_decl => |fd| {
                try self.writeFmt("(fun_decl \"{s}\"", .{fd.name});
                self.indent();
                try self.printVisibility(fd.visibility);
                try self.printTypeParams(fd.type_params);
                try self.printParams(fd.params);
                try self.printReturnType(fd.return_type);
                try self.printBounds(fd.bounds);
                try self.writeFmt("(is_async {})(is_entry {})", .{ fd.is_async, fd.is_entry });
                try self.writeLine("(body");
                self.indent();
                try self.printExpr(fd.body);
                self.dedent();
                try self.writeLine(")");
                self.dedent();
                try self.writeLine(")");
            },
            .type_decl => |td| {
                try self.writeFmt("(type_decl \"{s}\"", .{td.name});
                self.indent();
                try self.printVisibility(td.visibility);
                try self.printTypeParams(td.type_params);
                try self.printBounds(td.implemented_traits);
                try self.printTypeConstraints(td.type_constraints);
                try self.printTypeDef(&td.def);
                try self.printMethods(td.methods);
                self.dedent();
                try self.writeLine(")");
            },
            .trait_decl => |td| {
                try self.writeFmt("(trait_decl \"{s}\"", .{td.name});
                self.indent();
                try self.printVisibility(td.visibility);
                try self.printTypeParams(td.type_params);
                try self.printBounds(td.parents);
                try self.printAssociatedTypes(td.associated_types);
                try self.printMethods(td.methods);
                self.dedent();
                try self.writeLine(")");
            },
            .import_decl => |id| {
                // 拼接 module_path
                var path_buf: std.ArrayList(u8) = .empty;
                defer path_buf.deinit(self.allocator);
                for (id.module_path, 0..) |seg, i| {
                    if (i > 0) try path_buf.append(self.allocator, '.');
                    try path_buf.appendSlice(self.allocator, seg);
                }
                try self.writeFmt("(import_decl \"{s}\"", .{path_buf.items});
                self.indent();
                try self.printVisibility(id.visibility);
                if (id.items) |items| {
                    try self.writeLine("(items");
                    self.indent();
                    for (items) |item| {
                        if (item.alias) |alias| {
                            try self.writeFmt("(item \"{s}\" (alias \"{s}\"))", .{ item.name, alias });
                        } else {
                            try self.writeFmt("(item \"{s}\")", .{item.name});
                        }
                    }
                    self.dedent();
                    try self.writeLine(")");
                } else {
                    try self.writeLine("(items (none))");
                }
                self.dedent();
                try self.writeLine(")");
            },
            .pack_decl => |pd| {
                try self.writeFmt("(pack_decl \"{s}\"", .{pd.name});
                self.indent();
                try self.printVisibility(pd.visibility);
                self.dedent();
                try self.writeLine(")");
            },
            .expr_decl => |ed| {
                try self.writeLine("(expr_decl");
                self.indent();
                try self.printExpr(ed.expr);
                if (ed.stmt) |s| {
                    try self.writeLine("(stmt");
                    self.indent();
                    try self.printStmt(s);
                    self.dedent();
                    try self.writeLine(")");
                } else {
                    try self.writeLine("(stmt (none))");
                }
                self.dedent();
                try self.writeLine(")");
            },
        }
    }

    // --- 类型定义 ---

    fn printTypeDef(self: *Printer, def: *const ast.TypeDef) anyerror!void {
        switch (def.*) {
            .adt => |adt| {
                try self.writeLine("(adt");
                self.indent();
                for (adt.constructors) |ctor| {
                    try self.writeFmt("(constructor \"{s}\"", .{ctor.name});
                    self.indent();
                    if (ctor.fields.len == 0) {
                        try self.writeLine("(fields ())");
                    } else {
                        try self.writeLine("(fields");
                        self.indent();
                        for (ctor.fields) |field| {
                            if (field.name) |fname| {
                                try self.writeFmt("(field \"{s}\"", .{fname});
                                self.indent();
                                try self.printType(field.ty);
                                self.dedent();
                                try self.writeLine(")");
                            } else {
                                try self.writeLine("(positional_field");
                                self.indent();
                                try self.printType(field.ty);
                                self.dedent();
                                try self.writeLine(")");
                            }
                        }
                        self.dedent();
                        try self.writeLine(")");
                    }
                    if (ctor.return_type) |rt| {
                        try self.writeLine("(return_type");
                        self.indent();
                        try self.printType(rt);
                        self.dedent();
                        try self.writeLine(")");
                    } else {
                        try self.writeLine("(return_type (none))");
                    }
                    self.dedent();
                    try self.writeLine(")");
                }
                self.dedent();
                try self.writeLine(")");
            },
            .record => |rec| {
                try self.writeLine("(record");
                self.indent();
                if (rec.fields.len == 0) {
                    try self.writeLine("(fields ())");
                } else {
                    try self.writeLine("(fields");
                    self.indent();
                    for (rec.fields) |field| {
                        try self.writeFmt("(field \"{s}\"", .{field.name});
                        self.indent();
                        try self.printType(field.ty);
                        self.dedent();
                        try self.writeLine(")");
                    }
                    self.dedent();
                    try self.writeLine(")");
                }
                self.dedent();
                try self.writeLine(")");
            },
            .alias => |al| {
                try self.writeLine("(alias");
                self.indent();
                try self.printType(al.target);
                self.dedent();
                try self.writeLine(")");
            },
            .newtype => |nt| {
                try self.writeFmt("(newtype \"{s}\"", .{nt.name});
                self.indent();
                try self.printType(nt.inner);
                self.dedent();
                try self.writeLine(")");
            },
            .error_newtype => |en| {
                try self.writeFmt("(error_newtype \"{s}\"", .{en.name});
                self.indent();
                try self.printParams(en.params);
                self.dedent();
                try self.writeLine(")");
            },
        }
    }

    // --- 方法 ---

    fn printMethods(self: *Printer, methods: []const ast.MethodDecl) anyerror!void {
        if (methods.len == 0) {
            try self.writeLine("(methods ())");
            return;
        }
        try self.writeLine("(methods");
        self.indent();
        for (methods) |*m| {
            try self.printMethod(m);
        }
        self.dedent();
        try self.writeLine(")");
    }

    fn printMethod(self: *Printer, m: *const ast.MethodDecl) anyerror!void {
        try self.writeFmt("(method \"{s}\"", .{m.name});
        self.indent();
        try self.printVisibility(m.visibility);
        try self.writeFmt("(is_async {})(is_override {})", .{ m.is_async, m.is_override });
        try self.printTypeParams(m.type_params);
        try self.printParams(m.params);
        try self.printReturnType(m.return_type);
        if (m.delegate) |dl| {
            try self.writeFmt("(delegate (trait \"{s}\") (method \"{s}\"))", .{ dl.trait_name, dl.method_name });
        } else {
            try self.writeLine("(delegate (none))");
        }
        if (m.body) |body| {
            try self.writeLine("(body");
            self.indent();
            try self.printExpr(body);
            self.dedent();
            try self.writeLine(")");
        } else {
            try self.writeLine("(body (none))");
        }
        self.dedent();
        try self.writeLine(")");
    }

    fn printAssociatedTypes(self: *Printer, assoc: []const ast.AssociatedType) anyerror!void {
        if (assoc.len == 0) {
            try self.writeLine("(associated_types ())");
            return;
        }
        try self.writeLine("(associated_types");
        self.indent();
        for (assoc) |at| {
            try self.writeFmt("(associated_type \"{s}\"", .{at.name});
            self.indent();
            if (at.kind) |k| {
                try self.writeLine("(kind");
                self.indent();
                try self.printKind(k);
                self.dedent();
                try self.writeLine(")");
            } else {
                try self.writeLine("(kind (none))");
            }
            self.dedent();
            try self.writeLine(")");
        }
        self.dedent();
        try self.writeLine(")");
    }

    fn printTypeConstraints(self: *Printer, constraints: []const ast.TypeConstraint) anyerror!void {
        if (constraints.len == 0) {
            try self.writeLine("(type_constraints ())");
            return;
        }
        try self.writeLine("(type_constraints");
        self.indent();
        for (constraints) |c| {
            try self.writeFmt("(constraint \"{s}\"", .{c.type_param});
            self.indent();
            try self.printType(c.concrete_type);
            self.dedent();
            try self.writeLine(")");
        }
        self.dedent();
        try self.writeLine(")");
    }

    // --- 可见性/参数/约束 ---

    fn printVisibility(self: *Printer, vis: ast.Visibility) anyerror!void {
        switch (vis) {
            .private => try self.writeLine("(visibility private)"),
            .public => try self.writeLine("(visibility public)"),
        }
    }

    fn printTypeParams(self: *Printer, params: []const ast.TypeParam) anyerror!void {
        if (params.len == 0) {
            try self.writeLine("(type_params ())");
            return;
        }
        try self.writeLine("(type_params");
        self.indent();
        for (params) |tp| {
            try self.writeFmt("(type_param \"{s}\"", .{tp.name});
            self.indent();
            if (tp.kind) |k| {
                try self.writeLine("(kind");
                self.indent();
                try self.printKind(k);
                self.dedent();
                try self.writeLine(")");
            } else {
                try self.writeLine("(kind (none))");
            }
            try self.printBounds(tp.bounds);
            self.dedent();
            try self.writeLine(")");
        }
        self.dedent();
        try self.writeLine(")");
    }

    fn printParams(self: *Printer, params: []const ast.Param) anyerror!void {
        if (params.len == 0) {
            try self.writeLine("(params ())");
            return;
        }
        try self.writeLine("(params");
        self.indent();
        for (params) |p| {
            try self.writeFmt("(param \"{s}\"", .{p.name});
            self.indent();
            if (p.type_annotation) |ty| {
                try self.writeLine("(type");
                self.indent();
                try self.printType(ty);
                self.dedent();
                try self.writeLine(")");
            } else {
                try self.writeLine("(type (none))");
            }
            self.dedent();
            try self.writeLine(")");
        }
        self.dedent();
        try self.writeLine(")");
    }

    fn printBounds(self: *Printer, bounds: []const ast.TraitBound) anyerror!void {
        if (bounds.len == 0) {
            try self.writeLine("(bounds ())");
            return;
        }
        try self.writeLine("(bounds");
        self.indent();
        for (bounds) |b| {
            try self.writeFmt("(trait_bound \"{s}\"", .{b.trait_name});
            self.indent();
            if (b.type_args.len == 0) {
                try self.writeLine("(type_args ())");
            } else {
                try self.writeLine("(type_args");
                self.indent();
                for (b.type_args) |arg| {
                    try self.printType(arg);
                }
                self.dedent();
                try self.writeLine(")");
            }
            self.dedent();
            try self.writeLine(")");
        }
        self.dedent();
        try self.writeLine(")");
    }

    fn printReturnType(self: *Printer, rt: ?*ast.TypeNode) anyerror!void {
        if (rt) |ty| {
            try self.writeLine("(return_type");
            self.indent();
            try self.printType(ty);
            self.dedent();
            try self.writeLine(")");
        } else {
            try self.writeLine("(return_type (none))");
        }
    }

    // --- 类型节点 ---

    fn printType(self: *Printer, ty: *const ast.TypeNode) anyerror!void {
        switch (ty.*) {
            .named => |n| try self.writeFmt("(type_named \"{s}\")", .{n.name}),
            .self_type => try self.writeLine("(type_self)"),
            .generic => |g| {
                try self.writeFmt("(type_generic \"{s}\"", .{g.name});
                self.indent();
                if (g.args.len == 0) {
                    try self.writeLine("(type_args ())");
                } else {
                    try self.writeLine("(type_args");
                    self.indent();
                    for (g.args) |arg| {
                        try self.printType(arg);
                    }
                    self.dedent();
                    try self.writeLine(")");
                }
                self.dedent();
                try self.writeLine(")");
            },
            .nullable => |nb| {
                try self.writeLine("(type_nullable");
                self.indent();
                try self.printType(nb.inner);
                self.dedent();
                try self.writeLine(")");
            },
            .ref_type => |rt| {
                try self.writeLine("(type_ref");
                self.indent();
                try self.printType(rt.inner);
                self.dedent();
                try self.writeLine(")");
            },
            .raw_ptr => |rp| {
                try self.writeLine("(type_raw_ptr");
                self.indent();
                try self.printType(rp.inner);
                self.dedent();
                try self.writeLine(")");
            },
            .function => |fn_t| {
                try self.writeLine("(type_function");
                self.indent();
                if (fn_t.params.len == 0) {
                    try self.writeLine("(params ())");
                } else {
                    try self.writeLine("(params");
                    self.indent();
                    for (fn_t.params) |p| {
                        try self.printType(p);
                    }
                    self.dedent();
                    try self.writeLine(")");
                }
                try self.writeLine("(return_type");
                self.indent();
                try self.printType(fn_t.return_type);
                self.dedent();
                try self.writeLine(")");
                self.dedent();
                try self.writeLine(")");
            },
            .record => |rec| {
                try self.writeLine("(type_record");
                self.indent();
                if (rec.fields.len == 0) {
                    try self.writeLine("(fields ())");
                } else {
                    try self.writeLine("(fields");
                    self.indent();
                    for (rec.fields) |field| {
                        try self.writeFmt("(field \"{s}\"", .{field.name});
                        self.indent();
                        try self.printType(field.ty);
                        self.dedent();
                        try self.writeLine(")");
                    }
                    self.dedent();
                    try self.writeLine(")");
                }
                self.dedent();
                try self.writeLine(")");
            },
            .array => |arr| {
                try self.writeLine("(type_array");
                self.indent();
                try self.writeLine("(element_type");
                self.indent();
                try self.printType(arr.element_type);
                self.dedent();
                try self.writeLine(")");
                if (arr.size) |s| {
                    try self.writeFmt("(size {})", .{s});
                } else {
                    try self.writeLine("(size (none))");
                }
                self.dedent();
                try self.writeLine(")");
            },
            .kind_annotated => |ka| {
                try self.writeLine("(type_kind_annotated");
                self.indent();
                try self.printType(ka.inner);
                try self.writeLine("(kind");
                self.indent();
                try self.printKind(ka.kind);
                self.dedent();
                try self.writeLine(")");
                self.dedent();
                try self.writeLine(")");
            },
        }
    }

    fn printKind(self: *Printer, kind: *const ast.Kind) anyerror!void {
        switch (kind.*) {
            .star => try self.writeLine("(kind_star)"),
            .arrow => |ar| {
                try self.writeLine("(kind_arrow");
                self.indent();
                try self.writeLine("(param");
                self.indent();
                try self.printKind(ar.param);
                self.dedent();
                try self.writeLine(")");
                try self.writeLine("(result");
                self.indent();
                try self.printKind(ar.result);
                self.dedent();
                try self.writeLine(")");
                self.dedent();
                try self.writeLine(")");
            },
        }
    }

    // --- 表达式 ---

    fn printExpr(self: *Printer, expr: *const ast.Expr) anyerror!void {
        switch (expr.*) {
            .int_literal => |il| {
                if (il.suffix) |s| {
                    try self.writeFmt("(int_lit \"{s}\" (suffix \"{s}\"))", .{ il.raw, s });
                } else {
                    try self.writeFmt("(int_lit \"{s}\" (suffix (none)))", .{il.raw});
                }
            },
            .float_literal => |fl| {
                if (fl.suffix) |s| {
                    try self.writeFmt("(float_lit \"{s}\" (suffix \"{s}\"))", .{ fl.raw, s });
                } else {
                    try self.writeFmt("(float_lit \"{s}\" (suffix (none)))", .{fl.raw});
                }
            },
            .bool_literal => |bl| {
                try self.writeFmt("(bool_lit {})", .{bl.value});
            },
            .char_literal => |cl| {
                try self.writeFmt("(char_lit {})", .{cl.value});
            },
            .string_literal => |sl| {
                const escaped = try escapeStr(self.allocator, sl.value);
                defer self.allocator.free(escaped);
                try self.writeFmt("(str_lit \"{s}\")", .{escaped});
            },
            .string_interpolation => |si| {
                try self.writeLine("(str_interp");
                self.indent();
                for (si.parts) |part| {
                    switch (part) {
                        .literal => |text| {
                            const escaped = try escapeStr(self.allocator, text);
                            defer self.allocator.free(escaped);
                            try self.writeFmt("(literal \"{s}\")", .{escaped});
                        },
                        .expression => |e| {
                            try self.writeLine("(expression");
                            self.indent();
                            try self.printExpr(e);
                            self.dedent();
                            try self.writeLine(")");
                        },
                    }
                }
                self.dedent();
                try self.writeLine(")");
            },
            .null_literal => try self.writeLine("(null_lit)"),
            .unit_literal => try self.writeLine("(void_lit)"),
            .identifier => |id| try self.writeFmt("(ident \"{s}\")", .{id.name}),
            .assignment_expr => |ae| {
                try self.writeLine("(assign");
                self.indent();
                try self.writeLine("(target");
                self.indent();
                try self.printExpr(ae.target);
                self.dedent();
                try self.writeLine(")");
                try self.writeLine("(value");
                self.indent();
                try self.printExpr(ae.value);
                self.dedent();
                try self.writeLine(")");
                self.dedent();
                try self.writeLine(")");
            },
            .compound_assign => |ca| {
                try self.writeLine("(compound_assign");
                self.indent();
                try self.printCompoundAssignOp(ca.op);
                try self.writeLine("(target");
                self.indent();
                try self.printExpr(ca.target);
                self.dedent();
                try self.writeLine(")");
                try self.writeLine("(value");
                self.indent();
                try self.printExpr(ca.value);
                self.dedent();
                try self.writeLine(")");
                self.dedent();
                try self.writeLine(")");
            },
            .binary => |bn| {
                try self.writeLine("(binary");
                self.indent();
                try self.printBinaryOp(bn.op);
                try self.writeLine("(lhs");
                self.indent();
                try self.printExpr(bn.left);
                self.dedent();
                try self.writeLine(")");
                try self.writeLine("(rhs");
                self.indent();
                try self.printExpr(bn.right);
                self.dedent();
                try self.writeLine(")");
                self.dedent();
                try self.writeLine(")");
            },
            .unary => |un| {
                try self.writeLine("(unary");
                self.indent();
                try self.printUnaryOp(un.op);
                try self.writeLine("(operand");
                self.indent();
                try self.printExpr(un.operand);
                self.dedent();
                try self.writeLine(")");
                self.dedent();
                try self.writeLine(")");
            },
            .ref_of => |rf| {
                try self.writeLine("(ref_of");
                self.indent();
                try self.printExpr(rf.operand);
                self.dedent();
                try self.writeLine(")");
            },
            .deref => |dr| {
                try self.writeLine("(deref");
                self.indent();
                try self.printExpr(dr.operand);
                self.dedent();
                try self.writeLine(")");
            },
            .call => |cl| {
                try self.writeLine("(call");
                self.indent();
                try self.writeLine("(callee");
                self.indent();
                try self.printExpr(cl.callee);
                self.dedent();
                try self.writeLine(")");
                try self.printTypeArgsOpt(cl.type_args);
                try self.printExprList("args", cl.arguments);
                self.dedent();
                try self.writeLine(")");
            },
            .method_call => |mc| {
                try self.writeFmt("(method_call \"{s}\"", .{mc.method});
                self.indent();
                try self.writeLine("(recv");
                self.indent();
                try self.printExpr(mc.object);
                self.dedent();
                try self.writeLine(")");
                try self.printTypeArgsOpt(mc.type_args);
                try self.printExprList("args", mc.arguments);
                self.dedent();
                try self.writeLine(")");
            },
            .field_access => |fa| {
                try self.writeFmt("(field_access \"{s}\"", .{fa.field});
                self.indent();
                try self.printExpr(fa.object);
                self.dedent();
                try self.writeLine(")");
            },
            .index => |idx| {
                try self.writeLine("(index");
                self.indent();
                try self.writeLine("(recv");
                self.indent();
                try self.printExpr(idx.object);
                self.dedent();
                try self.writeLine(")");
                try self.writeLine("(index");
                self.indent();
                try self.printExpr(idx.index);
                self.dedent();
                try self.writeLine(")");
                self.dedent();
                try self.writeLine(")");
            },
            .slice => |sl| {
                try self.writeFmt("(slice (inclusive {})", .{sl.inclusive});
                self.indent();
                try self.writeLine("(recv");
                self.indent();
                try self.printExpr(sl.object);
                self.dedent();
                try self.writeLine(")");
                try self.writeLine("(start");
                self.indent();
                try self.printExpr(sl.start);
                self.dedent();
                try self.writeLine(")");
                try self.writeLine("(end");
                self.indent();
                try self.printExpr(sl.end);
                self.dedent();
                try self.writeLine(")");
                self.dedent();
                try self.writeLine(")");
            },
            .safe_access => |sa| {
                try self.writeFmt("(safe_access \"{s}\"", .{sa.field});
                self.indent();
                try self.printExpr(sa.object);
                self.dedent();
                try self.writeLine(")");
            },
            .safe_method_call => |smc| {
                try self.writeFmt("(safe_method_call \"{s}\"", .{smc.method});
                self.indent();
                try self.writeLine("(recv");
                self.indent();
                try self.printExpr(smc.object);
                self.dedent();
                try self.writeLine(")");
                try self.printTypeArgsOpt(smc.type_args);
                try self.printExprList("args", smc.arguments);
                self.dedent();
                try self.writeLine(")");
            },
            .propagate => |pg| {
                try self.writeLine("(propagate");
                self.indent();
                try self.printExpr(pg.expr);
                self.dedent();
                try self.writeLine(")");
            },
            .non_null_assert => |nna| {
                try self.writeLine("(non_null_assert");
                self.indent();
                try self.printExpr(nna.expr);
                self.dedent();
                try self.writeLine(")");
            },
            .array_literal => |al| {
                try self.writeLine("(array_lit");
                self.indent();
                try self.printExprList("elements", al.elements);
                if (al.fill_value) |fv| {
                    try self.writeLine("(fill");
                    self.indent();
                    try self.writeLine("(value");
                    self.indent();
                    try self.printExpr(fv);
                    self.dedent();
                    try self.writeLine(")");
                    if (al.fill_count) |fc| {
                        try self.writeLine("(count");
                        self.indent();
                        try self.printExpr(fc);
                        self.dedent();
                        try self.writeLine(")");
                    }
                    self.dedent();
                    try self.writeLine(")");
                } else {
                    try self.writeLine("(fill (none))");
                }
                self.dedent();
                try self.writeLine(")");
            },
            .record_literal => |rl| {
                try self.writeLine("(record_lit");
                self.indent();
                if (rl.fields.len == 0) {
                    try self.writeLine("(fields ())");
                } else {
                    try self.writeLine("(fields");
                    self.indent();
                    for (rl.fields) |f| {
                        try self.writeFmt("(field \"{s}\"", .{f.name});
                        self.indent();
                        try self.printExpr(f.value);
                        self.dedent();
                        try self.writeLine(")");
                    }
                    self.dedent();
                    try self.writeLine(")");
                }
                self.dedent();
                try self.writeLine(")");
            },
            .record_extend => |re| {
                try self.writeLine("(record_extend");
                self.indent();
                try self.writeLine("(base");
                self.indent();
                try self.printExpr(re.base);
                self.dedent();
                try self.writeLine(")");
                if (re.updates.len == 0) {
                    try self.writeLine("(updates ())");
                } else {
                    try self.writeLine("(updates");
                    self.indent();
                    for (re.updates) |f| {
                        try self.writeFmt("(field \"{s}\"", .{f.name});
                        self.indent();
                        try self.printExpr(f.value);
                        self.dedent();
                        try self.writeLine(")");
                    }
                    self.dedent();
                    try self.writeLine(")");
                }
                self.dedent();
                try self.writeLine(")");
            },
            .lambda => |lm| {
                try self.writeFmt("(lambda (is_async {})", .{lm.is_async});
                self.indent();
                try self.printParams(lm.params);
                try self.printReturnType(lm.return_type);
                switch (lm.body) {
                    .block => |b| {
                        try self.writeLine("(body_block");
                        self.indent();
                        try self.printExpr(b);
                        self.dedent();
                        try self.writeLine(")");
                    },
                    .expression => |b| {
                        try self.writeLine("(body_expr");
                        self.indent();
                        try self.printExpr(b);
                        self.dedent();
                        try self.writeLine(")");
                    },
                }
                self.dedent();
                try self.writeLine(")");
            },
            .if_expr => |ie| {
                try self.writeLine("(if");
                self.indent();
                try self.writeLine("(cond");
                self.indent();
                try self.printExpr(ie.condition);
                self.dedent();
                try self.writeLine(")");
                try self.writeLine("(then");
                self.indent();
                try self.printExpr(ie.then_branch);
                self.dedent();
                try self.writeLine(")");
                if (ie.else_branch) |e| {
                    try self.writeLine("(else");
                    self.indent();
                    try self.printExpr(e);
                    self.dedent();
                    try self.writeLine(")");
                } else {
                    try self.writeLine("(else (none))");
                }
                self.dedent();
                try self.writeLine(")");
            },
            .block => |bl| {
                try self.writeLine("(block");
                self.indent();
                if (bl.statements.len == 0) {
                    try self.writeLine("(stmts ())");
                } else {
                    try self.writeLine("(stmts");
                    self.indent();
                    for (bl.statements) |s| {
                        try self.printStmt(s);
                    }
                    self.dedent();
                    try self.writeLine(")");
                }
                if (bl.trailing_expr) |e| {
                    try self.writeLine("(trailing");
                    self.indent();
                    try self.printExpr(e);
                    self.dedent();
                    try self.writeLine(")");
                } else {
                    try self.writeLine("(trailing (none))");
                }
                self.dedent();
                try self.writeLine(")");
            },
            .match => |mt| {
                try self.writeLine("(match");
                self.indent();
                try self.writeLine("(scrutinee");
                self.indent();
                try self.printExpr(mt.scrutinee);
                self.dedent();
                try self.writeLine(")");
                if (mt.arms.len == 0) {
                    try self.writeLine("(arms ())");
                } else {
                    try self.writeLine("(arms");
                    self.indent();
                    for (mt.arms) |arm| {
                        try self.writeLine("(arm");
                        self.indent();
                        try self.writeLine("(pattern");
                        self.indent();
                        try self.printPattern(arm.pattern);
                        self.dedent();
                        try self.writeLine(")");
                        if (arm.guard) |g| {
                            try self.writeLine("(guard");
                            self.indent();
                            try self.printExpr(g);
                            self.dedent();
                            try self.writeLine(")");
                        } else {
                            try self.writeLine("(guard (none))");
                        }
                        try self.writeLine("(body");
                        self.indent();
                        try self.printExpr(arm.body);
                        self.dedent();
                        try self.writeLine(")");
                        self.dedent();
                        try self.writeLine(")");
                    }
                    self.dedent();
                    try self.writeLine(")");
                }
                self.dedent();
                try self.writeLine(")");
            },
            .type_cast => |tc| {
                try self.writeFmt("(type_cast (safe {})", .{tc.safe});
                self.indent();
                try self.writeLine("(target");
                self.indent();
                try self.printType(tc.target_type);
                self.dedent();
                try self.writeLine(")");
                try self.writeLine("(expr");
                self.indent();
                try self.printExpr(tc.expr);
                self.dedent();
                try self.writeLine(")");
                self.dedent();
                try self.writeLine(")");
            },
            .cast_builder => |cb| {
                try self.writeFmt("(cast_builder (mode {s})", .{castModeStr(cb.mode)});
                self.indent();
                try self.writeLine("(expr");
                self.indent();
                try self.printExpr(cb.expr);
                self.dedent();
                try self.writeLine(")");
                try self.writeLine("(target");
                self.indent();
                try self.printType(cb.target_type);
                self.dedent();
                try self.writeLine(")");
                self.dedent();
                try self.writeLine(")");
            },
            .atomic_expr => |ae| {
                try self.writeLine("(atomic");
                self.indent();
                try self.printExpr(ae.value);
                self.dedent();
                try self.writeLine(")");
            },
            .lazy => |lz| {
                try self.writeLine("(lazy");
                self.indent();
                try self.printExpr(lz.expr);
                self.dedent();
                try self.writeLine(")");
            },
            .select => |sel| {
                try self.writeLine("(select");
                self.indent();
                if (sel.arms.len == 0) {
                    try self.writeLine("(arms ())");
                } else {
                    try self.writeLine("(arms");
                    self.indent();
                    for (sel.arms) |arm| {
                        switch (arm) {
                            .receive => |rc| {
                                try self.writeLine("(receive");
                                self.indent();
                                try self.writeLine("(channel");
                                self.indent();
                                try self.printExpr(rc.channel_expr);
                                self.dedent();
                                try self.writeLine(")");
                                if (rc.binding) |name| {
                                    try self.writeFmt("(binding \"{s}\")", .{name});
                                } else {
                                    try self.writeLine("(binding (none))");
                                }
                                try self.writeLine("(body");
                                self.indent();
                                try self.printExpr(rc.body);
                                self.dedent();
                                try self.writeLine(")");
                                self.dedent();
                                try self.writeLine(")");
                            },
                            .timeout => |to| {
                                try self.writeLine("(timeout");
                                self.indent();
                                try self.writeLine("(duration");
                                self.indent();
                                try self.printExpr(to.duration);
                                self.dedent();
                                try self.writeLine(")");
                                try self.writeLine("(body");
                                self.indent();
                                try self.printExpr(to.body);
                                self.dedent();
                                try self.writeLine(")");
                                self.dedent();
                                try self.writeLine(")");
                            },
                        }
                    }
                    self.dedent();
                    try self.writeLine(")");
                }
                self.dedent();
                try self.writeLine(")");
            },
            .inline_trait_value => |itv| {
                try self.writeLine("(inline_trait");
                self.indent();
                try self.printMethods(itv.methods);
                self.dedent();
                try self.writeLine(")");
            },
        }
    }

    // --- 语句 ---

    fn printStmt(self: *Printer, stmt: *const ast.Stmt) anyerror!void {
        switch (stmt.*) {
            .val_decl => |vd| {
                try self.writeFmt("(val_decl \"{s}\"", .{vd.name});
                self.indent();
                try self.printVisibility(vd.visibility);
                if (vd.type_annotation) |ty| {
                    try self.writeLine("(type");
                    self.indent();
                    try self.printType(ty);
                    self.dedent();
                    try self.writeLine(")");
                } else {
                    try self.writeLine("(type (none))");
                }
                try self.writeLine("(value");
                self.indent();
                try self.printExpr(vd.value);
                self.dedent();
                try self.writeLine(")");
                self.dedent();
                try self.writeLine(")");
            },
            .var_decl => |vd| {
                try self.writeFmt("(var_decl \"{s}\"", .{vd.name});
                self.indent();
                try self.printVisibility(vd.visibility);
                if (vd.type_annotation) |ty| {
                    try self.writeLine("(type");
                    self.indent();
                    try self.printType(ty);
                    self.dedent();
                    try self.writeLine(")");
                } else {
                    try self.writeLine("(type (none))");
                }
                try self.writeLine("(value");
                self.indent();
                try self.printExpr(vd.value);
                self.dedent();
                try self.writeLine(")");
                self.dedent();
                try self.writeLine(")");
            },
            .assignment => |asg| {
                try self.writeLine("(assignment");
                self.indent();
                try self.writeLine("(target");
                self.indent();
                try self.printExpr(asg.target);
                self.dedent();
                try self.writeLine(")");
                try self.writeLine("(value");
                self.indent();
                try self.printExpr(asg.value);
                self.dedent();
                try self.writeLine(")");
                self.dedent();
                try self.writeLine(")");
            },
            .field_assignment => |fa| {
                try self.writeFmt("(field_assignment \"{s}\"", .{fa.field});
                self.indent();
                try self.writeLine("(object");
                self.indent();
                try self.printExpr(fa.object);
                self.dedent();
                try self.writeLine(")");
                try self.writeLine("(value");
                self.indent();
                try self.printExpr(fa.value);
                self.dedent();
                try self.writeLine(")");
                self.dedent();
                try self.writeLine(")");
            },
            .compound_assignment => |ca| {
                try self.writeLine("(compound_assignment");
                self.indent();
                try self.printCompoundAssignOp(ca.op);
                try self.writeLine("(target");
                self.indent();
                try self.printExpr(ca.target);
                self.dedent();
                try self.writeLine(")");
                try self.writeLine("(value");
                self.indent();
                try self.printExpr(ca.value);
                self.dedent();
                try self.writeLine(")");
                self.dedent();
                try self.writeLine(")");
            },
            .expression => |ex| {
                try self.writeLine("(expression_stmt");
                self.indent();
                try self.printExpr(ex.expr);
                self.dedent();
                try self.writeLine(")");
            },
            .return_stmt => |rs| {
                if (rs.value) |v| {
                    try self.writeLine("(return");
                    self.indent();
                    try self.printExpr(v);
                    self.dedent();
                    try self.writeLine(")");
                } else {
                    try self.writeLine("(return (none))");
                }
            },
            .defer_stmt => |ds| {
                try self.writeLine("(defer");
                self.indent();
                try self.printExpr(ds.expr);
                self.dedent();
                try self.writeLine(")");
            },
            .throw_stmt => |ts| {
                try self.writeLine("(throw");
                self.indent();
                try self.printExpr(ts.expr);
                self.dedent();
                try self.writeLine(")");
            },
            .break_stmt => try self.writeLine("(break)"),
            .continue_stmt => try self.writeLine("(continue)"),
            .for_stmt => |fs| {
                try self.writeFmt("(for \"{s}\"", .{fs.name});
                self.indent();
                try self.writeLine("(iterable");
                self.indent();
                try self.printExpr(fs.iterable);
                self.dedent();
                try self.writeLine(")");
                try self.writeLine("(body");
                self.indent();
                try self.printExpr(fs.body);
                self.dedent();
                try self.writeLine(")");
                self.dedent();
                try self.writeLine(")");
            },
            .while_stmt => |ws| {
                try self.writeLine("(while");
                self.indent();
                try self.writeLine("(cond");
                self.indent();
                try self.printExpr(ws.condition);
                self.dedent();
                try self.writeLine(")");
                try self.writeLine("(body");
                self.indent();
                try self.printExpr(ws.body);
                self.dedent();
                try self.writeLine(")");
                self.dedent();
                try self.writeLine(")");
            },
            .loop_stmt => |ls| {
                try self.writeLine("(loop");
                self.indent();
                try self.writeLine("(body");
                self.indent();
                try self.printExpr(ls.body);
                self.dedent();
                try self.writeLine(")");
                self.dedent();
                try self.writeLine(")");
            },
        }
    }

    // --- 模式 ---

    fn printPattern(self: *Printer, pat: *const ast.Pattern) anyerror!void {
        switch (pat.*) {
            .wildcard => try self.writeLine("(wildcard)"),
            .literal => |lit| {
                try self.writeLine("(pattern_literal");
                self.indent();
                try self.printPatternLiteral(lit);
                self.dedent();
                try self.writeLine(")");
            },
            .variable => |v| try self.writeFmt("(pattern_var \"{s}\")", .{v.name}),
            .constructor => |c| {
                try self.writeFmt("(pattern_constructor \"{s}\"", .{c.name});
                self.indent();
                if (c.patterns.len == 0) {
                    try self.writeLine("(patterns ())");
                } else {
                    try self.writeLine("(patterns");
                    self.indent();
                    for (c.patterns) |p| {
                        try self.printPattern(p);
                    }
                    self.dedent();
                    try self.writeLine(")");
                }
                self.dedent();
                try self.writeLine(")");
            },
            .record => |rec| {
                try self.writeLine("(pattern_record");
                self.indent();
                if (rec.fields.len == 0) {
                    try self.writeLine("(fields ())");
                } else {
                    try self.writeLine("(fields");
                    self.indent();
                    for (rec.fields) |f| {
                        try self.writeFmt("(field \"{s}\"", .{f.name});
                        self.indent();
                        try self.printPattern(f.pattern);
                        self.dedent();
                        try self.writeLine(")");
                    }
                    self.dedent();
                    try self.writeLine(")");
                }
                self.dedent();
                try self.writeLine(")");
            },
            .or_pattern => |op| {
                try self.writeLine("(or_pattern");
                self.indent();
                try self.writeLine("(left");
                self.indent();
                try self.printPattern(op.left);
                self.dedent();
                try self.writeLine(")");
                try self.writeLine("(right");
                self.indent();
                try self.printPattern(op.right);
                self.dedent();
                try self.writeLine(")");
                self.dedent();
                try self.writeLine(")");
            },
            .guard => |gd| {
                try self.writeLine("(guard_pattern");
                self.indent();
                try self.writeLine("(pattern");
                self.indent();
                try self.printPattern(gd.pattern);
                self.dedent();
                try self.writeLine(")");
                try self.writeLine("(condition");
                self.indent();
                try self.printExpr(gd.condition);
                self.dedent();
                try self.writeLine(")");
                self.dedent();
                try self.writeLine(")");
            },
        }
    }

    fn printPatternLiteral(self: *Printer, lit: ast.PatternLiteral) anyerror!void {
        switch (lit) {
            .int => |s| try self.writeFmt("(int \"{s}\")", .{s}),
            .float => |s| try self.writeFmt("(float \"{s}\")", .{s}),
            .bool => |b| try self.writeFmt("(bool {})", .{b}),
            .char => |c| try self.writeFmt("(char {})", .{c}),
            .string => |s| {
                const escaped = try escapeStr(self.allocator, s);
                defer self.allocator.free(escaped);
                try self.writeFmt("(string \"{s}\")", .{escaped});
            },
            .null => try self.writeLine("(null)"),
        }
    }

    // --- 运算符 ---

    fn printBinaryOp(self: *Printer, op: ast.BinaryOp) anyerror!void {
        try self.writeFmt("(op {s})", .{binaryOpStr(op)});
    }

    fn printUnaryOp(self: *Printer, op: ast.UnaryOp) anyerror!void {
        try self.writeFmt("(op {s})", .{unaryOpStr(op)});
    }

    fn printCompoundAssignOp(self: *Printer, op: ast.CompoundAssignOp) anyerror!void {
        try self.writeFmt("(op {s})", .{compoundAssignOpStr(op)});
    }

    // --- 列表辅助 ---

    fn printExprList(self: *Printer, label: []const u8, exprs: []const *ast.Expr) anyerror!void {
        if (exprs.len == 0) {
            try self.writeFmt("({s} ())", .{label});
            return;
        }
        try self.writeFmt("({s}", .{label});
        self.indent();
        for (exprs) |e| {
            try self.printExpr(e);
        }
        self.dedent();
        try self.writeLine(")");
    }

    fn printTypeArgsOpt(self: *Printer, type_args: ?[]*ast.TypeNode) anyerror!void {
        if (type_args) |args| {
            if (args.len > 0) {
                try self.writeLine("(type_args");
                self.indent();
                for (args) |arg| {
                    try self.printType(arg);
                }
                self.dedent();
                try self.writeLine(")");
                return;
            }
        }
        try self.writeLine("(type_args ())");
    }
};

// --- 运算符字符串映射 ---

fn binaryOpStr(op: ast.BinaryOp) []const u8 {
    return switch (op) {
        .add => "add",
        .sub => "sub",
        .mul => "mul",
        .div => "div",
        .mod => "mod",
        .eq => "eq",
        .not_eq => "neq",
        .ref_eq => "ref_eq",
        .ref_neq => "ref_neq",
        .lt => "lt",
        .gt => "gt",
        .lt_eq => "lt_eq",
        .gt_eq => "gt_eq",
        .and_op => "and",
        .or_op => "or",
        .bit_and => "bit_and",
        .bit_or => "bit_or",
        .bit_xor => "bit_xor",
        .shl => "shl",
        .shr => "shr",
        .concat_list => "concat_list",
        .range => "range",
        .range_inclusive => "range_inclusive",
        .elvis => "elvis",
    };
}

fn unaryOpStr(op: ast.UnaryOp) []const u8 {
    return switch (op) {
        .not => "not",
        .neg => "neg",
        .bit_not => "bit_not",
    };
}

fn compoundAssignOpStr(op: ast.CompoundAssignOp) []const u8 {
    return switch (op) {
        .add_assign => "add_assign",
        .sub_assign => "sub_assign",
        .mul_assign => "mul_assign",
        .div_assign => "div_assign",
        .mod_assign => "mod_assign",
        .bit_and_assign => "bit_and_assign",
        .bit_or_assign => "bit_or_assign",
        .bit_xor_assign => "bit_xor_assign",
        .shl_assign => "shl_assign",
        .shr_assign => "shr_assign",
    };
}

fn castModeStr(mode: ast.CastMode) []const u8 {
    return switch (mode) {
        .to => "to",
        .try_to => "try_to",
    };
}

/// 转义字符串中的特殊字符
fn escapeStr(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            else => {
                if (c < 0x20) {
                    var buf2: [32]u8 = undefined;
                    const esc = std.fmt.bufPrint(&buf2, "\\u{{{x}}}", .{c}) catch return error.FormatTooLong;
                    try out.appendSlice(allocator, esc);
                } else {
                    try out.append(allocator, c);
                }
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

// =====================================================
// CLI 入口
// =====================================================

pub fn main(init: std.process.Init) anyerror!void {
    const allocator = std.heap.c_allocator;
    const arena_alloc = init.arena.allocator();
    const io = init.io;

    const args_slice = try std.process.Args.toSlice(init.minimal.args, arena_alloc);
    if (args_slice.len < 2) {
        var buf: [256]u8 = undefined;
        var w = std.Io.File.stderr().writerStreaming(io, &buf);
        try w.interface.print("Usage: ast_printer <file.glue>\n", .{});
        try w.flush();
        return;
    }

    const cwd = std.Io.Dir.cwd();
    const source = cwd.readFileAlloc(io, args_slice[1], arena_alloc, .unlimited) catch |err| {
        var buf: [256]u8 = undefined;
        var w = std.Io.File.stderr().writerStreaming(io, &buf);
        try w.interface.print("Error reading {s}: {}\n", .{ args_slice[1], err });
        try w.flush();
        return;
    };

    // 词法分析
    var lx = lexer_mod.Lexer.init(arena_alloc, source);
    const tokens = try lx.tokenize();

    // 语法分析
    var parser = parser_mod.Parser.init(arena_alloc, tokens);
    const module = try parser.parseModule("stdin");

    // 打印 AST
    var printer = Printer.init(allocator);
    defer printer.deinit();
    try printer.printModule(&module);
    var out_buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &out_buf);
    try w.interface.writeAll(printer.buf.items);
    try w.flush();
}
