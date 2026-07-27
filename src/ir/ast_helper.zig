//! 测试用 AST 构造器：在 arena 中分配 NodeSlot 包装的 AST 节点
//!
//! 从 builder.zig 物理拆分，供 builder_tests.zig 及其他 IR 测试使用。

const std = @import("std");
const ast = @import("ast");

/// 测试用 AST 构造器：在 arena 中分配 NodeSlot 包装的 AST 节点
pub const AstHelper = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) AstHelper {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *AstHelper) void {
        self.arena.deinit();
    }

    pub fn alloc(self: *AstHelper) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub const loc: ast.SourceLocation = .{ .line = 1, .column = 1 };

    pub fn expr(self: *AstHelper, e: ast.Expr) *ast.Expr {
        const slot = self.alloc().create(ast.NodeSlot(ast.Expr)) catch unreachable;
        slot.* = .{ .loc = loc, .node = e };
        return &slot.node;
    }

    pub fn stmt(self: *AstHelper, s: ast.Stmt) *ast.Stmt {
        const slot = self.alloc().create(ast.NodeSlot(ast.Stmt)) catch unreachable;
        slot.* = .{ .loc = loc, .node = s };
        return &slot.node;
    }

    pub fn typeNode(self: *AstHelper, t: ast.TypeNode) *ast.TypeNode {
        const slot = self.alloc().create(ast.NodeSlot(ast.TypeNode)) catch unreachable;
        slot.* = .{ .loc = loc, .node = t };
        return &slot.node;
    }

    // 快捷构造：整数字面量
    pub fn intLit(self: *AstHelper, raw: []const u8) *ast.Expr {
        return self.expr(.{ .int_literal = .{ .raw = raw, .suffix = null } });
    }

    pub fn intLitSuf(self: *AstHelper, raw: []const u8, suffix: []const u8) *ast.Expr {
        return self.expr(.{ .int_literal = .{ .raw = raw, .suffix = suffix } });
    }

    // 快捷构造：浮点字面量
    pub fn floatLit(self: *AstHelper, raw: []const u8) *ast.Expr {
        return self.expr(.{ .float_literal = .{ .raw = raw, .suffix = null } });
    }

    pub fn floatLitSuf(self: *AstHelper, raw: []const u8, suffix: []const u8) *ast.Expr {
        return self.expr(.{ .float_literal = .{ .raw = raw, .suffix = suffix } });
    }

    // 快捷构造：布尔字面量
    pub fn boolLit(self: *AstHelper, v: bool) *ast.Expr {
        return self.expr(.{ .bool_literal = .{ .value = v } });
    }

    // 快捷构造：标识符引用
    pub fn ident(self: *AstHelper, name: []const u8) *ast.Expr {
        return self.expr(.{ .identifier = .{ .name = name } });
    }

    // 快捷构造：二元运算
    pub fn binary(self: *AstHelper, op: ast.BinaryOp, left: *ast.Expr, right: *ast.Expr) *ast.Expr {
        return self.expr(.{ .binary = .{ .op = op, .left = left, .right = right } });
    }

    // 快捷构造：一元运算
    pub fn unary(self: *AstHelper, op: ast.UnaryOp, operand: *ast.Expr) *ast.Expr {
        return self.expr(.{ .unary = .{ .op = op, .operand = operand } });
    }

    // 快捷构造：if 表达式
    pub fn ifExpr(
        self: *AstHelper,
        cond: *ast.Expr,
        then_b: *ast.Expr,
        else_b: ?*ast.Expr,
    ) *ast.Expr {
        return self.expr(.{ .if_expr = .{
            .condition = cond,
            .then_branch = then_b,
            .else_branch = else_b,
        } });
    }

    // 快捷构造：函数调用
    pub fn call(self: *AstHelper, func_name: []const u8, args: []const *ast.Expr) *ast.Expr {
        const args_slice = self.alloc().dupe(*ast.Expr, args) catch unreachable;
        return self.expr(.{ .call = .{
            .callee = self.ident(func_name),
            .arguments = args_slice,
            .type_args = null,
        } });
    }

    // 快捷构造：method_call 表达式
    pub fn methodCall(self: *AstHelper, obj: *ast.Expr, method: []const u8, args: []const *ast.Expr) *ast.Expr {
        const args_slice = self.alloc().dupe(*ast.Expr, args) catch unreachable;
        return self.expr(.{ .method_call = .{
            .object = obj,
            .method = method,
            .arguments = args_slice,
            .type_args = null,
        } });
    }

    // 快捷构造：block 表达式
    pub fn block(self: *AstHelper, stmts: []const *ast.Stmt, trailing: ?*ast.Expr) *ast.Expr {
        const stmts_slice = self.alloc().alloc(*ast.Stmt, stmts.len) catch unreachable;
        for (stmts, 0..) |s, i| stmts_slice[i] = s;
        return self.expr(.{ .block = .{
            .statements = stmts_slice,
            .trailing_expr = trailing,
        } });
    }

    // 快捷构造：val 声明语句
    pub fn valDecl(self: *AstHelper, name: []const u8, value: *ast.Expr) *ast.Stmt {
        return self.stmt(.{ .val_decl = .{
            .name = name,
            .type_annotation = null,
            .value = value,
        } });
    }

    // 快捷构造：var 声明语句
    pub fn varDecl(self: *AstHelper, name: []const u8, value: *ast.Expr) *ast.Stmt {
        return self.stmt(.{ .var_decl = .{
            .name = name,
            .type_annotation = null,
            .value = value,
        } });
    }

    // 快捷构造：赋值语句
    pub fn assignment(self: *AstHelper, target_name: []const u8, value: *ast.Expr) *ast.Stmt {
        return self.stmt(.{ .assignment = .{
            .target = self.ident(target_name),
            .value = value,
        } });
    }

    // 快捷构造：return 语句
    pub fn returnStmt(self: *AstHelper, value: ?*ast.Expr) *ast.Stmt {
        return self.stmt(.{ .return_stmt = .{ .value = value } });
    }

    // 快捷构造：表达式语句
    pub fn exprStmt(self: *AstHelper, e: *ast.Expr) *ast.Stmt {
        return self.stmt(.{ .expression = .{ .expr = e } });
    }

    // 快捷构造：命名类型节点
    pub fn namedType(self: *AstHelper, name: []const u8) *ast.TypeNode {
        return self.typeNode(.{ .named = .{ .name = name } });
    }

    // 快捷构造：函数参数
    pub fn param(self: *AstHelper, name: []const u8, type_name: []const u8) ast.Param {
        return .{
            .location = loc,
            .name = name,
            .type_annotation = self.namedType(type_name),
        };
    }

    // 快捷构造：函数声明
    pub fn funDecl(
        self: *AstHelper,
        name: []const u8,
        params: []const ast.Param,
        return_type: ?*ast.TypeNode,
        body: *ast.Expr,
        is_entry: bool,
    ) ast.Decl {
        const params_slice = self.alloc().alloc(ast.Param, params.len) catch unreachable;
        for (params, 0..) |p, i| params_slice[i] = p;
        return .{ .fun_decl = .{
            .location = loc,
            .visibility = .private,
            .name = name,
            .type_params = &.{},
            .params = params_slice,
            .return_type = return_type,
            .bounds = &.{},
            .body = body,
            .is_async = false,
            .is_entry = is_entry,
        } };
    }

    /// async 函数声明
    pub fn asyncFunDecl(
        self: *AstHelper,
        name: []const u8,
        params: []const ast.Param,
        return_type: ?*ast.TypeNode,
        body: *ast.Expr,
    ) ast.Decl {
        const params_slice = self.alloc().alloc(ast.Param, params.len) catch unreachable;
        for (params, 0..) |p, i| params_slice[i] = p;
        return .{ .fun_decl = .{
            .location = loc,
            .visibility = .private,
            .name = name,
            .type_params = &.{},
            .params = params_slice,
            .return_type = return_type,
            .bounds = &.{},
            .body = body,
            .is_async = true,
            .is_entry = false,
        } };
    }

    // 快捷构造：模块
    pub fn module(self: *AstHelper, name: []const u8, decls: []const ast.Decl) ast.Module {
        const decls_slice = self.alloc().dupe(ast.Decl, decls) catch unreachable;
        return .{ .name = name, .source_path = null, .declarations = decls_slice };
    }
};
