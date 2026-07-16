//! 递归下降语法分析器（Parser）
//!
//! 将词法分析器产生的 Token 序列解析为抽象语法树（AST）。
//! 采用递归下降 + 优先级爬升方式处理表达式，支持函数/类型/trait/import 等声明、
//! 模式匹配、lambda、控制流语句、字符串插值等语言特性。
//! AST 节点通过 arena 分配器统一分配，分析失败时收集错误并尝试同步恢复。

const std = @import("std");
const lexer = @import("lexer");
const ast = @import("ast");

/// 语法错误信息：行列号与消息
pub const ParseError = struct {
    line: u32,
    column: u32,
    message: []const u8,
};

const ParserError = error{ OutOfMemory, UnexpectedToken };

/// AST 节点 chunk 批量分配器：以 64 项为单位从 arena 批量申请 NodeSlot(T)，
/// 消除逐节点 vtable 开销并将 SourceLocation 存储在 node 外部。
/// 所有内存归属 arena，无需单独释放。
fn NodeChunk(comptime T: type) type {
    return struct {
        const Slot = ast.NodeSlot(T);
        const CHUNK_SIZE = 64;
        const Self = @This();

        current: []Slot = &.{},
        idx: usize = 0,

        fn alloc(self: *Self, arena: std.mem.Allocator) !*Slot {
            if (self.idx >= self.current.len) {
                self.current = try arena.alloc(Slot, CHUNK_SIZE);
                self.idx = 0;
            }
            const slot = &self.current[self.idx];
            self.idx += 1;
            return slot;
        }
    };
}

/// 语法分析器：持有 Token 序列、当前位置、arena 与错误列表
pub const Parser = struct {
    tokens: []const lexer.Token,
    current: usize,
    arena: std.heap.ArenaAllocator,
    errors: std.ArrayList(ParseError),
    /// expectCloseAngle 遇到 gt_eq 时虚拟拆分：当前已消费 gt 部分，待注入 eq
    pending_eq: bool,
    /// 节点批量分配器，减少逐节点 arena vtable 调用
    expr_chunk: NodeChunk(ast.Expr) = .{},
    stmt_chunk: NodeChunk(ast.Stmt) = .{},
    type_chunk: NodeChunk(ast.TypeNode) = .{},
    pattern_chunk: NodeChunk(ast.Pattern) = .{},
    kind_chunk: NodeChunk(ast.Kind) = .{},

    /// 创建分析器，直接引用外部 Token 切片（零拷贝）
    pub fn init(backing: std.mem.Allocator, tokens: []const lexer.Token) Parser {
        return Parser{
            .tokens = tokens,
            .current = 0,
            .arena = std.heap.ArenaAllocator.init(backing),
            .errors = .empty,
            .pending_eq = false,
        };
    }

    /// 释放分析器资源
    pub fn deinit(self: *Parser) void {
        self.errors.deinit(self.arena.allocator());
        self.arena.deinit();
    }

    /// 获取 arena 的分配器接口
    pub fn allocator(self: *Parser) std.mem.Allocator {
        return self.arena.allocator();
    }

    // ---- Token 导航辅助 ----

    /// 查看当前 Token，越界时返回最后一个（eof）。处理 pending_eq 虚拟注入。
    fn peek(self: *Parser) lexer.Token {
        if (self.pending_eq) {
            // 构造虚拟 eq token，位置基于被拆分的 gt_eq 的下一列
            const base = if (self.current > 0) self.tokens[self.current - 1] else self.tokens[0];
            return lexer.Token{
                .type = .eq,
                .lexeme = "=",
                .line = base.line,
                .column = base.column + 1,
            };
        }
        if (self.current >= self.tokens.len) {
            return self.tokens[self.tokens.len - 1];
        }
        return self.tokens[self.current];
    }

    /// 返回上一个已消费的 Token
    fn previous(self: *Parser) lexer.Token {
        std.debug.assert(self.current > 0);
        return self.tokens[self.current - 1];
    }

    /// 是否到达 Token 序列末尾
    pub fn isAtEnd(self: *Parser) bool {
        return self.peek().type == .eof;
    }

    /// 消费当前 Token 并前进，到达末尾时不前进。处理 pending_eq 虚拟消费。
    fn advance(self: *Parser) lexer.Token {
        if (self.pending_eq) {
            self.pending_eq = false;
            // 返回虚拟 eq token
            const base = if (self.current > 0) self.tokens[self.current - 1] else self.tokens[0];
            return lexer.Token{
                .type = .eq,
                .lexeme = "=",
                .line = base.line,
                .column = base.column + 1,
            };
        }
        if (!self.isAtEnd()) {
            self.current += 1;
        }
        return self.previous();
    }

    /// 当前 Token 是否为指定类型
    fn check(self: *Parser, token_type: lexer.TokenType) bool {
        if (self.isAtEnd()) return false;
        return self.peek().type == token_type;
    }

    /// 当当前 Token 匹配时消费并返回 true
    fn matchToken(self: *Parser, token_type: lexer.TokenType) bool {
        if (self.check(token_type)) {
            _ = self.advance();
            return true;
        }
        return false;
    }

    /// 期望消费指定类型 Token，不匹配时记录错误并返回 UnexpectedToken
    fn expect(self: *Parser, token_type: lexer.TokenType, message: []const u8) ParserError!lexer.Token {
        if (self.check(token_type)) {
            return self.advance();
        }
        const tok = self.peek();
        try self.errors.append(self.arena.allocator(), ParseError{
            .line = tok.line,
            .column = tok.column,
            .message = message,
        });
        return error.UnexpectedToken;
    }

    /// 期望消费关闭泛型参数的 '>'，支持把 `>=` 拆分为 `>` 与 `=` 以消除歧义
    fn expectCloseAngle(self: *Parser, message: []const u8) ParserError!void {
        if (self.check(.gt)) {
            _ = self.advance();
            return;
        }
        if (self.current < self.tokens.len and self.tokens[self.current].type == .gt_eq) {
            // 虚拟拆分 gt_eq：消费整个 token，设置 pending_eq 供下一次 peek 注入 eq
            self.current += 1;
            self.pending_eq = true;
            return;
        }
        const tok = self.peek();
        try self.errors.append(self.arena.allocator(), ParseError{
            .line = tok.line,
            .column = tok.column,
            .message = message,
        });
        return error.UnexpectedToken;
    }

    /// 在当前 Token 处记录一条语法错误
    fn reportError(self: *Parser, message: []const u8) ParserError!void {
        const tok = self.peek();
        try self.errors.append(self.arena.allocator(), ParseError{
            .line = tok.line,
            .column = tok.column,
            .message = message,
        });
    }

    /// 条件语句禁止使用括号：if/while/for/match 的条件部分不允许以 '(' 开头
    fn rejectParenCondition(self: *Parser, kw_name: []const u8) ParserError!void {
        if (self.check(.l_paren)) {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{s} 条件不允许使用括号", .{kw_name}) catch "条件不允许使用括号";
            try self.reportError(msg);
            return error.UnexpectedToken;
        }
    }

    /// 错误恢复：跳过 Token 直到遇到下一个声明起始或右大括号
    fn synchronize(self: *Parser) void {
        while (!self.isAtEnd()) {
            switch (self.peek().type) {
                .kw_fun,
                .kw_type,
                .kw_trait,
                .kw_import,
                .kw_pack,
                .kw_pub,
                .kw_val,
                .kw_var,
                => return,
                .r_brace,
                => {
                    _ = self.advance();
                    return;
                },
                else => {
                    _ = self.advance();
                },
            }
        }
    }

    /// 当前 Token 是否为指定名称的标识符
    fn checkIdentifier(self: *Parser, name: []const u8) bool {
        if (self.peek().type != .identifier) return false;
        return std.mem.eql(u8, self.peek().lexeme, name);
    }

    // ---- AST 节点分配辅助 ----

    fn allocExpr(self: *Parser, loc: ast.SourceLocation, expr: ast.Expr) ParserError!*ast.Expr {
        const slot = try self.expr_chunk.alloc(self.arena.allocator());
        slot.* = .{ .loc = loc, .node = expr };
        return &slot.node;
    }

    fn allocStmt(self: *Parser, loc: ast.SourceLocation, stmt: ast.Stmt) ParserError!*ast.Stmt {
        const slot = try self.stmt_chunk.alloc(self.arena.allocator());
        slot.* = .{ .loc = loc, .node = stmt };
        return &slot.node;
    }

    fn allocType(self: *Parser, loc: ast.SourceLocation, ty: ast.TypeNode) ParserError!*ast.TypeNode {
        const slot = try self.type_chunk.alloc(self.arena.allocator());
        slot.* = .{ .loc = loc, .node = ty };
        return &slot.node;
    }

    fn allocPattern(self: *Parser, loc: ast.SourceLocation, pat: ast.Pattern) ParserError!*ast.Pattern {
        const slot = try self.pattern_chunk.alloc(self.arena.allocator());
        slot.* = .{ .loc = loc, .node = pat };
        return &slot.node;
    }

    fn allocKind(self: *Parser, loc: ast.SourceLocation, kind: ast.Kind) ParserError!*ast.Kind {
        const slot = try self.kind_chunk.alloc(self.arena.allocator());
        slot.* = .{ .loc = loc, .node = kind };
        return &slot.node;
    }

    // ---- 模块与顶层声明 ----

    /// 解析整个模块：循环解析声明或顶层表达式，收集错误后返回 Module
    pub fn parseModule(self: *Parser, module_name: []const u8) ParserError!ast.Module {
        var declarations = std.ArrayList(ast.Decl).empty;
        try declarations.ensureTotalCapacity(self.arena.allocator(), 16);
        errdefer declarations.deinit(self.arena.allocator());
        while (!self.isAtEnd()) {
            const at_decl_kw = self.check(.kw_fun) or self.check(.kw_type) or
                self.check(.kw_trait) or
                self.check(.kw_import) or self.check(.kw_pack) or self.check(.kw_pub);
            if (self.tryParseDecl()) |decl| {
                try declarations.append(self.arena.allocator(), decl);
                continue;
            }
            if (at_decl_kw) {
                self.synchronize();
                continue;
            }
            const before_expr = self.current;
            const expr = self.parseExpr() catch {
                self.synchronize();
                continue;
            };
            if (self.current == before_expr) {
                _ = self.advance();
                continue;
            }
            if (self.matchToken(.eq)) {
                const value = self.parseExpr() catch |err| {
                    if (err == error.UnexpectedToken) {
                        self.synchronize();
                        continue;
                    }
                    return err;
                };
                const stmt = try self.allocStmt(getExprLocation(expr), ast.Stmt{
                    .assignment = .{
                        .target = expr,
                        .value = value,
                    },
                });
                try declarations.append(self.arena.allocator(), ast.Decl{
                    .expr_decl = .{
                        .location = getExprLocation(expr),
                        .expr = expr,
                        .stmt = stmt,
                    },
                });
            } else {
                try declarations.append(self.arena.allocator(), ast.Decl{
                    .expr_decl = .{
                        .location = getExprLocation(expr),
                        .expr = expr,
                    },
                });
            }
        }
        if (self.errors.items.len > 0) {
            return error.UnexpectedToken;
        }
        return ast.Module{
            .name = module_name,
            .source_path = null,
            .declarations = try declarations.toOwnedSlice(self.arena.allocator()),
        };
    }

    /// 尝试解析顶层声明（容错版本，失败返回 null 而不抛出）
    fn tryParseDecl(self: *Parser) ?ast.Decl {
        var visibility: ast.Visibility = .private;
        if (self.matchToken(.kw_pub)) {
            visibility = .public;
        }
        var is_async = false;
        if (self.matchToken(.kw_async)) {
            if (!self.check(.kw_fun)) return null;
            is_async = true;
        }
        if (self.check(.kw_fun)) {
            return self.parseFunDecl(visibility, is_async) catch return null;
        }
        if (self.check(.kw_type)) {
            return self.parseTypeDecl(visibility) catch return null;
        }
        if (self.check(.kw_trait)) {
            return self.parseTraitDecl(visibility) catch return null;
        }
        if (self.check(.kw_import)) {
            return self.parseUseDecl(visibility) catch return null;
        }
        if (self.check(.kw_pack)) {
            return self.parsePackDecl(visibility) catch return null;
        }
        if (visibility == .public and (self.check(.kw_val) or self.check(.kw_var))) {
            const stmt = self.parseStmt() catch return null;
            switch (stmt.*) {
                .val_decl => |*vd| vd.visibility = visibility,
                .var_decl => |*vd| vd.visibility = visibility,
                else => {},
            }
            const dummy = self.allocExpr(stmt.getLocation(), ast.Expr{
                .unit_literal = {},
            }) catch return null;
            return ast.Decl{
                .expr_decl = .{
                    .location = stmt.getLocation(),
                    .expr = dummy,
                    .stmt = stmt,
                },
            };
        }
        if (visibility == .public) {
            self.current -= 1;
        }
        if (self.check(.kw_val) or self.check(.kw_var) or
            self.check(.kw_for) or self.check(.kw_while) or
            self.check(.kw_loop) or self.check(.kw_defer) or
            self.check(.kw_throw) or self.check(.kw_return))
        {
            const stmt = self.parseStmt() catch return null;
            const dummy = self.allocExpr(stmt.getLocation(), ast.Expr{
                .unit_literal = {},
            }) catch return null;
            return ast.Decl{
                .expr_decl = .{
                    .location = stmt.getLocation(),
                    .expr = dummy,
                    .stmt = stmt,
                },
            };
        }
        return null;
    }

    /// 解析单个顶层声明（严格版本，失败时抛出错误）
    pub fn parseDecl(self: *Parser) ParserError!ast.Decl {
        var visibility: ast.Visibility = .private;
        if (self.matchToken(.kw_pub)) {
            visibility = .public;
        }
        var is_async = false;
        if (self.matchToken(.kw_async)) {
            if (!self.check(.kw_fun)) {
                try self.reportError("expected 'fun' after 'async'");
                return error.UnexpectedToken;
            }
            is_async = true;
        }
        if (self.check(.kw_fun)) {
            return self.parseFunDecl(visibility, is_async);
        }
        if (self.check(.kw_type)) {
            return self.parseTypeDecl(visibility);
        }
        if (self.check(.kw_trait)) {
            return self.parseTraitDecl(visibility);
        }
        if (self.check(.kw_import)) {
            return self.parseUseDecl(visibility);
        }
        if (self.check(.kw_pack)) {
            return self.parsePackDecl(visibility);
        }
        if (visibility == .public and (self.check(.kw_val) or self.check(.kw_var))) {
            const stmt = try self.parseStmt();
            switch (stmt.*) {
                .val_decl => |*vd| vd.visibility = visibility,
                .var_decl => |*vd| vd.visibility = visibility,
                else => {},
            }
            const dummy = try self.allocExpr(stmt.getLocation(), ast.Expr{
                .unit_literal = {},
            });
            return ast.Decl{
                .expr_decl = .{
                    .location = stmt.getLocation(),
                    .expr = dummy,
                    .stmt = stmt,
                },
            };
        }
        try self.reportError("expected top-level declaration (fun/type/trait/use/pack/val/var)");
        return error.UnexpectedToken;
    }

    /// 解析函数声明：fun name<类型参数>(参数): 返回类型 with 约束 { body }
    fn parseFunDecl(self: *Parser, visibility: ast.Visibility, is_async: bool) ParserError!ast.Decl {
        const fun_tok = self.advance();
        const name_tok = try self.expect(.identifier, "expected function name");
        var type_params = std.ArrayList(ast.TypeParam).empty;
        if (self.matchToken(.lt)) {
            try self.parseTypeParamList(&type_params);
            self.expectCloseAngle("expected '>' to close type parameter list") catch {};
        }
        var params = std.ArrayList(ast.Param).empty;
        _ = self.expect(.l_paren, "expected '(' to start parameter list") catch {};
        if (!self.check(.r_paren)) {
            try self.parseParamList(&params);
        }
        _ = self.expect(.r_paren, "expected ')' to close parameter list") catch {};
        var return_type: ?*ast.TypeNode = null;
        if (self.matchToken(.colon)) {
            return_type = self.parseType() catch |err| {
                return err;
            };
        }
        var bounds = std.ArrayList(ast.TraitBound).empty;
        if (self.matchToken(.kw_with)) {
            try self.parseTraitBoundList(&bounds);
        }
        const body = self.parseExpr() catch |err| {
            return err;
        };
        return ast.Decl{
            .fun_decl = .{
                .location = tokenLoc(fun_tok),
                .visibility = visibility,
                .name = name_tok.lexeme,
                .type_params = try type_params.toOwnedSlice(self.arena.allocator()),
                .params = try params.toOwnedSlice(self.arena.allocator()),
                .return_type = return_type,
                .bounds = try bounds.toOwnedSlice(self.arena.allocator()),
                .body = body,
                .is_async = is_async,
                .is_entry = std.mem.eql(u8, name_tok.lexeme, "main"),
            },
        };
    }

    /// 解析类型声明：type Name<类型参数> : traits = 定义 with 约束 { 方法 }
    fn parseTypeDecl(self: *Parser, visibility: ast.Visibility) ParserError!ast.Decl {
        const type_tok = self.advance();
        const name_tok = try self.expect(.identifier, "expected type name");
        var type_params = std.ArrayList(ast.TypeParam).empty;
        if (self.matchToken(.lt)) {
            try self.parseTypeParamList(&type_params);
            self.expectCloseAngle("expected '>' to close type parameter list") catch {};
        }
        var implemented_traits = std.ArrayList(ast.TraitBound).empty;
        var has_error_trait = false;
        if (self.matchToken(.colon)) {
            const has_paren = self.check(.l_paren);
            if (has_paren) {
                _ = self.advance();
            }
            try self.parseTraitBoundList(&implemented_traits);
            if (has_paren) {
                _ = self.expect(.r_paren, "expected ')' after trait list") catch {};
            }
            for (implemented_traits.items) |trait_bound| {
                if (std.mem.eql(u8, trait_bound.trait_name, "Error")) {
                    has_error_trait = true;
                    break;
                }
            }
        }
        _ = self.expect(.eq, "expected '=' to define type body") catch {};
        var def = try self.parseTypeDef(has_error_trait);
        if (def == .error_newtype) {
            def.error_newtype.name = name_tok.lexeme;
        }
        var type_constraints = std.ArrayList(ast.TypeConstraint).empty;
        if (self.matchToken(.kw_with)) {
            try self.parseTypeConstraints(&type_constraints);
        }
        var methods = std.ArrayList(ast.MethodDecl).empty;
        if (self.matchToken(.l_brace)) {
            try self.parseMethodBlock(&methods);
            _ = self.expect(.r_brace, "expected '}' to close method block") catch {};
        }
        return ast.Decl{
            .type_decl = .{
                .location = tokenLoc(type_tok),
                .visibility = visibility,
                .name = name_tok.lexeme,
                .type_params = try type_params.toOwnedSlice(self.arena.allocator()),
                .implemented_traits = try implemented_traits.toOwnedSlice(self.arena.allocator()),
                .type_constraints = try type_constraints.toOwnedSlice(self.arena.allocator()),
                .def = def,
                .methods = try methods.toOwnedSlice(self.arena.allocator()),
            },
        };
    }

    /// 解析类型定义体：ADT、记录、别名、新类型、错误新类型
    fn parseTypeDef(self: *Parser, has_error_trait: bool) ParserError!ast.TypeDef {
        if (self.matchToken(.pipe)) {
            return self.parseAdtBody();
        }
        if (self.check(.l_paren)) {
            const saved = self.current;
            if (self.tryParseRecordTypeDef()) |def| {
                return def;
            }
            self.current = saved;
        }
        if (self.check(.identifier)) {
            const saved = self.current;
            const name_tok = self.advance();
            if (self.check(.l_paren)) {
                _ = self.advance();
                var params = std.ArrayList(ast.Param).empty;
                if (!self.check(.r_paren)) {
                    const saved2 = self.current;
                    if (self.check(.identifier)) {
                        _ = self.advance();
                        if (self.check(.colon)) {
                            self.current = saved2;
                            try self.parseParamList(&params);
                            _ = self.expect(.r_paren, "expected ')'") catch {
                                self.current = saved;
                                const target = try self.parseType();
                                return ast.TypeDef{ .alias = .{ .target = target } };
                            };
                            if (has_error_trait) {
                                return ast.TypeDef{
                                    .error_newtype = .{
                                        .name = name_tok.lexeme,
                                        .params = try params.toOwnedSlice(self.arena.allocator()),
                                    },
                                };
                            }
                            self.current = saved;
                            if (self.tryParseSingleCtorAdt()) |def| {
                                return def;
                            }
                            self.current = saved;
                        }
                        self.current = saved2;
                    }
                    self.current = saved;
                    if (self.tryParseSingleCtorAdt()) |def| {
                        return def;
                    }
                    self.current = saved;
                } else {
                }
            }
            self.current = saved;
        }
        const target = try self.parseType();
        if (self.check(.pipe)) {
            try self.reportError("each variant of a sum type must be prefixed with '|', including the first; for example `type Color = | Red | Green`");
            return ParserError.UnexpectedToken;
        }
        return ast.TypeDef{ .alias = .{ .target = target } };
    }

    /// 尝试解析单构造器 ADT（形如 Name(field1, field2)）
    fn tryParseSingleCtorAdt(self: *Parser) ?ast.TypeDef {
        const name_tok = self.advance();
        if (!self.check(.l_paren)) return null;
        _ = self.advance();
        if (self.check(.r_paren)) {
            _ = self.advance();
            const ctors = self.arena.allocator().alloc(ast.ConstructorDef, 1) catch return null;
            ctors[0] = .{
                .location = tokenLoc(name_tok),
                .name = name_tok.lexeme,
                .fields = &[_]ast.ConstructorField{},
                .return_type = null,
            };
            return ast.TypeDef{
                .adt = .{ .constructors = ctors },
            };
        }
        if (self.check(.identifier) and self.current + 1 < self.tokens.len and self.tokens[self.current + 1].type == .colon) {
            var fields = std.ArrayList(ast.ConstructorField).empty;
            self.parseConstructorFieldList(&fields) catch {
                fields.deinit(self.arena.allocator());
                return null;
            };
            _ = self.expect(.r_paren, "expected ')' to close constructor fields") catch {
                fields.deinit(self.arena.allocator());
                return null;
            };
            const ctors = self.arena.allocator().alloc(ast.ConstructorDef, 1) catch return null;
            ctors[0] = .{
                .location = tokenLoc(name_tok),
                .name = name_tok.lexeme,
                .fields = fields.toOwnedSlice(self.arena.allocator()) catch return null,
                .return_type = null,
            };
            return ast.TypeDef{
                .adt = .{ .constructors = ctors },
            };
        }
        const first_type = self.parseType() catch return null;
        if (self.check(.comma)) {
            var fields = std.ArrayList(ast.ConstructorField).empty;
            fields.append(self.arena.allocator(), .{
                .name = null,
                .ty = first_type,
            }) catch return null;
            while (self.matchToken(.comma)) {
                const ty = self.parseType() catch {
                    fields.deinit(self.arena.allocator());
                    return null;
                };
                fields.append(self.arena.allocator(), .{
                    .name = null,
                    .ty = ty,
                }) catch {
                    fields.deinit(self.arena.allocator());
                    return null;
                };
            }
            _ = self.expect(.r_paren, "expected ')' to close constructor fields") catch {
                fields.deinit(self.arena.allocator());
                return null;
            };
            const ctors = self.arena.allocator().alloc(ast.ConstructorDef, 1) catch return null;
            ctors[0] = .{
                .location = tokenLoc(name_tok),
                .name = name_tok.lexeme,
                .fields = fields.toOwnedSlice(self.arena.allocator()) catch return null,
                .return_type = null,
            };
            return ast.TypeDef{
                .adt = .{ .constructors = ctors },
            };
        }
        _ = self.expect(.r_paren, "expected ')'") catch return null;
        return ast.TypeDef{ .newtype = .{
            .name = name_tok.lexeme,
            .inner = first_type,
        } };
    }

    /// 尝试解析记录类型定义（形如 (field: Type, ...)）
    fn tryParseRecordTypeDef(self: *Parser) ?ast.TypeDef {
        _ = self.advance();
        if (self.peek().type == .identifier) {
            const name = self.advance();
            if (self.check(.colon)) {
                _ = self.advance();
                const ty = self.parseType() catch return null;
                var fields = std.ArrayList(ast.RecordFieldType).empty;
                fields.append(self.arena.allocator(), .{
                    .name = name.lexeme,
                    .ty = ty,
                }) catch return null;
                while (self.matchToken(.comma)) {
                    if (self.check(.r_paren)) break;
                    const field_name = self.expect(.identifier, "expected field name") catch return null;
                    _ = self.expect(.colon, "expected ':'") catch return null;
                    const field_ty = self.parseType() catch return null;
                    fields.append(self.arena.allocator(), .{
                        .name = field_name.lexeme,
                        .ty = field_ty,
                    }) catch return null;
                }
                _ = self.expect(.r_paren, "expected ')'") catch return null;
                return ast.TypeDef{
                    .record = .{ .fields = fields.toOwnedSlice(self.arena.allocator()) catch return null },
                };
            } else {
                return null;
            }
        }
        return null;
    }

    /// 解析 ADT 构造器列表（以 | 分隔）
    fn parseAdtBody(self: *Parser) ParserError!ast.TypeDef {
        var constructors = std.ArrayList(ast.ConstructorDef).empty;
        try constructors.append(self.arena.allocator(), try self.parseConstructorDef());
        while (self.matchToken(.pipe)) {
            try constructors.append(self.arena.allocator(), try self.parseConstructorDef());
        }
        return ast.TypeDef{
            .adt = .{ .constructors = try constructors.toOwnedSlice(self.arena.allocator()) },
        };
    }

    /// 解析单个构造器定义：Name(字段列表): 返回类型
    fn parseConstructorDef(self: *Parser) ParserError!ast.ConstructorDef {
        const name_tok = try self.expect(.identifier, "expected constructor name");
        var fields = std.ArrayList(ast.ConstructorField).empty;
        if (self.matchToken(.l_paren)) {
            if (!self.check(.r_paren)) {
                try self.parseConstructorFieldList(&fields);
            }
            _ = self.expect(.r_paren, "expected ')' to close constructor fields") catch {};
        }
        var return_type: ?*ast.TypeNode = null;
        if (self.matchToken(.colon)) {
            return_type = try self.parseType();
        }
        return ast.ConstructorDef{
            .location = tokenLoc(name_tok),
            .name = name_tok.lexeme,
            .fields = try fields.toOwnedSlice(self.arena.allocator()),
            .return_type = return_type,
        };
    }

    /// 解析构造器字段列表（逗号分隔）
    fn parseConstructorFieldList(self: *Parser, fields: *std.ArrayList(ast.ConstructorField)) ParserError!void {
        try fields.append(self.arena.allocator(), try self.parseConstructorField());
        while (self.matchToken(.comma)) {
            try fields.append(self.arena.allocator(), try self.parseConstructorField());
        }
    }

    /// 解析单个构造器字段：可带名称（name: Type）或仅为类型
    fn parseConstructorField(self: *Parser) ParserError!ast.ConstructorField {
        if (self.peek().type == .identifier) {
            const saved = self.current;
            const name = self.advance();
            if (self.matchToken(.colon)) {
                const ty = try self.parseType();
                return ast.ConstructorField{
                    .name = name.lexeme,
                    .ty = ty,
                };
            }
            self.current = saved;
        }
        const ty = try self.parseType();
        return ast.ConstructorField{
            .name = null,
            .ty = ty,
        };
    }

    /// 解析 trait 声明：trait Name<类型参数>(父 trait) { 关联类型 / 方法 }
    fn parseTraitDecl(self: *Parser, visibility: ast.Visibility) ParserError!ast.Decl {
        const trait_tok = self.advance();
        const name_tok = try self.expect(.identifier, "expected trait name");
        var type_params = std.ArrayList(ast.TypeParam).empty;
        if (self.matchToken(.lt)) {
            try self.parseTypeParamList(&type_params);
            self.expectCloseAngle("expected '>' to close type parameter list") catch {};
        }
        var parents = std.ArrayList(ast.TraitBound).empty;
        if (self.matchToken(.l_paren)) {
            if (!self.check(.r_paren)) {
                try self.parseTraitBoundListInner(&parents);
            }
            _ = self.expect(.r_paren, "expected ')' to close parent trait list") catch {};
        }
        var associated_types = std.ArrayList(ast.AssociatedType).empty;
        var methods = std.ArrayList(ast.MethodDecl).empty;
        _ = self.expect(.l_brace, "expected '{' to start trait body") catch {};
        while (!self.check(.r_brace) and !self.isAtEnd()) {
            if (self.check(.kw_type)) {
                try associated_types.append(self.arena.allocator(), try self.parseAssociatedType());
            } else {
                try methods.append(self.arena.allocator(), try self.parseMethodDecl());
            }
        }
        _ = self.expect(.r_brace, "expected '}' to close trait body") catch {};
        return ast.Decl{
            .trait_decl = .{
                .location = tokenLoc(trait_tok),
                .visibility = visibility,
                .name = name_tok.lexeme,
                .type_params = try type_params.toOwnedSlice(self.arena.allocator()),
                .parents = try parents.toOwnedSlice(self.arena.allocator()),
                .associated_types = try associated_types.toOwnedSlice(self.arena.allocator()),
                .methods = try methods.toOwnedSlice(self.arena.allocator()),
            },
        };
    }

    /// 解析关联类型声明：type Name: kind
    fn parseAssociatedType(self: *Parser) ParserError!ast.AssociatedType {
        const type_tok = self.advance();
        const name_tok = try self.expect(.identifier, "expected associated type name");
        var kind: ?*ast.Kind = null;
        if (self.matchToken(.colon)) {
            kind = try self.parseKind();
        }
        return ast.AssociatedType{
            .location = tokenLoc(type_tok),
            .name = name_tok.lexeme,
            .kind = kind,
        };
    }

    /// 解析方法声明：[pub] [override] fun name<类型参数>(参数): 返回类型 { body } 或 = Trait.method
    fn parseMethodDecl(self: *Parser) ParserError!ast.MethodDecl {
        var visibility: ast.Visibility = .private;
        if (self.matchToken(.kw_pub)) {
            visibility = .public;
        }
        var is_override = false;
        if (self.matchToken(.kw_override)) {
            is_override = true;
        }
        _ = self.expect(.kw_fun, "expected 'fun'") catch {};
        const name_tok = try self.expect(.identifier, "expected method name");
        var type_params = std.ArrayList(ast.TypeParam).empty;
        if (self.matchToken(.lt)) {
            try self.parseTypeParamList(&type_params);
            self.expectCloseAngle("expected '>'") catch {};
        }
        var params = std.ArrayList(ast.Param).empty;
        _ = self.expect(.l_paren, "expected '('") catch {};
        if (!self.check(.r_paren)) {
            try self.parseParamList(&params);
        }
        _ = self.expect(.r_paren, "expected ')'") catch {};
        var return_type: ?*ast.TypeNode = null;
        if (self.matchToken(.colon)) {
            return_type = try self.parseType();
        }
        var delegate: ?ast.DelegateInfo = null;
        var body: ?*ast.Expr = null;
        if (self.matchToken(.eq)) {
            const trait_tok = try self.expect(.identifier, "expected delegate trait name");
            _ = self.expect(.dot, "expected '.'") catch {};
            const method_tok = try self.expect(.identifier, "expected delegate method name");
            delegate = ast.DelegateInfo{
                .trait_name = trait_tok.lexeme,
                .method_name = method_tok.lexeme,
            };
        } else if (self.check(.l_brace)) {
            body = try self.parseExpr();
        }
        return ast.MethodDecl{
            .location = tokenLoc(name_tok),
            .name = name_tok.lexeme,
            .type_params = try type_params.toOwnedSlice(self.arena.allocator()),
            .params = try params.toOwnedSlice(self.arena.allocator()),
            .return_type = return_type,
            .body = body,
            .is_override = is_override,
            .delegate = delegate,
            .visibility = visibility,
        };
    }

    /// 解析 import 声明：import path.to.module { item1, item2 as alias }
    fn parseUseDecl(self: *Parser, visibility: ast.Visibility) ParserError!ast.Decl {
        const use_tok = self.advance();
        var module_path = std.ArrayList([]const u8).empty;
        const first = try self.expect(.identifier, "expected module name");
        try module_path.append(self.arena.allocator(), first.lexeme);
        while (self.matchToken(.dot)) {
            if (self.check(.l_brace)) break;
            const part = try self.expect(.identifier, "expected module path segment");
            try module_path.append(self.arena.allocator(), part.lexeme);
        }
        var items: ?[]ast.ImportItem = null;
        if (self.check(.l_brace) or self.matchToken(.dot)) {
            _ = self.expect(.l_brace, "expected '{'") catch {};
            var item_list = std.ArrayList(ast.ImportItem).empty;
            if (!self.check(.r_brace)) {
                try item_list.append(self.arena.allocator(), try self.parseImportItem());
                while (self.matchToken(.comma)) {
                    if (self.check(.r_brace)) break;
                    try item_list.append(self.arena.allocator(), try self.parseImportItem());
                }
            }
            _ = self.expect(.r_brace, "expected '}'") catch {};
            items = try item_list.toOwnedSlice(self.arena.allocator());
        }
        return ast.Decl{
            .import_decl = .{
                .location = tokenLoc(use_tok),
                .module_path = try module_path.toOwnedSlice(self.arena.allocator()),
                .items = items,
                .visibility = visibility,
            },
        };
    }

    /// 解析单个导入项：name as alias
    fn parseImportItem(self: *Parser) ParserError!ast.ImportItem {
        const name = try self.expect(.identifier, "expected import item name");
        var alias: ?[]const u8 = null;
        if (self.matchToken(.kw_as)) {
            const alias_tok = try self.expect(.identifier, "expected alias");
            alias = alias_tok.lexeme;
        }
        return ast.ImportItem{
            .name = name.lexeme,
            .alias = alias,
        };
    }

    /// 解析 pack 声明：pack Name
    fn parsePackDecl(self: *Parser, visibility: ast.Visibility) ParserError!ast.Decl {
        const pack_tok = self.advance();
        const name_tok = try self.expect(.identifier, "expected pack name");
        return ast.Decl{
            .pack_decl = .{
                .location = tokenLoc(pack_tok),
                .visibility = visibility,
                .name = name_tok.lexeme,
            },
        };
    }

    // ---- 类型参数、kind、参数、约束 ----

    /// 解析类型参数列表（逗号分隔）
    fn parseTypeParamList(self: *Parser, type_params: *std.ArrayList(ast.TypeParam)) ParserError!void {
        try type_params.ensureTotalCapacity(self.arena.allocator(), 2);
        try type_params.append(self.arena.allocator(), try self.parseTypeParam());
        while (self.matchToken(.comma)) {
            try type_params.append(self.arena.allocator(), try self.parseTypeParam());
        }
    }

    /// 解析单个类型参数：Name: kind/trait with 约束
    fn parseTypeParam(self: *Parser) ParserError!ast.TypeParam {
        const name_tok = try self.expect(.identifier, "expected type parameter name");
        var kind: ?*ast.Kind = null;
        var bounds = std.ArrayList(ast.TraitBound).empty;
        if (self.matchToken(.colon)) {
            if (self.check(.identifier)) {
                const has_paren = self.check(.l_paren);
                if (has_paren) {
                    _ = self.advance();
                }
                const trait_name_tok = try self.expect(.identifier, "expected trait name");
                try bounds.append(self.arena.allocator(), ast.TraitBound{
                    .trait_name = trait_name_tok.lexeme,
                    .type_args = &[_]*ast.TypeNode{},
                });
                if (has_paren) {
                    while (self.matchToken(.comma)) {
                        const next_trait = try self.expect(.identifier, "expected trait name");
                        try bounds.append(self.arena.allocator(), ast.TraitBound{
                            .trait_name = next_trait.lexeme,
                            .type_args = &[_]*ast.TypeNode{},
                        });
                    }
                    _ = self.expect(.r_paren, "expected ')' after trait list") catch {};
                }
            } else {
                kind = try self.parseKind();
            }
        }
        if (self.matchToken(.kw_with)) {
            try self.parseTraitBoundListInner(&bounds);
        }
        return ast.TypeParam{
            .location = tokenLoc(name_tok),
            .name = name_tok.lexeme,
            .kind = kind,
            .bounds = try bounds.toOwnedSlice(self.arena.allocator()),
        };
    }

    /// 解析 kind 表达式（入口）
    fn parseKind(self: *Parser) ParserError!*ast.Kind {
        return self.parseKindArrow();
    }

    /// 解析箭头 kind：右结合，如 * -> * -> *
    fn parseKindArrow(self: *Parser) ParserError!*ast.Kind {
        const left = try self.parseKindPrimary();
        if (self.matchToken(.minus_gt)) {
            const arrow_tok = self.previous();
            const right = try self.parseKindArrow();
            return self.allocKind(tokenLoc(arrow_tok), ast.Kind{
                .arrow = .{
                    .param = left,
                    .result = right,
                },
            });
        }
        return left;
    }

    /// 解析 kind 基本元素：* 或括号包裹的 kind
    fn parseKindPrimary(self: *Parser) ParserError!*ast.Kind {
        if (self.check(.star)) {
            const star_tok = self.advance();
            return self.allocKind(tokenLoc(star_tok), ast.Kind.star);
        }
        if (self.matchToken(.l_paren)) {
            const kind = try self.parseKindArrow();
            _ = self.expect(.r_paren, "expected ')'") catch {};
            return kind;
        }
        try self.reportError("expected kind (* or arrow kind)");
        return error.UnexpectedToken;
    }

    /// 解析参数列表（逗号分隔，支持尾随逗号）
    fn parseParamList(self: *Parser, params: *std.ArrayList(ast.Param)) ParserError!void {
        try params.ensureTotalCapacity(self.arena.allocator(), 4);
        try params.append(self.arena.allocator(), try self.parseParam());
        while (self.matchToken(.comma)) {
            if (self.check(.r_paren)) break;
            try params.append(self.arena.allocator(), try self.parseParam());
        }
    }

    /// 解析单个参数：[var|val] name: Type
    fn parseParam(self: *Parser) ParserError!ast.Param {
        var is_var = false;
        if (self.matchToken(.kw_var)) {
            is_var = true;
        } else {
            _ = self.matchToken(.kw_val);
        }
        const name_tok = try self.expect(.identifier, "expected parameter name");
        var type_annotation: ?*ast.TypeNode = null;
        if (self.matchToken(.colon)) {
            if (self.matchToken(.kw_var)) {
                is_var = true;
            }
            type_annotation = try self.parseType();
        }
        return ast.Param{
            .location = tokenLoc(name_tok),
            .name = name_tok.lexeme,
            .type_annotation = type_annotation,
            .is_var = is_var,
        };
    }

    /// 解析 trait 约束列表（委托给 parseTraitBoundListInner）
    fn parseTraitBoundList(self: *Parser, bounds: *std.ArrayList(ast.TraitBound)) ParserError!void {
        try self.parseTraitBoundListInner(bounds);
    }

    /// 解析 trait 约束列表内部实现（逗号分隔）
    fn parseTraitBoundListInner(self: *Parser, bounds: *std.ArrayList(ast.TraitBound)) ParserError!void {
        try bounds.append(self.arena.allocator(), try self.parseTraitBound());
        while (self.matchToken(.comma)) {
            try bounds.append(self.arena.allocator(), try self.parseTraitBound());
        }
    }

    /// 解析单个 trait 约束：Name<类型实参>
    fn parseTraitBound(self: *Parser) ParserError!ast.TraitBound {
        const name_tok = try self.expect(.identifier, "expected trait name");
        var type_args = std.ArrayList(*ast.TypeNode).empty;
        if (self.matchToken(.lt)) {
            try self.parseTypeArgList(&type_args);
            self.expectCloseAngle("expected '>'") catch {};
        }
        return ast.TraitBound{
            .trait_name = name_tok.lexeme,
            .type_args = try type_args.toOwnedSlice(self.arena.allocator()),
        };
    }

    /// 解析类型约束列表（逗号分隔）
    fn parseTypeConstraints(self: *Parser, constraints: *std.ArrayList(ast.TypeConstraint)) ParserError!void {
        try constraints.append(self.arena.allocator(), try self.parseTypeConstraint());
        while (self.matchToken(.comma)) {
            try constraints.append(self.arena.allocator(), try self.parseTypeConstraint());
        }
    }

    /// 解析单个类型约束：类型参数: 具体类型
    fn parseTypeConstraint(self: *Parser) ParserError!ast.TypeConstraint {
        const type_param_tok = try self.expect(.identifier, "expected type parameter name");
        _ = try self.expect(.colon, "expected ':' after type parameter");
        const concrete_type = try self.parseType();
        return ast.TypeConstraint{
            .type_param = type_param_tok.lexeme,
            .concrete_type = concrete_type,
        };
    }

    /// 解析方法块（直到右大括号）
    fn parseMethodBlock(self: *Parser, methods: *std.ArrayList(ast.MethodDecl)) ParserError!void {
        while (!self.check(.r_brace) and !self.isAtEnd()) {
            const method = try self.parseMethodDecl();
            try methods.append(self.arena.allocator(), method);
        }
    }

    /// 解析类型实参列表（逗号分隔）
    fn parseTypeArgList(self: *Parser, type_args: *std.ArrayList(*ast.TypeNode)) ParserError!void {
        try type_args.append(self.arena.allocator(), try self.parseType());
        while (self.matchToken(.comma)) {
            try type_args.append(self.arena.allocator(), try self.parseType());
        }
    }

    // ---- 类型解析 ----

    /// 类型解析入口
    fn parseType(self: *Parser) ParserError!*ast.TypeNode {
        return self.parseFunctionType();
    }

    /// 解析函数类型：支持 (A, B) -> C 与 A -> C 两种形式
    fn parseFunctionType(self: *Parser) ParserError!*ast.TypeNode {
        if (self.check(.l_paren) and self.parenGroupFollowedByArrow()) {
            const loc = tokenLoc(self.peek());
            _ = self.advance();
            var params = std.ArrayList(*ast.TypeNode).empty;
            try params.ensureTotalCapacity(self.arena.allocator(), 4);
            if (!self.check(.r_paren)) {
                try params.append(self.arena.allocator(), try self.parseType());
                while (self.matchToken(.comma)) {
                    if (self.check(.r_paren)) break;
                    try params.append(self.arena.allocator(), try self.parseType());
                }
            }
            _ = self.expect(.r_paren, "expected ')'") catch {};
            _ = self.expect(.minus_gt, "expected '->'") catch {};
            const ret = try self.parseType();
            return self.allocType(loc, ast.TypeNode{
                .function = .{
                    .params = try params.toOwnedSlice(self.arena.allocator()),
                    .return_type = ret,
                },
            });
        }
        const left = try self.parseNullableType();
        if (self.matchToken(.minus_gt)) {
            var params = std.ArrayList(*ast.TypeNode).empty;
            try params.append(self.arena.allocator(), left);
            const ret = try self.parseType();
            return self.allocType(getTypeNodeLocation(left), ast.TypeNode{
                .function = .{
                    .params = try params.toOwnedSlice(self.arena.allocator()),
                    .return_type = ret,
                },
            });
        }
        return left;
    }

    /// 向前探测：圆括号组之后是否紧跟箭头（用于区分函数类型与分组类型）
    fn parenGroupFollowedByArrow(self: *Parser) bool {
        var i = self.current;
        if (i >= self.tokens.len or self.tokens[i].type != .l_paren) return false;
        var depth: usize = 0;
        while (i < self.tokens.len) : (i += 1) {
            switch (self.tokens[i].type) {
                .l_paren => depth += 1,
                .r_paren => {
                    depth -= 1;
                    if (depth == 0) {
                        const next = i + 1;
                        return next < self.tokens.len and self.tokens[next].type == .minus_gt;
                    }
                },
                .eof => return false,
                else => {},
            }
        }
        return false;
    }

    /// 解析可空类型：T?，支持链式（如 T??）
    fn parseNullableType(self: *Parser) ParserError!*ast.TypeNode {
        var ty = try self.parsePrimaryType();
        while (self.matchToken(.question)) {
            const location = getTypeNodeLocation(ty);
            switch (ty.*) {
                .nullable => {
                },
                else => {
                    ty = try self.allocType(location, ast.TypeNode{
                        .nullable = .{
                            .inner = ty,
                        },
                    });
                },
            }
        }
        return ty;
    }

    /// 解析基本类型：命名/泛型类型，支持后缀数组 [N]
    fn parsePrimaryType(self: *Parser) ParserError!*ast.TypeNode {
        if (self.check(.l_paren)) {
            return self.parseRecordType();
        }
        const name_tok = try self.expect(.identifier, "expected type name");
        const location = tokenLoc(name_tok);
        var ty: *ast.TypeNode = undefined;
        if (self.matchToken(.lt)) {
            var args = std.ArrayList(*ast.TypeNode).empty;
            try args.append(self.arena.allocator(), try self.parseType());
            while (self.matchToken(.comma)) {
                try args.append(self.arena.allocator(), try self.parseType());
            }
            self.expectCloseAngle("expected '>' to close type parameters") catch {};
            ty = try self.allocType(location, ast.TypeNode{
                .generic = .{
                    .name = name_tok.lexeme,
                    .args = try args.toOwnedSlice(self.arena.allocator()),
                },
            });
        } else {
            ty = try self.allocType(location, ast.TypeNode{
                .named = .{
                    .name = name_tok.lexeme,
                },
            });
        }
        // 后缀数组类型 T[N]
        while (self.matchToken(.l_bracket)) {
            const arr_location = tokenLoc(name_tok);
            var size: ?u64 = null;
            if (!self.check(.r_bracket)) {
                const size_tok = try self.expect(.int_literal, "expected array size");
                size = std.fmt.parseInt(u64, size_tok.lexeme, 10) catch {
                    try self.reportError("array size must be a positive integer");
                    return error.UnexpectedToken;
                };
            }
            _ = self.expect(.r_bracket, "expected ']'") catch {};
            ty = try self.allocType(arr_location, ast.TypeNode{
                .array = .{
                    .element_type = ty,
                    .size = size,
                },
            });
        }
        return ty;
    }

    /// 解析记录类型：(field: Type, ...)
    fn parseRecordType(self: *Parser) ParserError!*ast.TypeNode {
        const lparen = self.advance();
        const location = tokenLoc(lparen);
        var fields = std.ArrayList(ast.RecordFieldType).empty;
        if (!self.check(.r_paren)) {
            const name_tok = try self.expect(.identifier, "expected field name");
            _ = self.expect(.colon, "expected ':'") catch {};
            const ty = try self.parseType();
            try fields.append(self.arena.allocator(), .{
                .name = name_tok.lexeme,
                .ty = ty,
            });
            while (self.matchToken(.comma)) {
                if (self.check(.r_paren)) break;
                const field_name = try self.expect(.identifier, "expected field name");
                _ = self.expect(.colon, "expected ':'") catch {};
                const field_ty = try self.parseType();
                try fields.append(self.arena.allocator(), .{
                    .name = field_name.lexeme,
                    .ty = field_ty,
                });
            }
        }
        _ = self.expect(.r_paren, "expected ')'") catch {};
        return self.allocType(location, ast.TypeNode{
            .record = .{
                .fields = try fields.toOwnedSlice(self.arena.allocator()),
            },
        });
    }

    // ---- 表达式解析（优先级爬升） ----

    /// 表达式解析入口
    pub fn parseExpr(self: *Parser) ParserError!*ast.Expr {
        return self.parseElvis();
    }

    /// 解析 Elvis 运算符 ??（最低优先级）
    fn parseElvis(self: *Parser) ParserError!*ast.Expr {
        var left = try self.parseOr();
        while (self.matchToken(.question_question)) {
            const op_tok = self.previous();
            const right = try self.parseOr();
            left = try self.allocExpr(tokenLoc(op_tok), ast.Expr{
                .binary = .{
                    .op = .elvis,
                    .left = left,
                    .right = right,
                },
            });
        }
        return left;
    }

    /// 解析逻辑或 ||
    fn parseOr(self: *Parser) ParserError!*ast.Expr {
        var left = try self.parseAnd();
        while (self.matchToken(.pipe_pipe)) {
            const op_tok = self.previous();
            const right = try self.parseAnd();
            left = try self.allocExpr(tokenLoc(op_tok), ast.Expr{
                .binary = .{
                    .op = .or_op,
                    .left = left,
                    .right = right,
                },
            });
        }
        return left;
    }

    /// 解析逻辑与 &&
    fn parseAnd(self: *Parser) ParserError!*ast.Expr {
        var left = try self.parseBitOr();
        while (self.matchToken(.amp_amp)) {
            const op_tok = self.previous();
            const right = try self.parseBitOr();
            left = try self.allocExpr(tokenLoc(op_tok), ast.Expr{
                .binary = .{
                    .op = .and_op,
                    .left = left,
                    .right = right,
                },
            });
        }
        return left;
    }

    /// 解析按位或 |
    fn parseBitOr(self: *Parser) ParserError!*ast.Expr {
        var left = try self.parseBitXor();
        while (self.matchToken(.pipe)) {
            const op_tok = self.previous();
            const right = try self.parseBitXor();
            left = try self.allocExpr(tokenLoc(op_tok), ast.Expr{
                .binary = .{
                    .op = .bit_or,
                    .left = left,
                    .right = right,
                },
            });
        }
        return left;
    }

    /// 解析按位异或 ^
    fn parseBitXor(self: *Parser) ParserError!*ast.Expr {
        var left = try self.parseBitAnd();
        while (self.matchToken(.caret)) {
            const op_tok = self.previous();
            const right = try self.parseBitAnd();
            left = try self.allocExpr(tokenLoc(op_tok), ast.Expr{
                .binary = .{
                    .op = .bit_xor,
                    .left = left,
                    .right = right,
                },
            });
        }
        return left;
    }

    /// 解析按位与 &
    fn parseBitAnd(self: *Parser) ParserError!*ast.Expr {
        var left = try self.parseShift();
        while (self.matchToken(.ampersand)) {
            const op_tok = self.previous();
            const right = try self.parseShift();
            left = try self.allocExpr(tokenLoc(op_tok), ast.Expr{
                .binary = .{
                    .op = .bit_and,
                    .left = left,
                    .right = right,
                },
            });
        }
        return left;
    }

    /// 解析移位 << >>
    fn parseShift(self: *Parser) ParserError!*ast.Expr {
        var left = try self.parseEquality();
        while (true) {
            if (self.matchToken(.lt_lt)) {
                const op_tok = self.previous();
                const right = try self.parseEquality();
                left = try self.allocExpr(tokenLoc(op_tok), ast.Expr{
                    .binary = .{
                        .op = .shl,
                        .left = left,
                        .right = right,
                    },
                });
            } else if (self.matchToken(.gt_gt)) {
                const op_tok = self.previous();
                const right = try self.parseEquality();
                left = try self.allocExpr(tokenLoc(op_tok), ast.Expr{
                    .binary = .{
                        .op = .shr,
                        .left = left,
                        .right = right,
                    },
                });
            } else break;
        }
        return left;
    }

    /// 解析相等性 == !=
    fn parseEquality(self: *Parser) ParserError!*ast.Expr {
        var left = try self.parseComparison();
        while (true) {
            if (self.matchToken(.eq_eq)) {
                const op_tok = self.previous();
                const right = try self.parseComparison();
                left = try self.allocExpr(tokenLoc(op_tok), ast.Expr{
                    .binary = .{
                        .op = .eq,
                        .left = left,
                        .right = right,
                    },
                });
            } else if (self.matchToken(.bang_eq)) {
                const op_tok = self.previous();
                const right = try self.parseComparison();
                left = try self.allocExpr(tokenLoc(op_tok), ast.Expr{
                    .binary = .{
                        .op = .not_eq,
                        .left = left,
                        .right = right,
                    },
                });
            } else {
                break;
            }
        }
        return left;
    }

    /// 解析比较 < > <= >=
    fn parseComparison(self: *Parser) ParserError!*ast.Expr {
        var left = try self.parseRange();
        while (true) {
            const op: ?ast.BinaryOp = switch (self.peek().type) {
                .lt => .lt,
                .gt => .gt,
                .lt_eq => .lt_eq,
                .gt_eq => .gt_eq,
                else => null,
            };
            if (op) |o| {
                const op_tok = self.advance();
                const right = try self.parseRange();
                left = try self.allocExpr(tokenLoc(op_tok), ast.Expr{
                    .binary = .{
                        .op = o,
                        .left = left,
                        .right = right,
                    },
                });
            } else {
                break;
            }
        }
        return left;
    }

    /// 解析范围 .. ..=
    fn parseRange(self: *Parser) ParserError!*ast.Expr {
        var left = try self.parseAddition();
        while (true) {
            if (self.matchToken(.dot_dot)) {
                const op_tok = self.previous();
                const right = try self.parseAddition();
                left = try self.allocExpr(tokenLoc(op_tok), ast.Expr{
                    .binary = .{
                        .op = .range,
                        .left = left,
                        .right = right,
                    },
                });
            } else if (self.matchToken(.dot_dot_eq)) {
                const op_tok = self.previous();
                const right = try self.parseAddition();
                left = try self.allocExpr(tokenLoc(op_tok), ast.Expr{
                    .binary = .{
                        .op = .range_inclusive,
                        .left = left,
                        .right = right,
                    },
                });
            } else {
                break;
            }
        }
        return left;
    }

    /// 解析加减 ++ + -
    fn parseAddition(self: *Parser) ParserError!*ast.Expr {
        var left = try self.parseMultiplication();
        while (true) {
            if (self.matchToken(.plus)) {
                const op_tok = self.previous();
                const right = try self.parseMultiplication();
                left = try self.allocExpr(tokenLoc(op_tok), ast.Expr{
                    .binary = .{
                        .op = .add,
                        .left = left,
                        .right = right,
                    },
                });
            } else if (self.matchToken(.plus_plus)) {
                const op_tok = self.previous();
                const right = try self.parseMultiplication();
                left = try self.allocExpr(tokenLoc(op_tok), ast.Expr{
                    .binary = .{
                        .op = .concat_list,
                        .left = left,
                        .right = right,
                    },
                });
            } else if (self.matchToken(.minus)) {
                const op_tok = self.previous();
                const right = try self.parseMultiplication();
                left = try self.allocExpr(tokenLoc(op_tok), ast.Expr{
                    .binary = .{
                        .op = .sub,
                        .left = left,
                        .right = right,
                    },
                });
            } else {
                break;
            }
        }
        return left;
    }

    /// 解析乘除模 * / %
    fn parseMultiplication(self: *Parser) ParserError!*ast.Expr {
        var left = try self.parseUnary();
        while (true) {
            const op: ?ast.BinaryOp = switch (self.peek().type) {
                .star => .mul,
                .slash => .div,
                .percent => .mod,
                else => null,
            };
            if (op) |o| {
                const op_tok = self.advance();
                const right = try self.parseUnary();
                left = try self.allocExpr(tokenLoc(op_tok), ast.Expr{
                    .binary = .{
                        .op = o,
                        .left = left,
                        .right = right,
                    },
                });
            } else {
                break;
            }
        }
        return left;
    }

    /// 解析一元运算 ! - ~，负号直接折叠到数字字面量
    fn parseUnary(self: *Parser) ParserError!*ast.Expr {
        if (self.matchToken(.bang)) {
            const op_tok = self.previous();
            const operand = try self.parseUnary();
            return self.allocExpr(tokenLoc(op_tok), ast.Expr{
                .unary = .{
                    .op = .not,
                    .operand = operand,
                },
            });
        }
        if (self.matchToken(.tilde)) {
            const op_tok = self.previous();
            const operand = try self.parseUnary();
            return self.allocExpr(tokenLoc(op_tok), ast.Expr{
                .unary = .{
                    .op = .bit_not,
                    .operand = operand,
                },
            });
        }
        if (self.matchToken(.minus)) {
            const op_tok = self.previous();
            // 负号紧跟数字字面量时直接合并，避免产生多余的一元节点
            if (self.check(.int_literal)) {
                const lit_tok = self.advance();
                return self.parseNegativeIntLiteral(op_tok, lit_tok);
            }
            if (self.check(.float_literal)) {
                const lit_tok = self.advance();
                return self.parseNegativeFloatLiteral(op_tok, lit_tok);
            }
            const operand = try self.parseUnary();
            return self.allocExpr(tokenLoc(op_tok), ast.Expr{
                .unary = .{
                    .op = .neg,
                    .operand = operand,
                },
            });
        }
        return self.parsePostfix();
    }

    /// 解析后缀运算：? ! ?. . () <> []
    fn parsePostfix(self: *Parser) ParserError!*ast.Expr {
        var expr_node = try self.parsePrimary();
        while (true) {
            if (self.matchToken(.question)) {
                const op_tok = self.previous();
                // 特殊处理：type_cast 后紧跟 ? → 安全转换（i32(x)? → tryCast + 错误传播）
                if (expr_node.* == .type_cast and !expr_node.type_cast.safe) {
                    expr_node.type_cast.safe = true;
                    continue;
                }
                expr_node = try self.allocExpr(tokenLoc(op_tok), ast.Expr{
                    .propagate = .{
                        .expr = expr_node,
                    },
                });
            } else if (self.matchToken(.bang)) {
                const op_tok = self.previous();
                expr_node = try self.allocExpr(tokenLoc(op_tok), ast.Expr{
                    .non_null_assert = .{
                        .expr = expr_node,
                    },
                });
            } else if (self.matchToken(.question_dot)) {
                // 安全调用 ?.field 或 ?.method(args)
                const op_tok = self.previous();
                const field_tok = try self.expect(.identifier, "expected field or method name");
                if (self.check(.l_paren)) {
                    var args = std.ArrayList(*ast.Expr).empty;
                    try args.ensureTotalCapacity(self.arena.allocator(), 4);
                    var type_args: ?[]*ast.TypeNode = null;
                    if (self.matchToken(.lt)) {
                        var ta = std.ArrayList(*ast.TypeNode).empty;
                        try self.parseTypeArgList(&ta);
                        self.expectCloseAngle("expected '>'") catch {};
                        type_args = try ta.toOwnedSlice(self.arena.allocator());
                    }
                    _ = self.expect(.l_paren, "expected '('") catch {};
                    if (!self.check(.r_paren)) {
                        try args.append(self.arena.allocator(), try self.parseExpr());
                        while (self.matchToken(.comma)) {
                            try args.append(self.arena.allocator(), try self.parseExpr());
                        }
                    }
                    _ = self.expect(.r_paren, "expected ')'") catch {};
                    expr_node = try self.allocExpr(tokenLoc(op_tok), ast.Expr{
                        .safe_method_call = .{
                            .object = expr_node,
                            .method = field_tok.lexeme,
                            .arguments = try args.toOwnedSlice(self.arena.allocator()),
                            .type_args = type_args,
                        },
                    });
                } else {
                    expr_node = try self.allocExpr(tokenLoc(op_tok), ast.Expr{
                        .safe_access = .{
                            .object = expr_node,
                            .field = field_tok.lexeme,
                        },
                    });
                }
            } else if (self.matchToken(.dot)) {
                // 字段访问 .field 或方法调用 .method(args)
                const op_tok = self.previous();
                const field_tok = try self.expect(.identifier, "expected field or method name");
                if (self.check(.l_paren)) {
                    var args = std.ArrayList(*ast.Expr).empty;
                    try args.ensureTotalCapacity(self.arena.allocator(), 4);
                    var type_args: ?[]*ast.TypeNode = null;
                    if (self.matchToken(.lt)) {
                        var ta = std.ArrayList(*ast.TypeNode).empty;
                        try self.parseTypeArgList(&ta);
                        self.expectCloseAngle("expected '>'") catch {};
                        type_args = try ta.toOwnedSlice(self.arena.allocator());
                    }
                    _ = self.expect(.l_paren, "expected '('") catch {};
                    if (!self.check(.r_paren)) {
                        try args.append(self.arena.allocator(), try self.parseExpr());
                        while (self.matchToken(.comma)) {
                            try args.append(self.arena.allocator(), try self.parseExpr());
                        }
                    }
                    _ = self.expect(.r_paren, "expected ')'") catch {};
                    expr_node = try self.allocExpr(tokenLoc(op_tok), ast.Expr{
                        .method_call = .{
                            .object = expr_node,
                            .method = field_tok.lexeme,
                            .arguments = try args.toOwnedSlice(self.arena.allocator()),
                            .type_args = type_args,
                        },
                    });
                } else {
                    expr_node = try self.allocExpr(tokenLoc(op_tok), ast.Expr{
                        .field_access = .{
                            .object = expr_node,
                            .field = field_tok.lexeme,
                        },
                    });
                }
            } else if (self.check(.l_paren)) {
                // 函数调用 f(args)，禁止链式调用 f(a)(b)
                if (expr_node.* == .call) {
                    const tok = self.peek();
                    try self.errors.append(self.arena.allocator(), ParseError{
                        .line = tok.line,
                        .column = tok.column,
                        .message = "chained call f(a)(b) is not allowed; use default currying: bind the partial result to a variable first",
                    });
                    return error.UnexpectedToken;
                }
                const call_tok = self.peek();
                var args = std.ArrayList(*ast.Expr).empty;
                try args.ensureTotalCapacity(self.arena.allocator(), 4);
                var type_args: ?[]*ast.TypeNode = null;
                if (self.matchToken(.lt)) {
                    var ta = std.ArrayList(*ast.TypeNode).empty;
                    try self.parseTypeArgList(&ta);
                    if (self.matchToken(.gt)) {
                        type_args = try ta.toOwnedSlice(self.arena.allocator());
                    } else {
                        self.current -= ta.items.len + 1;
                        ta.deinit(self.arena.allocator());
                    }
                }
                _ = self.expect(.l_paren, "expected '('") catch {};
                if (!self.check(.r_paren)) {
                    try args.append(self.arena.allocator(), try self.parseExpr());
                    while (self.matchToken(.comma)) {
                        try args.append(self.arena.allocator(), try self.parseExpr());
                    }
                }
                _ = self.expect(.r_paren, "expected ')'") catch {};
                expr_node = try self.allocExpr(tokenLoc(call_tok), ast.Expr{
                    .call = .{
                        .callee = expr_node,
                        .arguments = try args.toOwnedSlice(self.arena.allocator()),
                        .type_args = type_args,
                    },
                });
            } else if (self.check(.lt) and self.isTurbofishCall()) {
                // turbofish 调用 f::<Type>(args)
                _ = self.matchToken(.lt);
                var ta = std.ArrayList(*ast.TypeNode).empty;
                try self.parseTypeArgList(&ta);
                self.expectCloseAngle("expected '>'") catch {};
                const type_args: ?[]*ast.TypeNode = try ta.toOwnedSlice(self.arena.allocator());
                if (expr_node.* == .call) {
                    const tok = self.peek();
                    try self.errors.append(self.arena.allocator(), ParseError{
                        .line = tok.line,
                        .column = tok.column,
                        .message = "chained call f(a)(b) is not allowed; use default currying: bind the partial result to a variable first",
                    });
                    return error.UnexpectedToken;
                }
                const call_tok = self.peek();
                var args = std.ArrayList(*ast.Expr).empty;
                try args.ensureTotalCapacity(self.arena.allocator(), 4);
                _ = self.expect(.l_paren, "expected '('") catch {};
                if (!self.check(.r_paren)) {
                    try args.append(self.arena.allocator(), try self.parseExpr());
                    while (self.matchToken(.comma)) {
                        try args.append(self.arena.allocator(), try self.parseExpr());
                    }
                }
                _ = self.expect(.r_paren, "expected ')'") catch {};
                expr_node = try self.allocExpr(tokenLoc(call_tok), ast.Expr{
                    .call = .{
                        .callee = expr_node,
                        .arguments = try args.toOwnedSlice(self.arena.allocator()),
                        .type_args = type_args,
                    },
                });
            } else if (self.matchToken(.l_bracket)) {
                // 索引访问 obj[index]
                const bracket_tok = self.previous();
                const index = try self.parseExpr();
                _ = self.expect(.r_bracket, "expected ']'") catch {};
                expr_node = try self.allocExpr(tokenLoc(bracket_tok), ast.Expr{
                    .index = .{
                        .object = expr_node,
                        .index = index,
                    },
                });
            } else {
                break;
            }
        }
        return expr_node;
    }

    /// 探测 `::<...>(` 形式的 turbofish 调用，避免与小于号比较混淆
    fn isTurbofishCall(self: *Parser) bool {
        if (!self.check(.lt)) return false;
        var i = self.current + 1;
        var depth: usize = 1;
        var steps: usize = 0;
        while (i < self.tokens.len and steps < 256) : (steps += 1) {
            const tt = self.tokens[i].type;
            switch (tt) {
                .lt => depth += 1,
                .gt => {
                    depth -= 1;
                    if (depth == 0) {
                        return i + 1 < self.tokens.len and self.tokens[i + 1].type == .l_paren;
                    }
                },
                .l_brace, .r_brace, .eq, .eq_gt, .eof => return false,
                else => {},
            }
            i += 1;
        }
        return false;
    }

    /// 解析基本表达式：字面量、标识符、lambda、if/match/lazy/atomic/select、块、数组、括号等
    fn parsePrimary(self: *Parser) ParserError!*ast.Expr {
        if (self.matchToken(.int_literal)) {
            const tok = self.previous();
            return self.parseIntLiteral(tok);
        }
        if (self.matchToken(.float_literal)) {
            const tok = self.previous();
            return self.parseFloatLiteral(tok);
        }
        if (self.matchToken(.true_literal)) {
            const tok = self.previous();
            return self.allocExpr(tokenLoc(tok), ast.Expr{
                .bool_literal = .{
                    .value = true,
                },
            });
        }
        if (self.matchToken(.false_literal)) {
            const tok = self.previous();
            return self.allocExpr(tokenLoc(tok), ast.Expr{
                .bool_literal = .{
                    .value = false,
                },
            });
        }
        if (self.matchToken(.char_literal)) {
            const tok = self.previous();
            return self.allocExpr(tokenLoc(tok), ast.Expr{
                .char_literal = .{
                    .value = parseCharValue(tok.lexeme),
                },
            });
        }
        if (self.matchToken(.string_literal)) {
            const tok = self.previous();
            return self.parseStringLiteral(tok);
        }
        if (self.matchToken(.null_literal)) {
            const tok = self.previous();
            return self.allocExpr(tokenLoc(tok), ast.Expr{
                .null_literal = {},
            });
        }
        if (self.check(.kw_fun)) {
            if (self.tokens.len > self.current + 1 and self.tokens[self.current + 1].type == .l_paren) {
                return self.parseLambdaFun(false);
            }
        }
        if (self.check(.kw_async)) {
            if (self.tokens.len > self.current + 1 and self.tokens[self.current + 1].type == .kw_fun) {
                _ = self.advance();
                return self.parseLambdaFun(true);
            }
        }
        if (self.matchToken(.kw_if)) {
            return self.parseIfExpr();
        }
        if (self.matchToken(.kw_match)) {
            return self.parseMatchExpr();
        }
        if (self.matchToken(.kw_lazy)) {
            return self.parseLazyExpr();
        }
        if (self.matchToken(.kw_spawn)) {
            return self.parseSpawnExpr();
        }
        if (self.matchToken(.kw_atomic)) {
            return self.parseAtomicExpr();
        }
        if (self.matchToken(.kw_select)) {
            return self.parseSelectExpr();
        }
        if (self.check(.kw_trait)) {
            if (self.tokens.len > self.current + 1 and self.tokens[self.current + 1].type == .l_brace) {
                return self.parseInlineTraitValue();
            }
        }
        if (self.matchToken(.l_bracket)) {
            return self.parseArrayLiteral();
        }
        if (self.check(.l_brace)) {
            return self.parseBlockExpr();
        }
        if (self.matchToken(.l_paren)) {
            return self.parseParenOrRecordOrLambda();
        }
        if (self.check(.kw_type) and
            self.tokens.len > self.current + 1 and
            self.tokens[self.current + 1].type == .l_paren)
        {
            const tok = self.advance();
            return self.allocExpr(tokenLoc(tok), ast.Expr{
                .identifier = .{
                    .name = tok.lexeme,
                },
            });
        }
        if (self.check(.identifier) or self.check(.kw_val) or self.check(.kw_var) or self.check(.kw_channel)) {
            if (isBuiltinType(self.peek().lexeme)) {
                if (self.tokens.len > self.current + 1 and self.tokens[self.current + 1].type == .l_paren) {
                    return self.parseTypeCast();
                }
            }
            const tok = self.advance();
            return self.allocExpr(tokenLoc(tok), ast.Expr{
                .identifier = .{
                    .name = tok.lexeme,
                },
            });
        }
        try self.reportError("expected expression");
        return error.UnexpectedToken;
    }

    /// 解析整数字面量，分离数字部分与类型后缀
    fn parseIntLiteral(self: *Parser, tok: lexer.Token) ParserError!*ast.Expr {
        var suffix: ?[]const u8 = null;
        const raw = tok.lexeme;
        var i: usize = 0;
        if (raw.len > 2 and raw[0] == '0') {
            if (raw[1] == 'x' or raw[1] == 'X' or raw[1] == 'o' or raw[1] == 'O' or raw[1] == 'b' or raw[1] == 'B') {
                i = 2;
            }
        }
        while (i < raw.len and isDigitOrUnderscore(raw[i])) : (i += 1) {}
        if (i < raw.len and raw.len > 2 and raw[0] == '0' and (raw[1] == 'x' or raw[1] == 'X')) {
            while (i < raw.len and isHexOrUnderscore(raw[i])) : (i += 1) {}
        }
        if (i < raw.len) {
            suffix = raw[i..];
        }
        return self.allocExpr(tokenLoc(tok), ast.Expr{
            .int_literal = .{
                .raw = raw[0..i],
                .suffix = suffix,
            },
        });
    }

    /// 解析负整数字面量，将负号合并进 raw
    fn parseNegativeIntLiteral(self: *Parser, minus_tok: lexer.Token, lit_tok: lexer.Token) ParserError!*ast.Expr {
        _ = minus_tok;
        var suffix: ?[]const u8 = null;
        const lit_raw = lit_tok.lexeme;
        var i: usize = 0;
        if (lit_raw.len > 2 and lit_raw[0] == '0') {
            if (lit_raw[1] == 'x' or lit_raw[1] == 'X' or lit_raw[1] == 'o' or lit_raw[1] == 'O' or lit_raw[1] == 'b' or lit_raw[1] == 'B') {
                i = 2;
            }
        }
        while (i < lit_raw.len and isDigitOrUnderscore(lit_raw[i])) : (i += 1) {}
        if (i < lit_raw.len and lit_raw.len > 2 and lit_raw[0] == '0' and (lit_raw[1] == 'x' or lit_raw[1] == 'X')) {
            while (i < lit_raw.len and isHexOrUnderscore(lit_raw[i])) : (i += 1) {}
        }
        if (i < lit_raw.len) {
            suffix = lit_raw[i..];
        }
        const neg_raw = try self.arena.allocator().alloc(u8, i + 1);
        neg_raw[0] = '-';
        @memcpy(neg_raw[1..], lit_raw[0..i]);
        return self.allocExpr(tokenLoc(lit_tok), ast.Expr{
            .int_literal = .{
                .raw = neg_raw,
                .suffix = suffix,
            },
        });
    }

    /// 解析负浮点字面量，将负号合并进 raw
    fn parseNegativeFloatLiteral(self: *Parser, minus_tok: lexer.Token, lit_tok: lexer.Token) ParserError!*ast.Expr {
        _ = minus_tok;
        var suffix: ?[]const u8 = null;
        const lit_raw = lit_tok.lexeme;
        var i: usize = lit_raw.len;
        while (i > 0) {
            const ch = lit_raw[i - 1];
            if (ch >= '0' and ch <= '9') {
                i -= 1;
            } else {
                break;
            }
        }
        while (i > 0) {
            const ch = lit_raw[i - 1];
            if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z')) {
                i -= 1;
            } else {
                break;
            }
        }
        if (i < lit_raw.len and i > 0 and ((lit_raw[i] >= 'a' and lit_raw[i] <= 'z') or (lit_raw[i] >= 'A' and lit_raw[i] <= 'Z'))) {
            suffix = lit_raw[i..];
        } else {
            i = lit_raw.len;
        }
        const neg_raw = try self.arena.allocator().alloc(u8, i + 1);
        neg_raw[0] = '-';
        @memcpy(neg_raw[1..], lit_raw[0..i]);
        return self.allocExpr(tokenLoc(lit_tok), ast.Expr{
            .float_literal = .{
                .raw = neg_raw,
                .suffix = suffix,
            },
        });
    }

    /// 解析浮点字面量，分离数字部分与类型后缀
    fn parseFloatLiteral(self: *Parser, tok: lexer.Token) ParserError!*ast.Expr {
        var suffix: ?[]const u8 = null;
        const raw = tok.lexeme;
        var i: usize = raw.len;
        while (i > 0) {
            const ch = raw[i - 1];
            if (ch >= '0' and ch <= '9') {
                i -= 1;
            } else {
                break;
            }
        }
        while (i > 0) {
            const ch = raw[i - 1];
            if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z')) {
                i -= 1;
            } else {
                break;
            }
        }
        if (i < raw.len and i > 0 and ((raw[i] >= 'a' and raw[i] <= 'z') or (raw[i] >= 'A' and raw[i] <= 'Z'))) {
            suffix = raw[i..];
        } else {
            i = raw.len;
        }
        return self.allocExpr(tokenLoc(tok), ast.Expr{
            .float_literal = .{
                .raw = raw[0..i],
                .suffix = suffix,
            },
        });
    }

    /// 解析字符串字面量，含插值时拆分为字面量与表达式片段
    fn parseStringLiteral(self: *Parser, tok: lexer.Token) ParserError!*ast.Expr {
        const raw = tok.lexeme;
        if (!containsInterpolation(raw)) {
            const content = raw[1 .. raw.len - 1];
            const value = try self.unescapeString(content);
            return self.allocExpr(tokenLoc(tok), ast.Expr{
                .string_literal = .{
                    .value = value,
                },
            });
        }
        var parts = std.ArrayList(ast.InterpolationPart).empty;
        errdefer {
            for (parts.items) |*p| {
                switch (p.*) {
                    .literal => |s| self.arena.allocator().free(s),
                    else => {},
                }
            }
            parts.deinit(self.arena.allocator());
        }
        const content = raw[1 .. raw.len - 1];
        var i: usize = 0;
        var literal_start: usize = 0;
        while (i < content.len) {
            if (content[i] == '\\') {
                i += 2;
                continue;
            }
            if (content[i] == '{') {
                if (i + 1 < content.len and content[i + 1] == '{') {
                    i += 2;
                    continue;
                }
                if (i > literal_start) {
                    const text = try self.unescapeString(content[literal_start..i]);
                    try parts.append(self.arena.allocator(), ast.InterpolationPart{ .literal = text });
                }
                i += 1;
                const expr_start = i;
                var brace_depth: usize = 1;
                while (i < content.len and brace_depth > 0) {
                    if (content[i] == '{') {
                        brace_depth += 1;
                    } else if (content[i] == '}') {
                        brace_depth -= 1;
                    } else if (content[i] == '\\') {
                        i += 1;
                    }
                    i += 1;
                }
                const expr_text = content[expr_start .. i - 1];
                const expr = try self.parseInterpolationExpr(expr_text);
                try parts.append(self.arena.allocator(), ast.InterpolationPart{ .expression = expr });
                literal_start = i;
                continue;
            }
            i += 1;
        }
        if (literal_start < content.len) {
            const text = try self.unescapeString(content[literal_start..]);
            try parts.append(self.arena.allocator(), ast.InterpolationPart{ .literal = text });
        }
        return self.allocExpr(tokenLoc(tok), ast.Expr{
            .string_interpolation = .{
                .parts = try parts.toOwnedSlice(self.arena.allocator()),
            },
        });
    }

    /// 对插值表达式文本进行词法+语法分析，返回其 AST 节点。
    /// 复用当前 Parser（保存/恢复状态），避免创建嵌套 ArenaAllocator。
    fn parseInterpolationExpr(self: *Parser, text: []const u8) ParserError!*ast.Expr {
        var interp_lex = lexer.Lexer.init(self.arena.allocator(), text);
        const tokens = interp_lex.tokenize() catch return error.UnexpectedToken;
        // tokens 由 arena 管理，无需手动释放
        const saved_tokens = self.tokens;
        const saved_current = self.current;
        const saved_pending_eq = self.pending_eq;
        const saved_error_count = self.errors.items.len;
        self.tokens = tokens;
        self.current = 0;
        self.pending_eq = false;
        const expr = self.parseExpr() catch {
            // 恢复解析器状态
            self.tokens = saved_tokens;
            self.current = saved_current;
            self.pending_eq = saved_pending_eq;
            self.errors.shrinkRetainingCapacity(saved_error_count);
            return error.UnexpectedToken;
        };
        // 恢复解析器状态
        self.tokens = saved_tokens;
        self.current = saved_current;
        self.pending_eq = saved_pending_eq;
        return expr;
    }

    /// 反转义字符串：处理 \n \t \r \\ \" \{ \} 以及 {{ }} 转义
    fn unescapeString(self: *Parser, text: []const u8) ParserError![]const u8 {
        // 快路径：单次扫描检测是否含转义序列（\、{{、}}），若无则零拷贝返回原切片
        {
            var i: usize = 0;
            while (i < text.len) {
                const c = text[i];
                if (c == '\\') break;
                if (c == '{' and i + 1 < text.len and text[i + 1] == '{') break;
                if (c == '}' and i + 1 < text.len and text[i + 1] == '}') break;
                i += 1;
            }
            if (i >= text.len) return text;
        }
        // 慢路径：逐字符处理转义
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(self.arena.allocator());
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '\\' and i + 1 < text.len) {
                const next = text[i + 1];
                switch (next) {
                    'n' => {
                        try result.append(self.arena.allocator(), '\n');
                        i += 2;
                    },
                    't' => {
                        try result.append(self.arena.allocator(), '\t');
                        i += 2;
                    },
                    'r' => {
                        try result.append(self.arena.allocator(), '\r');
                        i += 2;
                    },
                    '\\' => {
                        try result.append(self.arena.allocator(), '\\');
                        i += 2;
                    },
                    '"' => {
                        try result.append(self.arena.allocator(), '"');
                        i += 2;
                    },
                    '{' => {
                        try result.append(self.arena.allocator(), '{');
                        i += 2;
                    },
                    '}' => {
                        try result.append(self.arena.allocator(), '}');
                        i += 2;
                    },
                    else => {
                        try result.append(self.arena.allocator(), text[i]);
                        i += 1;
                    },
                }
            } else if (text[i] == '{' and i + 1 < text.len and text[i + 1] == '{') {
                try result.append(self.arena.allocator(), '{');
                i += 2;
            } else if (text[i] == '}' and i + 1 < text.len and text[i + 1] == '}') {
                try result.append(self.arena.allocator(), '}');
                i += 2;
            } else {
                try result.append(self.arena.allocator(), text[i]);
                i += 1;
            }
        }
        return result.toOwnedSlice(self.arena.allocator());
    }

    /// 解析 fun 关键字开头的 lambda：fun(params) body
    fn parseLambdaFun(self: *Parser, is_async: bool) ParserError!*ast.Expr {
        const fun_tok = self.advance();
        const location = tokenLoc(fun_tok);
        var params = std.ArrayList(ast.Param).empty;
        _ = self.expect(.l_paren, "expected '('") catch {};
        if (!self.check(.r_paren)) {
            try self.parseParamList(&params);
        }
        _ = self.expect(.r_paren, "expected ')'") catch {};
        const body_expr = try self.parseExpr();
        const body = ast.LambdaBody{ .block = body_expr };
        return self.allocExpr(location, ast.Expr{
            .lambda = .{
                .params = try params.toOwnedSlice(self.arena.allocator()),
                .body = body,
                .is_async = is_async,
            },
        });
    }

    /// 解析 if 表达式：if cond then else?
    fn parseIfExpr(self: *Parser) ParserError!*ast.Expr {
        const if_tok = self.previous();
        try self.rejectParenCondition("if");
        const condition = try self.parseExpr();
        const then_branch = try self.parseExpr();
        var else_branch: ?*ast.Expr = null;
        if (self.matchToken(.kw_else)) {
            else_branch = try self.parseExpr();
        }
        return self.allocExpr(tokenLoc(if_tok), ast.Expr{
            .if_expr = .{
                .condition = condition,
                .then_branch = then_branch,
                .else_branch = else_branch,
            },
        });
    }

    /// 解析 match 表达式：match scrutinee { arms }
    fn parseMatchExpr(self: *Parser) ParserError!*ast.Expr {
        const match_tok = self.previous();
        try self.rejectParenCondition("match");
        const scrutinee = try self.parseExpr();
        _ = self.expect(.l_brace, "expected '{'") catch {};
        var arms = std.ArrayList(ast.MatchArm).empty;
        try arms.ensureTotalCapacity(self.arena.allocator(), 4);
        while (!self.check(.r_brace) and !self.isAtEnd()) {
            const arm = self.parseMatchArm() catch |err| {
                if (err == error.UnexpectedToken) {
                    while (!self.check(.comma) and !self.check(.r_brace) and !self.isAtEnd()) {
                        _ = self.advance();
                    }
                    if (self.matchToken(.comma)) continue;
                    break;
                }
                return err;
            };
            try arms.append(self.arena.allocator(), arm);
            _ = self.matchToken(.comma);
        }
        _ = self.expect(.r_brace, "expected '}'") catch {};
        return self.allocExpr(tokenLoc(match_tok), ast.Expr{
            .match = .{
                .scrutinee = scrutinee,
                .arms = try arms.toOwnedSlice(self.arena.allocator()),
            },
        });
    }

    /// 解析 match 的单个分支：pattern if guard => body
    fn parseMatchArm(self: *Parser) ParserError!ast.MatchArm {
        const pattern = try self.parsePattern();
        var guard: ?*ast.Expr = null;
        if (self.matchToken(.kw_if)) {
            try self.rejectParenCondition("if guard");
            guard = try self.parseExpr();
        }
        _ = self.expect(.eq_gt, "expected '=>'") catch {};
        // 控制流语句作为分支体时包装为块表达式
        const body = if (self.check(.kw_throw) or self.check(.kw_return) or
            self.check(.kw_break) or self.check(.kw_continue))
        blk: {
            const stmt_tok = self.peek();
            const stmt = try self.parseStmt();
            var stmts = std.ArrayList(*ast.Stmt).empty;
            try stmts.ensureTotalCapacity(self.arena.allocator(), 1);
            try stmts.append(self.arena.allocator(), stmt);
            break :blk try self.allocExpr(tokenLoc(stmt_tok), ast.Expr{
                .block = .{
                    .statements = try stmts.toOwnedSlice(self.arena.allocator()),
                    .trailing_expr = null,
                },
            });
        } else try self.parseExpr();
        return ast.MatchArm{
            .pattern = pattern,
            .guard = guard,
            .body = body,
        };
    }

    /// 解析 lazy 表达式：lazy expr
    fn parseLazyExpr(self: *Parser) ParserError!*ast.Expr {
        const lazy_tok = self.previous();
        const expr = try self.parseExpr();
        return self.allocExpr(tokenLoc(lazy_tok), ast.Expr{
            .lazy = .{
                .expr = expr,
            },
        });
    }

    /// 解析 spawn 表达式：spawn expr（创建异步任务，不自动 await）
    fn parseSpawnExpr(self: *Parser) ParserError!*ast.Expr {
        const spawn_tok = self.previous();
        const expr = try self.parseExpr();
        return self.allocExpr(tokenLoc(spawn_tok), ast.Expr{
            .spawn_expr = .{
                .expr = expr,
            },
        });
    }

    /// 解析 atomic 表达式：atomic value
    fn parseAtomicExpr(self: *Parser) ParserError!*ast.Expr {
        const atomic_tok = self.previous();
        const value_expr = try self.parsePrimary();
        return self.allocExpr(tokenLoc(atomic_tok), ast.Expr{
            .atomic_expr = .{
                .value = value_expr,
            },
        }) catch return error.OutOfMemory;
    }

    /// 解析 select 表达式：select { arms }
    fn parseSelectExpr(self: *Parser) ParserError!*ast.Expr {
        const select_tok = self.previous();
        _ = self.expect(.l_brace, "expected '{'") catch {};
        var arms = std.ArrayList(ast.SelectArm).empty;
        while (!self.check(.r_brace) and !self.isAtEnd()) {
            try arms.append(self.arena.allocator(), try self.parseSelectArm());
            _ = self.matchToken(.comma);
        }
        _ = self.expect(.r_brace, "expected '}'") catch {};
        return self.allocExpr(tokenLoc(select_tok), ast.Expr{
            .select = .{
                .arms = try arms.toOwnedSlice(self.arena.allocator()),
            },
        });
    }

    /// 解析 select 的单个分支：timeout(duration) => body 或 channel => binding => body
    fn parseSelectArm(self: *Parser) ParserError!ast.SelectArm {
        if (self.checkIdentifier("timeout")) {
            const timeout_tok = self.advance();
            _ = self.expect(.l_paren, "expected '('") catch {};
            const duration = try self.parseExpr();
            _ = self.expect(.r_paren, "expected ')'") catch {};
            _ = self.expect(.eq_gt, "expected '=>'") catch {};
            const body = try self.parseExpr();
            return ast.SelectArm{
                .timeout = .{
                    .location = tokenLoc(timeout_tok),
                    .duration = duration,
                    .body = body,
                },
            };
        }
        const channel_expr = try self.parseExpr();
        _ = self.expect(.eq_gt, "expected '=>'") catch {};
        var binding: ?[]const u8 = null;
        if (self.check(.identifier) and
            self.current + 1 < self.tokens.len and
            self.tokens[self.current + 1].type == .eq_gt)
        {
            const name_tok = self.advance();
            _ = self.advance();
            binding = name_tok.lexeme;
        }
        const body = try self.parseExpr();
        return ast.SelectArm{
            .receive = .{
                .location = getExprLocation(channel_expr),
                .channel_expr = channel_expr,
                .binding = binding,
                .body = body,
            },
        };
    }

    /// 解析内联 trait 值：trait { methods }
    fn parseInlineTraitValue(self: *Parser) ParserError!*ast.Expr {
        const trait_tok = self.advance();
        _ = self.expect(.l_brace, "expected '{'") catch {};
        var methods = std.ArrayList(ast.MethodDecl).empty;
        while (!self.check(.r_brace) and !self.isAtEnd()) {
            try methods.append(self.arena.allocator(), try self.parseMethodDecl());
        }
        _ = self.expect(.r_brace, "expected '}'") catch {};
        return self.allocExpr(tokenLoc(trait_tok), ast.Expr{
            .inline_trait_value = .{
                .methods = try methods.toOwnedSlice(self.arena.allocator()),
            },
        });
    }

    /// 解析数组字面量：[e1, e2, ...]
    fn parseArrayLiteral(self: *Parser) ParserError!*ast.Expr {
        const bracket_tok = self.previous();
        var elements = std.ArrayList(*ast.Expr).empty;
        if (!self.check(.r_bracket)) {
            try elements.append(self.arena.allocator(), try self.parseExpr());
            while (self.matchToken(.comma)) {
                if (self.check(.r_bracket)) break;
                try elements.append(self.arena.allocator(), try self.parseExpr());
            }
        }
        _ = self.expect(.r_bracket, "expected ']'") catch {};
        return self.allocExpr(tokenLoc(bracket_tok), ast.Expr{
            .array_literal = .{
                .elements = try elements.toOwnedSlice(self.arena.allocator()),
            },
        });
    }

    /// 解析块表达式：{ statements; trailing_expr? }
    fn parseBlockExpr(self: *Parser) ParserError!*ast.Expr {
        const brace_tok = self.advance();
        const location = tokenLoc(brace_tok);
        var statements = std.ArrayList(*ast.Stmt).empty;
        try statements.ensureTotalCapacity(self.arena.allocator(), 8);
        var trailing_expr: ?*ast.Expr = null;
        while (!self.check(.r_brace) and !self.isAtEnd()) {
            if (self.isStmtStart()) {
                const stmt = self.parseStmt() catch |err| {
                    return err;
                };
                if (stmt.* == .expression and self.check(.r_brace)) {
                    trailing_expr = stmt.expression.expr;
                    break;
                }
                try statements.append(self.arena.allocator(), stmt);
            } else {
                const stmt = self.parseExprOrAssignmentStmt() catch |err| {
                    return err;
                };
                if (stmt.* == .expression and self.check(.r_brace)) {
                    trailing_expr = stmt.expression.expr;
                    break;
                }
                try statements.append(self.arena.allocator(), stmt);
            }
        }
        _ = self.expect(.r_brace, "expected '}'") catch {};
        return self.allocExpr(location, ast.Expr{
            .block = .{
                .statements = try statements.toOwnedSlice(self.arena.allocator()),
                .trailing_expr = trailing_expr,
            },
        });
    }

    /// 解析圆括号表达式：可能是单元值、lambda、记录字面量、记录扩展或普通分组表达式
    fn parseParenOrRecordOrLambda(self: *Parser) ParserError!*ast.Expr {
        const lparen_tok = self.previous();
        const location = tokenLoc(lparen_tok);
        if (self.matchToken(.r_paren)) {
            return self.allocExpr(location, ast.Expr{
                .unit_literal = {},
            });
        }
        const saved = self.current;
        if (self.tryParseLambda(saved, location)) |lambda_expr| {
            return lambda_expr;
        }
        self.current = saved;
        if (self.peek().type == .identifier or self.peek().type == .ellipsis) {
            if (self.peek().type == .ellipsis) {
                // 记录扩展：(...base, field: value)
                _ = self.advance();
                const base_expr = try self.parseExpr();
                var updates = std.ArrayList(ast.RecordFieldExpr).empty;
                while (self.matchToken(.comma)) {
                    if (self.check(.r_paren)) break;
                    const field_name = try self.expect(.identifier, "expected field name");
                    _ = self.expect(.colon, "expected ':'") catch {};
                    const field_value = try self.parseExpr();
                    try updates.append(self.arena.allocator(), .{
                        .name = field_name.lexeme,
                        .value = field_value,
                    });
                }
                _ = self.expect(.r_paren, "expected ')'") catch {};
                return self.allocExpr(location, ast.Expr{
                    .record_extend = .{
                        .base = base_expr,
                        .updates = try updates.toOwnedSlice(self.arena.allocator()),
                    },
                });
            }
            const name_tok = self.advance();
            if (self.check(.colon)) {
                // 记录字面量：(field: value, ...)
                _ = self.advance();
                const value = try self.parseExpr();
                var fields = std.ArrayList(ast.RecordFieldExpr).empty;
                try fields.append(self.arena.allocator(), .{
                    .name = name_tok.lexeme,
                    .value = value,
                });
                while (self.matchToken(.comma)) {
                    if (self.check(.r_paren)) break;
                    if (self.check(.ellipsis)) {
                        // 记录扩展：(field: value, ...base, more: value)
                        _ = self.advance();
                        const base_expr = try self.parseExpr();
                        var updates = std.ArrayList(ast.RecordFieldExpr).empty;
                        for (fields.items) |f| {
                            try updates.append(self.arena.allocator(), f);
                        }
                        while (self.matchToken(.comma)) {
                            if (self.check(.r_paren)) break;
                            const field_name = try self.expect(.identifier, "expected field name");
                            _ = self.expect(.colon, "expected ':'") catch {};
                            const field_value = try self.parseExpr();
                            try updates.append(self.arena.allocator(), .{
                                .name = field_name.lexeme,
                                .value = field_value,
                            });
                        }
                        _ = self.expect(.r_paren, "expected ')'") catch {};
                        return self.allocExpr(location, ast.Expr{
                            .record_extend = .{
                                .base = base_expr,
                                .updates = try updates.toOwnedSlice(self.arena.allocator()),
                            },
                        });
                    }
                    const field_name = try self.expect(.identifier, "expected field name");
                    _ = self.expect(.colon, "expected ':'") catch {};
                    const field_value = try self.parseExpr();
                    try fields.append(self.arena.allocator(), .{
                        .name = field_name.lexeme,
                        .value = field_value,
                    });
                }
                _ = self.expect(.r_paren, "expected ')'") catch {};
                return self.allocExpr(location, ast.Expr{
                    .record_literal = .{
                        .fields = try fields.toOwnedSlice(self.arena.allocator()),
                    },
                });
            }
            self.current = saved;
        }
        const first_expr = try self.parseExpr();
        if (self.matchToken(.comma)) {
            // 匿名元组不被允许，报告错误并跳过剩余
            const loc = tokenLoc(lparen_tok);
            try self.errors.append(self.arena.allocator(), ParseError{
                .line = loc.line,
                .column = loc.column,
                .message = "anonymous tuples are not allowed; use named record fields like (name: value, ...)",
            });
            while (!self.check(.r_paren) and !self.isAtEnd()) {
                _ = self.advance();
            }
            _ = self.matchToken(.r_paren);
            return first_expr;
        }
        _ = self.expect(.r_paren, "expected ')'") catch {};
        return first_expr;
    }

    /// 尝试解析 lambda（(params) => expr），失败时回退
    fn tryParseLambda(self: *Parser, saved: usize, location: ast.SourceLocation) ?*ast.Expr {
        const saved_error_count = self.errors.items.len;
        var params = std.ArrayList(ast.Param).empty;
        if (!self.check(.r_paren)) {
            self.parseLambdaParamList(&params) catch {
                self.errors.shrinkRetainingCapacity(saved_error_count);
                return null;
            };
        }
        if (!self.check(.r_paren)) {
            self.errors.shrinkRetainingCapacity(saved_error_count);
            return null;
        }
        _ = self.advance();
        if (!self.check(.eq_gt)) {
            self.current = saved;
            self.errors.shrinkRetainingCapacity(saved_error_count);
            return null;
        }
        _ = self.advance();
        const body_expr = self.parseExpr() catch return null;
        const body = ast.LambdaBody{ .expression = body_expr };
        return self.allocExpr(location, ast.Expr{
            .lambda = .{
                .params = params.toOwnedSlice(self.arena.allocator()) catch return null,
                .body = body,
            },
        }) catch return null;
    }

    /// 解析 lambda 参数列表（逗号分隔）
    fn parseLambdaParamList(self: *Parser, params: *std.ArrayList(ast.Param)) ParserError!void {
        try params.append(self.arena.allocator(), try self.parseLambdaParam());
        while (self.matchToken(.comma)) {
            if (self.check(.r_paren)) break;
            try params.append(self.arena.allocator(), try self.parseLambdaParam());
        }
    }

    /// 解析单个 lambda 参数：[var|val] name: Type
    fn parseLambdaParam(self: *Parser) ParserError!ast.Param {
        var is_var = false;
        if (self.matchToken(.kw_var)) {
            is_var = true;
        } else {
            _ = self.matchToken(.kw_val);
        }
        const name_tok = try self.expect(.identifier, "expected parameter name");
        var type_annotation: ?*ast.TypeNode = null;
        if (self.matchToken(.colon)) {
            type_annotation = try self.parseType();
        }
        return ast.Param{
            .location = tokenLoc(name_tok),
            .name = name_tok.lexeme,
            .type_annotation = type_annotation,
            .is_var = is_var,
        };
    }

    /// 解析类型转换表达式：BuiltinType(expr)
    fn parseTypeCast(self: *Parser) ParserError!*ast.Expr {
        const name_tok = self.advance();
        const location = tokenLoc(name_tok);
        const target_type = try self.allocType(location, ast.TypeNode{
            .named = .{
                .name = name_tok.lexeme,
            },
        });
        _ = self.expect(.l_paren, "expected '('") catch {};
        const expr = try self.parseExpr();
        _ = self.expect(.r_paren, "expected ')'") catch {};
        return self.allocExpr(location, ast.Expr{
            .type_cast = .{
                .target_type = target_type,
                .expr = expr,
            },
        });
    }

    // ---- 模式解析 ----

    /// 模式解析入口
    fn parsePattern(self: *Parser) ParserError!*ast.Pattern {
        return self.parseOrPattern();
    }

    /// 解析或模式：left | right
    fn parseOrPattern(self: *Parser) ParserError!*ast.Pattern {
        var left = try self.parsePrimaryPattern();
        while (self.matchToken(.pipe)) {
            const pipe_tok = self.previous();
            const right = try self.parsePrimaryPattern();
            left = try self.allocPattern(tokenLoc(pipe_tok), ast.Pattern{
                .or_pattern = .{
                    .left = left,
                    .right = right,
                },
            });
        }
        return left;
    }

    /// 解析基本模式：通配符、字面量、变量、构造器、记录模式
    fn parsePrimaryPattern(self: *Parser) ParserError!*ast.Pattern {
        if (self.check(.identifier) and std.mem.eql(u8, self.peek().lexeme, "_")) {
            const tok = self.advance();
            return self.allocPattern(tokenLoc(tok), ast.Pattern{
                .wildcard = {},
            });
        }
        if (self.matchToken(.null_literal)) {
            const tok = self.previous();
            return self.allocPattern(tokenLoc(tok), ast.Pattern{
                .literal = .{ .null = tokenLoc(tok) },
            });
        }
        if (self.matchToken(.true_literal)) {
            return self.allocPattern(tokenLoc(self.previous()), ast.Pattern{
                .literal = .{ .bool = true },
            });
        }
        if (self.matchToken(.false_literal)) {
            return self.allocPattern(tokenLoc(self.previous()), ast.Pattern{
                .literal = .{ .bool = false },
            });
        }
        if (self.matchToken(.int_literal)) {
            const tok = self.previous();
            return self.allocPattern(tokenLoc(tok), ast.Pattern{
                .literal = .{ .int = tok.lexeme },
            });
        }
        if (self.matchToken(.float_literal)) {
            const tok = self.previous();
            return self.allocPattern(tokenLoc(tok), ast.Pattern{
                .literal = .{ .float = tok.lexeme },
            });
        }
        if (self.matchToken(.char_literal)) {
            const tok = self.previous();
            return self.allocPattern(tokenLoc(tok), ast.Pattern{
                .literal = .{ .char = parseCharValue(tok.lexeme) },
            });
        }
        if (self.matchToken(.string_literal)) {
            const tok = self.previous();
            const value = tok.lexeme[1 .. tok.lexeme.len - 1];
            return self.allocPattern(tokenLoc(tok), ast.Pattern{
                .literal = .{ .string = value },
            });
        }
        if (self.matchToken(.l_paren)) {
            return self.parseRecordPattern();
        }
        if (self.check(.kw_val) or self.check(.kw_var)) {
            const name_tok = self.advance();
            if (self.check(.l_paren)) {
                _ = self.advance();
                var patterns = std.ArrayList(*ast.Pattern).empty;
                if (!self.check(.r_paren)) {
                    try patterns.append(self.arena.allocator(), try self.parsePattern());
                    while (self.matchToken(.comma)) {
                        try patterns.append(self.arena.allocator(), try self.parsePattern());
                    }
                }
                _ = self.expect(.r_paren, "expected ')'") catch {};
                return self.allocPattern(tokenLoc(name_tok), ast.Pattern{
                    .constructor = .{
                        .name = name_tok.lexeme,
                        .patterns = try patterns.toOwnedSlice(self.arena.allocator()),
                    },
                });
            }
            return self.allocPattern(tokenLoc(name_tok), ast.Pattern{
                .variable = .{
                    .name = name_tok.lexeme,
                },
            });
        }
        if (self.check(.identifier)) {
            const name_tok = self.advance();
            if (self.check(.l_paren)) {
                _ = self.advance();
                var patterns = std.ArrayList(*ast.Pattern).empty;
                if (!self.check(.r_paren)) {
                    try patterns.append(self.arena.allocator(), try self.parsePattern());
                    while (self.matchToken(.comma)) {
                        try patterns.append(self.arena.allocator(), try self.parsePattern());
                    }
                }
                _ = self.expect(.r_paren, "expected ')'") catch {};
                return self.allocPattern(tokenLoc(name_tok), ast.Pattern{
                    .constructor = .{
                        .name = name_tok.lexeme,
                        .patterns = try patterns.toOwnedSlice(self.arena.allocator()),
                    },
                });
            }
            return self.allocPattern(tokenLoc(name_tok), ast.Pattern{
                .variable = .{
                    .name = name_tok.lexeme,
                },
            });
        }
        try self.reportError("expected pattern");
        return error.UnexpectedToken;
    }

    /// 解析记录模式：(field: pattern, ...) 或位置模式 (p0, p1, ...)
    fn parseRecordPattern(self: *Parser) ParserError!*ast.Pattern {
        const lparen = self.previous();
        const location = tokenLoc(lparen);
        var fields = std.ArrayList(ast.PatternRecordField).empty;
        if (!self.check(.r_paren)) {
            if (self.peek().type == .identifier) {
                const saved = self.current;
                const name_tok = self.advance();
                if (self.check(.colon)) {
                    // 命名字段模式
                    _ = self.advance();
                    const pattern = try self.parsePattern();
                    try fields.append(self.arena.allocator(), .{
                        .name = name_tok.lexeme,
                        .pattern = pattern,
                    });
                    while (self.matchToken(.comma)) {
                        if (self.check(.r_paren)) break;
                        const field_name = try self.expect(.identifier, "expected field name");
                        _ = self.expect(.colon, "expected ':'") catch {};
                        const field_pattern = try self.parsePattern();
                        try fields.append(self.arena.allocator(), .{
                            .name = field_name.lexeme,
                            .pattern = field_pattern,
                        });
                    }
                    _ = self.expect(.r_paren, "expected ')'") catch {};
                    return self.allocPattern(location, ast.Pattern{
                        .record = .{
                            .fields = try fields.toOwnedSlice(self.arena.allocator()),
                        },
                    });
                }
                self.current = saved;
            }
            // 位置模式：用数字字符串作为字段名
            const first_pattern = try self.parsePattern();
            const key0 = try self.arena.allocator().dupe(u8, "0");
            try fields.append(self.arena.allocator(), .{
                .name = key0,
                .pattern = first_pattern,
            });
            var idx: usize = 1;
            while (self.matchToken(.comma)) {
                if (self.check(.r_paren)) break;
                const next_pattern = try self.parsePattern();
                const k = try intToKey(self.arena.allocator(), idx);
                try fields.append(self.arena.allocator(), .{
                    .name = k,
                    .pattern = next_pattern,
                });
                idx += 1;
            }
        }
        _ = self.expect(.r_paren, "expected ')'") catch {};
        return self.allocPattern(location, ast.Pattern{
            .record = .{
                .fields = try fields.toOwnedSlice(self.arena.allocator()),
            },
        });
    }

    // ---- 语句解析 ----

    /// 当前 Token 是否为语句起始关键字
    fn isStmtStart(self: *Parser) bool {
        return switch (self.peek().type) {
            .kw_val,
            .kw_var,
            .kw_fun,
            .kw_return,
            .kw_defer,
            .kw_throw,
            .kw_break,
            .kw_continue,
            .kw_for,
            .kw_while,
            .kw_loop,
            => true,
            else => false,
        };
    }

    /// 语句解析入口：根据关键字分派
    fn parseStmt(self: *Parser) ParserError!*ast.Stmt {
        if (self.matchToken(.kw_val)) {
            return self.parseValDecl();
        }
        if (self.matchToken(.kw_var)) {
            return self.parseVarDecl();
        }
        if (self.matchToken(.kw_fun)) {
            return self.parseFunStmt();
        }
        if (self.matchToken(.kw_return)) {
            return self.parseReturnStmt();
        }
        if (self.matchToken(.kw_defer)) {
            return self.parseDeferStmt();
        }
        if (self.matchToken(.kw_throw)) {
            return self.parseThrowStmt();
        }
        if (self.matchToken(.kw_break)) {
            const tok = self.previous();
            return self.allocStmt(tokenLoc(tok), ast.Stmt{
                .break_stmt = .{ },
            });
        }
        if (self.matchToken(.kw_continue)) {
            const tok = self.previous();
            return self.allocStmt(tokenLoc(tok), ast.Stmt{
                .continue_stmt = .{ },
            });
        }
        if (self.matchToken(.kw_for)) {
            return self.parseForStmt();
        }
        if (self.matchToken(.kw_while)) {
            return self.parseWhileStmt();
        }
        if (self.matchToken(.kw_loop)) {
            return self.parseLoopStmt();
        }
        return self.parseExprOrAssignmentStmt();
    }

    /// 解析 fun 语句：具名时作为 val 绑定 lambda，匿名时作为表达式语句
    fn parseFunStmt(self: *Parser) ParserError!*ast.Stmt {
        const fun_tok = self.previous();
        if (self.check(.identifier) and !self.checkIdentifier("in")) {
            const name_tok = self.advance();
            var params = std.ArrayList(ast.Param).empty;
            _ = self.expect(.l_paren, "expected '('") catch {};
            if (!self.check(.r_paren)) {
                try self.parseParamList(&params);
            }
            _ = self.expect(.r_paren, "expected ')'") catch {};
            var return_type: ?*ast.TypeNode = null;
            if (self.matchToken(.colon)) {
                return_type = try self.parseType();
            }
            const body_expr = try self.parseExpr();
            const body = ast.LambdaBody{ .block = body_expr };
            const lambda_expr = try self.allocExpr(tokenLoc(fun_tok), ast.Expr{
                .lambda = .{
                    .params = try params.toOwnedSlice(self.arena.allocator()),
                    .body = body,
                    .return_type = return_type,
                },
            });
            return self.allocStmt(tokenLoc(fun_tok), ast.Stmt{
                .val_decl = .{
                    .name = name_tok.lexeme,
                    .type_annotation = null,
                    .value = lambda_expr,
                },
            });
        }
        var params = std.ArrayList(ast.Param).empty;
        _ = self.expect(.l_paren, "expected '('") catch {};
        if (!self.check(.r_paren)) {
            try self.parseParamList(&params);
        }
        _ = self.expect(.r_paren, "expected ')'") catch {};
        const body_expr = try self.parseExpr();
        const body = ast.LambdaBody{ .block = body_expr };
        const lambda_expr = try self.allocExpr(tokenLoc(fun_tok), ast.Expr{
            .lambda = .{
                .params = try params.toOwnedSlice(self.arena.allocator()),
                .body = body,
            },
        });
        return self.allocStmt(tokenLoc(fun_tok), ast.Stmt{
            .expression = .{
                .expr = lambda_expr,
            },
        });
    }

    /// 解析 val 声明：val name: Type = value
    fn parseValDecl(self: *Parser) ParserError!*ast.Stmt {
        const val_tok = self.previous();
        const name_tok = try self.expect(.identifier, "expected variable name");
        var type_annotation: ?*ast.TypeNode = null;
        if (self.matchToken(.colon)) {
            type_annotation = try self.parseType();
        }
        _ = self.expect(.eq, "expected '='") catch {};
        const value = try self.parseExpr();
        return self.allocStmt(tokenLoc(val_tok), ast.Stmt{
            .val_decl = .{
                .name = name_tok.lexeme,
                .type_annotation = type_annotation,
                .value = value,
            },
        });
    }

    /// 解析 var 声明：var name: Type = value
    fn parseVarDecl(self: *Parser) ParserError!*ast.Stmt {
        const var_tok = self.previous();
        const name_tok = try self.expect(.identifier, "expected variable name");
        var type_annotation: ?*ast.TypeNode = null;
        if (self.matchToken(.colon)) {
            type_annotation = try self.parseType();
        }
        _ = self.expect(.eq, "expected '='") catch {};
        const value = try self.parseExpr();
        return self.allocStmt(tokenLoc(var_tok), ast.Stmt{
            .var_decl = .{
                .name = name_tok.lexeme,
                .type_annotation = type_annotation,
                .value = value,
            },
        });
    }

    /// 解析 return 语句：return expr?
    fn parseReturnStmt(self: *Parser) ParserError!*ast.Stmt {
        const return_tok = self.previous();
        var value: ?*ast.Expr = null;
        if (!self.check(.r_brace) and !self.isStmtStart() and !self.isAtEnd()) {
            value = try self.parseExpr();
        }
        return self.allocStmt(tokenLoc(return_tok), ast.Stmt{
            .return_stmt = .{
                .value = value,
            },
        });
    }

    /// 解析 defer 语句：defer expr 或 defer target = value
    fn parseDeferStmt(self: *Parser) ParserError!*ast.Stmt {
        const defer_tok = self.previous();
        const expr = try self.parseExpr();
        if (self.matchToken(.eq)) {
            const value = try self.parseExpr();
            const assign_expr = try self.allocExpr(getExprLocation(expr), ast.Expr{
                .assignment_expr = .{
                    .target = expr,
                    .value = value,
                },
            });
            return self.allocStmt(tokenLoc(defer_tok), ast.Stmt{
                .defer_stmt = .{
                    .expr = assign_expr,
                },
            });
        }
        return self.allocStmt(tokenLoc(defer_tok), ast.Stmt{
            .defer_stmt = .{
                .expr = expr,
            },
        });
    }

    /// 解析 throw 语句：throw expr
    fn parseThrowStmt(self: *Parser) ParserError!*ast.Stmt {
        const throw_tok = self.previous();
        const expr = try self.parseExpr();
        return self.allocStmt(tokenLoc(throw_tok), ast.Stmt{
            .throw_stmt = .{
                .expr = expr,
            },
        });
    }

    /// 解析 for 语句：for name in iterable body
    fn parseForStmt(self: *Parser) ParserError!*ast.Stmt {
        const for_tok = self.previous();
        const name_tok = try self.expect(.identifier, "expected iterator variable name");
        _ = self.expect(.kw_in, "expected 'in'") catch {};
        try self.rejectParenCondition("for");
        const iterable = try self.parseExpr();
        const body = try self.parseExpr();
        return self.allocStmt(tokenLoc(for_tok), ast.Stmt{
            .for_stmt = .{
                .name = name_tok.lexeme,
                .iterable = iterable,
                .body = body,
            },
        });
    }

    /// 解析 while 语句：while condition body
    fn parseWhileStmt(self: *Parser) ParserError!*ast.Stmt {
        const while_tok = self.previous();
        try self.rejectParenCondition("while");
        const condition = try self.parseExpr();
        const body = try self.parseExpr();
        return self.allocStmt(tokenLoc(while_tok), ast.Stmt{
            .while_stmt = .{
                .condition = condition,
                .body = body,
            },
        });
    }

    /// 解析 loop 语句：loop body
    fn parseLoopStmt(self: *Parser) ParserError!*ast.Stmt {
        const loop_tok = self.previous();
        const body = try self.parseExpr();
        return self.allocStmt(tokenLoc(loop_tok), ast.Stmt{
            .loop_stmt = .{
                .body = body,
            },
        });
    }

    /// 解析表达式语句或赋值语句（含复合赋值）
    fn parseExprOrAssignmentStmt(self: *Parser) ParserError!*ast.Stmt {
        const expr = try self.parseExpr();
        if (self.matchToken(.eq)) {
            const eq_tok = self.previous();
            const value = try self.parseExpr();
            switch (expr.*) {
                .identifier => {
                    return self.allocStmt(getExprLocation(expr), ast.Stmt{
                        .assignment = .{
                            .target = expr,
                            .value = value,
                        },
                    });
                },
                .field_access => |fa| {
                    return self.allocStmt(tokenLoc(eq_tok), ast.Stmt{
                        .field_assignment = .{
                            .object = fa.object,
                            .field = fa.field,
                            .value = value,
                        },
                    });
                },
                else => {
                    return self.allocStmt(tokenLoc(eq_tok), ast.Stmt{
                        .assignment = .{
                            .target = expr,
                            .value = value,
                        },
                    });
                },
            }
        }
        const compound_op = self.peekCompoundAssign();
        if (compound_op != null) {
            _ = self.advance();
            const op_tok = self.previous();
            const value = try self.parseExpr();
            const op = compound_op.?;
            return self.allocStmt(tokenLoc(op_tok), ast.Stmt{
                .compound_assignment = .{
                    .target = expr,
                    .op = op,
                    .value = value,
                },
            });
        }
        return self.allocStmt(getExprLocation(expr), ast.Stmt{
            .expression = .{
                .expr = expr,
            },
        });
    }

    /// 查看当前 Token 是否为复合赋值运算符，返回对应枚举
    fn peekCompoundAssign(self: *Parser) ?ast.CompoundAssignOp {
        const tok_type = self.peek().type;
        return switch (tok_type) {
            .plus_eq => .add_assign,
            .minus_eq => .sub_assign,
            .star_eq => .mul_assign,
            .slash_eq => .div_assign,
            .percent_eq => .mod_assign,
            .amp_eq => .bit_and_assign,
            .pipe_eq => .bit_or_assign,
            .caret_eq => .bit_xor_assign,
            .lt_lt_eq => .shl_assign,
            .gt_gt_eq => .shr_assign,
            else => null,
        };
    }
};

// ---- 模块级辅助函数 ----

/// 从 Token 提取源码位置
fn tokenLoc(token: lexer.Token) ast.SourceLocation {
    return ast.SourceLocation{
        .line = token.line,
        .column = token.column,
    };
}

/// 返回类型节点的源码位置
fn getTypeNodeLocation(ty: *const ast.TypeNode) ast.SourceLocation {
    return ast.typeNodeLocation(ty);
}

/// 返回表达式的源码位置（委托给 ast.exprLocation）
fn getExprLocation(expr: *const ast.Expr) ast.SourceLocation {
    return ast.exprLocation(expr);
}

/// 判断名称是否为内置类型（整数、浮点、布尔、字符、字符串）
fn isBuiltinType(name: []const u8) bool {
    const builtin_types = [_][]const u8{
        "i8",   "i16",  "i32",  "i64",  "i128",
        "u8",   "u16",  "u32",  "u64",  "u128",
        "f16",  "f32",  "f64",  "f128",
        "bool", "char", "str",
    };
    for (builtin_types) |bt| {
        if (std.mem.eql(u8, name, bt)) return true;
    }
    return false;
}

/// 解析字符字面量的实际码点值，处理转义序列
fn parseCharValue(lexeme: []const u8) u21 {
    if (lexeme.len < 3) return 0;
    const content = lexeme[1 .. lexeme.len - 1];
    if (content.len == 0) return 0;
    if (content[0] == '\\') {
        if (content.len < 2) return 0;
        switch (content[1]) {
            'n' => return '\n',
            't' => return '\t',
            'r' => return '\r',
            '\\' => return '\\',
            '\'' => return '\'',
            '0' => return 0,
            else => return @intCast(content[1]),
        }
    }
    return @intCast(content[0]);
}

/// 判断字符串字面量是否包含插值表达式（未转义的 { ）
fn containsInterpolation(raw: []const u8) bool {
    if (raw.len < 2) return false;
    var i: usize = 1;
    while (i < raw.len - 1) {
        if (raw[i] == '\\') {
            i += 2;
            continue;
        }
        if (raw[i] == '{') {
            if (i + 1 < raw.len - 1 and raw[i + 1] == '{') {
                i += 2;
                continue;
            }
            return true;
        }
        i += 1;
    }
    return false;
}

/// 将索引转换为字符串键（用于位置模式的字段名）
fn intToKey(allocator: std.mem.Allocator, idx: usize) ![]const u8 {
    var buf: [16]u8 = undefined;
    var len: usize = 0;
    var n = idx;
    if (n == 0) {
        buf[0] = '0';
        len = 1;
    } else {
        var tmp: [16]u8 = undefined;
        var tmp_len: usize = 0;
        while (n > 0) {
            tmp[tmp_len] = @intCast('0' + (n % 10));
            tmp_len += 1;
            n /= 10;
        }
        var i: usize = 0;
        while (i < tmp_len) : (i += 1) {
            buf[i] = tmp[tmp_len - 1 - i];
        }
        len = tmp_len;
    }
    return allocator.dupe(u8, buf[0..len]);
}

/// 判断字符是否为数字或下划线
fn isDigitOrUnderscore(ch: u8) bool {
    return (ch >= '0' and ch <= '9') or ch == '_';
}

/// 判断字符是否为十六进制数字或下划线
fn isHexOrUnderscore(ch: u8) bool {
    return isDigitOrUnderscore(ch) or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F');
}
