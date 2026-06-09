//! Glue 语言递归下降语法分析器
//!
//! 将 Token 流转换为 AST，支持：
//! - 完整的运算符优先级解析
//! - 顶层声明（fun/type/trait/impl/use/pack）
//! - 表达式（字面量、二元/一元/后缀运算、Lambda、if/match/spawn/lazy/select 等）
//! - 语句（val/var/赋值/return/defer/throw/break/continue/for/while/loop）
//! - 类型注解和模式
//! - 错误恢复

const std = @import("std");
const lexer = @import("lexer");
const ast = @import("ast");

// ============================================================
// 解析错误
// ============================================================

/// 解析错误信息
pub const ParseError = struct {
    /// 错误位置
    line: u32,
    column: u32,
    /// 错误消息
    message: []const u8,
};

/// 解析器可能返回的错误集（用于打破互相递归函数的依赖循环）
const ParserError = error{ OutOfMemory, UnexpectedToken };

// ============================================================
// Parser
// ============================================================

pub const Parser = struct {
    tokens: []const lexer.Token,
    current: usize,
    allocator: std.mem.Allocator,
    errors: std.ArrayList(ParseError),
    allocated_exprs: std.ArrayList(*ast.Expr),
    allocated_stmts: std.ArrayList(*ast.Stmt),
    allocated_types: std.ArrayList(*ast.TypeNode),
    allocated_patterns: std.ArrayList(*ast.Pattern),
    allocated_kinds: std.ArrayList(*ast.Kind),

    /// 初始化解析器
    pub fn init(allocator: std.mem.Allocator, tokens: []const lexer.Token) Parser {
        return Parser{
            .tokens = tokens,
            .current = 0,
            .allocator = allocator,
            .errors = .empty,
            .allocated_exprs = .empty,
            .allocated_stmts = .empty,
            .allocated_types = .empty,
            .allocated_patterns = .empty,
            .allocated_kinds = .empty,
        };
    }

    /// 释放解析器资源
    pub fn deinit(self: *Parser) void {
        self.errors.deinit(self.allocator);
        for (self.allocated_exprs.items) |ptr| {
            self.allocator.destroy(ptr);
        }
        self.allocated_exprs.deinit(self.allocator);
        for (self.allocated_stmts.items) |ptr| {
            self.allocator.destroy(ptr);
        }
        self.allocated_stmts.deinit(self.allocator);
        for (self.allocated_types.items) |ptr| {
            self.allocator.destroy(ptr);
        }
        self.allocated_types.deinit(self.allocator);
        for (self.allocated_patterns.items) |ptr| {
            self.allocator.destroy(ptr);
        }
        self.allocated_patterns.deinit(self.allocator);
        for (self.allocated_kinds.items) |ptr| {
            self.allocator.destroy(ptr);
        }
        self.allocated_kinds.deinit(self.allocator);
    }

    // --------------------------------------------------------
    // 导航辅助方法
    // --------------------------------------------------------

    /// 当前 token
    fn peek(self: *Parser) lexer.Token {
        if (self.current >= self.tokens.len) {
            return self.tokens[self.tokens.len - 1]; // EOF
        }
        return self.tokens[self.current];
    }

    /// 上一个 token
    fn previous(self: *Parser) lexer.Token {
        std.debug.assert(self.current > 0);
        return self.tokens[self.current - 1];
    }

    /// 是否到达末尾
    pub fn isAtEnd(self: *Parser) bool {
        return self.peek().type == .eof;
    }

    /// 前进一个 token，返回被消费的 token
    fn advance(self: *Parser) lexer.Token {
        if (!self.isAtEnd()) {
            self.current += 1;
        }
        return self.previous();
    }

    /// 检查当前 token 类型
    fn check(self: *Parser, token_type: lexer.TokenType) bool {
        if (self.isAtEnd()) return false;
        return self.peek().type == token_type;
    }

    /// 如果当前 token 匹配则前进，返回是否匹配
    fn matchToken(self: *Parser, token_type: lexer.TokenType) bool {
        if (self.check(token_type)) {
            _ = self.advance();
            return true;
        }
        return false;
    }

    /// 期望特定 token，不匹配则报错
    fn expect(self: *Parser, token_type: lexer.TokenType, message: []const u8) ParserError!lexer.Token {
        if (self.check(token_type)) {
            return self.advance();
        }
        const tok = self.peek();
        try self.errors.append(self.allocator, ParseError{
            .line = tok.line,
            .column = tok.column,
            .message = message,
        });
        return error.UnexpectedToken;
    }

    /// 报告错误
    fn reportError(self: *Parser, message: []const u8) ParserError!void {
        const tok = self.peek();
        try self.errors.append(self.allocator, ParseError{
            .line = tok.line,
            .column = tok.column,
            .message = message,
        });
    }

    /// 错误恢复：跳到同步点
    fn synchronize(self: *Parser) void {
        while (!self.isAtEnd()) {
            switch (self.peek().type) {
                .kw_fun,
                .kw_type,
                .kw_trait,
                .kw_impl,
                .kw_use,
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

    /// 检查当前 token 是否为标识符且词素匹配
    fn checkIdentifier(self: *Parser, name: []const u8) bool {
        if (self.peek().type != .identifier) return false;
        return std.mem.eql(u8, self.peek().lexeme, name);
    }

    // --------------------------------------------------------
    // AST 节点分配辅助
    // --------------------------------------------------------

    fn allocExpr(self: *Parser, expr: ast.Expr) ParserError!*ast.Expr {
        const ptr = try self.allocator.create(ast.Expr);
        ptr.* = expr;
        self.allocated_exprs.append(self.allocator, ptr) catch {};
        return ptr;
    }

    fn allocStmt(self: *Parser, stmt: ast.Stmt) ParserError!*ast.Stmt {
        const ptr = try self.allocator.create(ast.Stmt);
        ptr.* = stmt;
        self.allocated_stmts.append(self.allocator, ptr) catch {};
        return ptr;
    }

    fn allocType(self: *Parser, ty: ast.TypeNode) ParserError!*ast.TypeNode {
        const ptr = try self.allocator.create(ast.TypeNode);
        ptr.* = ty;
        self.allocated_types.append(self.allocator, ptr) catch {};
        return ptr;
    }

    fn allocPattern(self: *Parser, pat: ast.Pattern) ParserError!*ast.Pattern {
        const ptr = try self.allocator.create(ast.Pattern);
        ptr.* = pat;
        self.allocated_patterns.append(self.allocator, ptr) catch {};
        return ptr;
    }

    fn allocKind(self: *Parser, kind: ast.Kind) ParserError!*ast.Kind {
        const ptr = try self.allocator.create(ast.Kind);
        ptr.* = kind;
        self.allocated_kinds.append(self.allocator, ptr) catch {};
        return ptr;
    }

    // ============================================================
    // 模块解析
    // ============================================================

    /// 解析整个模块
    pub fn parseModule(self: *Parser, module_name: []const u8) ParserError!ast.Module {
        var declarations = std.ArrayList(ast.Decl).empty;
        errdefer declarations.deinit(self.allocator);

        while (!self.isAtEnd()) {
            // 先尝试解析为声明
            if (self.tryParseDecl()) |decl| {
                try declarations.append(self.allocator, decl);
                continue;
            }

            // 声明解析失败，尝试解析为顶层表达式或赋值语句
            const expr = self.parseExpr() catch |err| {
                if (err == error.UnexpectedToken) {
                    self.synchronize();
                    continue;
                }
                return err;
            };

            // 检查是否是赋值语句（identifier = expr）
            if (self.matchToken(.eq)) {
                const value = self.parseExpr() catch |err| {
                    if (err == error.UnexpectedToken) {
                        self.synchronize();
                        continue;
                    }
                    return err;
                };
                // 包装为赋值语句的表达式声明
                const stmt = try self.allocStmt(ast.Stmt{
                    .assignment = .{
                        .location = getExprLocation(expr),
                        .target = expr,
                        .value = value,
                    },
                });
                try declarations.append(self.allocator, ast.Decl{
                    .expr_decl = .{
                        .location = getExprLocation(expr),
                        .expr = expr,
                        .stmt = stmt,
                    },
                });
            } else {
                // 将表达式包装为表达式声明
                try declarations.append(self.allocator, ast.Decl{
                    .expr_decl = .{
                        .location = getExprLocation(expr),
                        .expr = expr,
                    },
                });
            }
        }

        return ast.Module{
            .name = module_name,
            .source_path = null,
            .declarations = try declarations.toOwnedSlice(self.allocator),
        };
    }

    /// 尝试解析顶层声明，失败返回 null
    fn tryParseDecl(self: *Parser) ?ast.Decl {
        var visibility: ast.Visibility = .private;
        if (self.matchToken(.kw_pub)) {
            visibility = .public;
        }

        if (self.check(.kw_fun)) {
            return self.parseFunDecl(visibility) catch return null;
        }
        if (self.check(.kw_type)) {
            return self.parseTypeDecl(visibility) catch return null;
        }
        if (self.check(.kw_trait)) {
            return self.parseTraitDecl(visibility) catch return null;
        }
        if (self.check(.kw_impl)) {
            return self.parseImplDecl(visibility) catch return null;
        }
        if (self.check(.kw_use)) {
            return self.parseUseDecl(visibility) catch return null;
        }
        if (self.check(.kw_pack)) {
            return self.parsePackDecl(visibility) catch return null;
        }

        // 支持 pub val / pub var 作为顶层声明
        if (visibility == .public and (self.check(.kw_val) or self.check(.kw_var))) {
            const stmt = self.parseStmt() catch return null;
            // 将 visibility 注入到 val_decl/var_decl 中
            switch (stmt.*) {
                .val_decl => |*vd| vd.visibility = visibility,
                .var_decl => |*vd| vd.visibility = visibility,
                else => {},
            }
            const dummy = self.allocExpr(ast.Expr{
                .unit_literal = stmt.getLocation(),
            }) catch return null;
            return ast.Decl{
                .expr_decl = .{
                    .location = stmt.getLocation(),
                    .expr = dummy,
                    .stmt = stmt,
                },
            };
        }

        // 如果消费了 pub 但后面不是声明关键字，回退
        if (visibility == .public) {
            self.current -= 1;
        }

        // 支持 val/var/for/while/loop/defer/throw/return 作为顶层语句
        if (self.check(.kw_val) or self.check(.kw_var) or
            self.check(.kw_for) or self.check(.kw_while) or
            self.check(.kw_loop) or self.check(.kw_defer) or
            self.check(.kw_throw) or self.check(.kw_return))
        {
            const stmt = self.parseStmt() catch return null;
            // 创建一个空的 dummy 表达式
            const dummy = self.allocExpr(ast.Expr{
                .unit_literal = stmt.getLocation(),
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

    // ============================================================
    // 顶层声明解析
    // ============================================================

    /// 解析顶层声明
    pub fn parseDecl(self: *Parser) ParserError!ast.Decl {
        var visibility: ast.Visibility = .private;
        if (self.matchToken(.kw_pub)) {
            visibility = .public;
        }

        if (self.check(.kw_fun)) {
            return self.parseFunDecl(visibility);
        }
        if (self.check(.kw_type)) {
            return self.parseTypeDecl(visibility);
        }
        if (self.check(.kw_trait)) {
            return self.parseTraitDecl(visibility);
        }
        if (self.check(.kw_impl)) {
            return self.parseImplDecl(visibility);
        }
        if (self.check(.kw_use)) {
            return self.parseUseDecl(visibility);
        }
        if (self.check(.kw_pack)) {
            return self.parsePackDecl(visibility);
        }

        // 支持 pub val / pub var 作为顶层声明
        if (visibility == .public and (self.check(.kw_val) or self.check(.kw_var))) {
            const stmt = try self.parseStmt();
            switch (stmt.*) {
                .val_decl => |*vd| vd.visibility = visibility,
                .var_decl => |*vd| vd.visibility = visibility,
                else => {},
            }
            const dummy = try self.allocExpr(ast.Expr{
                .unit_literal = stmt.getLocation(),
            });
            return ast.Decl{
                .expr_decl = .{
                    .location = stmt.getLocation(),
                    .expr = dummy,
                    .stmt = stmt,
                },
            };
        }

        try self.reportError("期望顶层声明（fun/type/trait/impl/use/pack/val/var）");
        return error.UnexpectedToken;
    }

    /// 解析函数声明：fun name<T>(params) : ReturnType with Bounds { body }
    fn parseFunDecl(self: *Parser, visibility: ast.Visibility) ParserError!ast.Decl {
        const fun_tok = self.advance(); // 消费 fun
        const name_tok = try self.expect(.identifier, "期望函数名");

        // 类型参数
        var type_params = std.ArrayList(ast.TypeParam).empty;
        if (self.matchToken(.lt)) {
            try self.parseTypeParamList(&type_params);
            _ = self.expect(.gt, "期望 '>' 关闭类型参数列表") catch {};
        }

        // 参数列表
        var params = std.ArrayList(ast.Param).empty;
        _ = self.expect(.l_paren, "期望 '(' 开始参数列表") catch {};
        if (!self.check(.r_paren)) {
            try self.parseParamList(&params);
        }
        _ = self.expect(.r_paren, "期望 ')' 关闭参数列表") catch {};

        // 返回类型
        var return_type: ?*ast.TypeNode = null;
        if (self.matchToken(.colon)) {
            return_type = try self.parseType();
        }

        // Trait 约束 with Bounds
        var bounds = std.ArrayList(ast.TraitBound).empty;
        if (self.matchToken(.kw_with)) {
            try self.parseTraitBoundList(&bounds);
        }

        // 函数体
        const body = try self.parseExpr();

        return ast.Decl{
            .fun_decl = .{
                .location = tokenLoc(fun_tok),
                .visibility = visibility,
                .name = name_tok.lexeme,
                .type_params = try type_params.toOwnedSlice(self.allocator),
                .params = try params.toOwnedSlice(self.allocator),
                .return_type = return_type,
                .bounds = try bounds.toOwnedSlice(self.allocator),
                .body = body,
            },
        };
    }

    /// 解析类型声明：type Name<T> = ...
    fn parseTypeDecl(self: *Parser, visibility: ast.Visibility) ParserError!ast.Decl {
        const type_tok = self.advance(); // 消费 type
        const name_tok = try self.expect(.identifier, "期望类型名");

        // 类型参数
        var type_params = std.ArrayList(ast.TypeParam).empty;
        if (self.matchToken(.lt)) {
            try self.parseTypeParamList(&type_params);
            _ = self.expect(.gt, "期望 '>' 关闭类型参数列表") catch {};
        }

        _ = self.expect(.eq, "期望 '=' 定义类型体") catch {};

        var def = try self.parseTypeDef();

        // 修正 error_newtype 的 name：文档语法 type FileError = Error("msg")
        // 中 FileError 才是类型名，Error("msg") 只是定义体
        if (def == .error_newtype) {
            def.error_newtype.name = name_tok.lexeme;
        }

        return ast.Decl{
            .type_decl = .{
                .location = tokenLoc(type_tok),
                .visibility = visibility,
                .name = name_tok.lexeme,
                .type_params = try type_params.toOwnedSlice(self.allocator),
                .def = def,
            },
        };
    }

    /// 解析类型定义体
    fn parseTypeDef(self: *Parser) ParserError!ast.TypeDef {
        // 检查 ADT：以 | 开头
        if (self.matchToken(.pipe)) {
            return self.parseAdtBody();
        }

        // 检查记录类型：(name: Type, ...)
        if (self.check(.l_paren)) {
            const saved = self.current;
            if (self.tryParseRecordTypeDef()) |def| {
                return def;
            }
            self.current = saved;
        }

        // 检查 error newtype：Error("message")
        if (self.checkIdentifier("Error")) {
            const saved = self.current;
            if (self.tryParseErrorNewtype()) |def| {
                return def;
            }
            self.current = saved;
        }

        // 检查单构造器 ADT：Name(field: Type, ...) 或 Name(Type, ...)
        // type Pair = Pair(first: i32, second: i32)
        // type Handle = Handle(i32)
        if (self.check(.identifier)) {
            const saved = self.current;
            if (self.tryParseSingleCtorAdt()) |def| {
                return def;
            }
            self.current = saved;
        }

        // 类型别名：target_type
        const target = try self.parseType();
        return ast.TypeDef{ .alias = .{ .target = target } };
    }

    /// 尝试解析单构造器 ADT：Name(field: Type, ...) 或 Name(Type)
    /// type Pair = Pair(first: i32, second: i32)
    /// type Handle = Handle(i32)
    fn tryParseSingleCtorAdt(self: *Parser) ?ast.TypeDef {
        const name_tok = self.advance(); // 消费构造器名
        if (!self.check(.l_paren)) return null;
        _ = self.advance(); // 消费 (

        // 检查空构造器：Name()
        if (self.check(.r_paren)) {
            _ = self.advance();
            const ctors = self.allocator.alloc(ast.ConstructorDef, 1) catch return null;
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

        // 检查是否有命名字段：Name(field: Type, ...)
        // 通过看第一个标识符后是否跟着冒号来判断
        if (self.check(.identifier) and self.current + 1 < self.tokens.len and self.tokens[self.current + 1].type == .colon) {
            // 有命名字段 — 解析为 ADT 构造器
            var fields = std.ArrayList(ast.ConstructorField).empty;
            self.parseConstructorFieldList(&fields) catch {
                fields.deinit(self.allocator);
                return null;
            };
            _ = self.expect(.r_paren, "期望 ')' 关闭构造器字段") catch {
                fields.deinit(self.allocator);
                return null;
            };
            const ctors = self.allocator.alloc(ast.ConstructorDef, 1) catch return null;
            ctors[0] = .{
                .location = tokenLoc(name_tok),
                .name = name_tok.lexeme,
                .fields = fields.toOwnedSlice(self.allocator) catch return null,
                .return_type = null,
            };
            return ast.TypeDef{
                .adt = .{ .constructors = ctors },
            };
        }

        // 位置参数 — 解析类型列表
        // 单个位置参数：Name(Type) → newtype
        // 多个位置参数：Name(Type, Type, ...) → ADT 构造器
        const first_type = self.parseType() catch return null;

        if (self.check(.comma)) {
            // 多个位置参数 — 解析为 ADT 构造器
            // Name(Type1, Type2, ...)
            var fields = std.ArrayList(ast.ConstructorField).empty;
            fields.append(self.allocator, .{
                .name = null,
                .ty = first_type,
            }) catch return null;
            while (self.matchToken(.comma)) {
                const ty = self.parseType() catch {
                    fields.deinit(self.allocator);
                    return null;
                };
                fields.append(self.allocator, .{
                    .name = null,
                    .ty = ty,
                }) catch {
                    fields.deinit(self.allocator);
                    return null;
                };
            }
            _ = self.expect(.r_paren, "期望 ')' 关闭构造器字段") catch {
                fields.deinit(self.allocator);
                return null;
            };
            const ctors = self.allocator.alloc(ast.ConstructorDef, 1) catch return null;
            ctors[0] = .{
                .location = tokenLoc(name_tok),
                .name = name_tok.lexeme,
                .fields = fields.toOwnedSlice(self.allocator) catch return null,
                .return_type = null,
            };
            return ast.TypeDef{
                .adt = .{ .constructors = ctors },
            };
        }

        // 单个位置参数 — 解析为 newtype：Name(Type)
        _ = self.expect(.r_paren, "期望 ')'") catch return null;
        return ast.TypeDef{ .newtype = .{
            .name = name_tok.lexeme,
            .inner = first_type,
        } };
    }

    /// 尝试解析记录类型定义
    fn tryParseRecordTypeDef(self: *Parser) ?ast.TypeDef {
        _ = self.advance(); // 消费 (
        if (self.peek().type == .identifier) {
            const name = self.advance();
            if (self.check(.colon)) {
                _ = self.advance(); // 消费 :
                const ty = self.parseType() catch return null;
                var fields = std.ArrayList(ast.RecordFieldType).empty;
                fields.append(self.allocator, .{
                    .name = name.lexeme,
                    .ty = ty,
                }) catch return null;

                while (self.matchToken(.comma)) {
                    const field_name = self.expect(.identifier, "期望字段名") catch return null;
                    _ = self.expect(.colon, "期望 ':'") catch return null;
                    const field_ty = self.parseType() catch return null;
                    fields.append(self.allocator, .{
                        .name = field_name.lexeme,
                        .ty = field_ty,
                    }) catch return null;
                }
                _ = self.expect(.r_paren, "期望 ')'") catch return null;
                return ast.TypeDef{
                    .record = .{ .fields = fields.toOwnedSlice(self.allocator) catch return null },
                };
            } else {
                return null;
            }
        }
        return null;
    }

    /// 尝试解析错误 newtype：Error("message")
    fn tryParseErrorNewtype(self: *Parser) ?ast.TypeDef {
        _ = self.advance(); // 消费 Error
        if (!self.check(.l_paren)) return null;
        _ = self.advance(); // 消费 (
        if (!self.check(.string_literal)) return null;
        const msg = self.advance();
        _ = self.expect(.r_paren, "期望 ')'") catch return null;
        // 去除字符串字面量的引号
        const raw_msg = if (msg.lexeme.len >= 2) msg.lexeme[1 .. msg.lexeme.len - 1] else msg.lexeme;
        return ast.TypeDef{
            .error_newtype = .{
                .name = "Error",
                .message = raw_msg,
            },
        };
    }

    /// 解析 ADT 体：| Constructor(fields) | ...
    fn parseAdtBody(self: *Parser) ParserError!ast.TypeDef {
        var constructors = std.ArrayList(ast.ConstructorDef).empty;

        try constructors.append(self.allocator, try self.parseConstructorDef());

        while (self.matchToken(.pipe)) {
            try constructors.append(self.allocator, try self.parseConstructorDef());
        }

        return ast.TypeDef{
            .adt = .{ .constructors = try constructors.toOwnedSlice(self.allocator) },
        };
    }

    /// 解析构造器定义：Name(fields) [: ReturnType]
    fn parseConstructorDef(self: *Parser) ParserError!ast.ConstructorDef {
        const name_tok = try self.expect(.identifier, "期望构造器名");

        var fields = std.ArrayList(ast.ConstructorField).empty;
        if (self.matchToken(.l_paren)) {
            if (!self.check(.r_paren)) {
                try self.parseConstructorFieldList(&fields);
            }
            _ = self.expect(.r_paren, "期望 ')' 关闭构造器字段") catch {};
        }

        var return_type: ?*ast.TypeNode = null;
        if (self.matchToken(.colon)) {
            return_type = try self.parseType();
        }

        return ast.ConstructorDef{
            .location = tokenLoc(name_tok),
            .name = name_tok.lexeme,
            .fields = try fields.toOwnedSlice(self.allocator),
            .return_type = return_type,
        };
    }

    /// 解析构造器字段列表
    fn parseConstructorFieldList(self: *Parser, fields: *std.ArrayList(ast.ConstructorField)) ParserError!void {
        try fields.append(self.allocator, try self.parseConstructorField());
        while (self.matchToken(.comma)) {
            try fields.append(self.allocator, try self.parseConstructorField());
        }
    }

    /// 解析单个构造器字段
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

    /// 解析 Trait 声明：trait Name<T>(Parents) { methods }
    fn parseTraitDecl(self: *Parser, visibility: ast.Visibility) ParserError!ast.Decl {
        const trait_tok = self.advance(); // 消费 trait
        const name_tok = try self.expect(.identifier, "期望 Trait 名");

        var type_params = std.ArrayList(ast.TypeParam).empty;
        if (self.matchToken(.lt)) {
            try self.parseTypeParamList(&type_params);
            _ = self.expect(.gt, "期望 '>' 关闭类型参数列表") catch {};
        }

        var parents = std.ArrayList(ast.TraitBound).empty;
        if (self.matchToken(.l_paren)) {
            if (!self.check(.r_paren)) {
                try self.parseTraitBoundListInner(&parents);
            }
            _ = self.expect(.r_paren, "期望 ')' 关闭父 Trait 列表") catch {};
        }

        var associated_types = std.ArrayList(ast.AssociatedType).empty;
        var methods = std.ArrayList(ast.MethodDecl).empty;

        _ = self.expect(.l_brace, "期望 '{' 开始 Trait 体") catch {};
        while (!self.check(.r_brace) and !self.isAtEnd()) {
            if (self.checkIdentifier("type")) {
                try associated_types.append(self.allocator, try self.parseAssociatedType());
            } else {
                try methods.append(self.allocator, try self.parseMethodDecl());
            }
        }
        _ = self.expect(.r_brace, "期望 '}' 关闭 Trait 体") catch {};

        return ast.Decl{
            .trait_decl = .{
                .location = tokenLoc(trait_tok),
                .visibility = visibility,
                .name = name_tok.lexeme,
                .type_params = try type_params.toOwnedSlice(self.allocator),
                .parents = try parents.toOwnedSlice(self.allocator),
                .associated_types = try associated_types.toOwnedSlice(self.allocator),
                .methods = try methods.toOwnedSlice(self.allocator),
            },
        };
    }

    /// 解析关联类型声明
    fn parseAssociatedType(self: *Parser) ParserError!ast.AssociatedType {
        const type_tok = self.advance(); // 消费 type
        const name_tok = try self.expect(.identifier, "期望关联类型名");

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

    /// 解析方法声明
    fn parseMethodDecl(self: *Parser) ParserError!ast.MethodDecl {
        var visibility: ast.Visibility = .private;
        if (self.matchToken(.kw_pub)) {
            visibility = .public;
        }

        var is_override = false;
        if (self.matchToken(.kw_override)) {
            is_override = true;
        }

        _ = self.expect(.kw_fun, "期望 'fun'") catch {};
        const name_tok = try self.expect(.identifier, "期望方法名");

        var type_params = std.ArrayList(ast.TypeParam).empty;
        if (self.matchToken(.lt)) {
            try self.parseTypeParamList(&type_params);
            _ = self.expect(.gt, "期望 '>'") catch {};
        }

        var params = std.ArrayList(ast.Param).empty;
        _ = self.expect(.l_paren, "期望 '('") catch {};
        if (!self.check(.r_paren)) {
            try self.parseParamList(&params);
        }
        _ = self.expect(.r_paren, "期望 ')'") catch {};

        var return_type: ?*ast.TypeNode = null;
        if (self.matchToken(.colon)) {
            return_type = try self.parseType();
        }

        var body: ?*ast.Expr = null;
        if (self.check(.l_brace)) {
            body = try self.parseExpr();
        }

        return ast.MethodDecl{
            .location = tokenLoc(name_tok),
            .name = name_tok.lexeme,
            .type_params = try type_params.toOwnedSlice(self.allocator),
            .params = try params.toOwnedSlice(self.allocator),
            .return_type = return_type,
            .body = body,
            .is_override = is_override,
            .visibility = visibility,
        };
    }

    /// 解析 Impl 声明：impl TraitName<Type> { methods }
    fn parseImplDecl(self: *Parser, visibility: ast.Visibility) ParserError!ast.Decl {
        const impl_tok = self.advance(); // 消费 impl
        const name_tok = try self.expect(.identifier, "期望 Trait 名");

        var type_args = std.ArrayList(*ast.TypeNode).empty;
        if (self.matchToken(.lt)) {
            try self.parseTypeArgList(&type_args);
            _ = self.expect(.gt, "期望 '>'") catch {};
        }

        var methods = std.ArrayList(ast.MethodDecl).empty;
        _ = self.expect(.l_brace, "期望 '{'") catch {};
        while (!self.check(.r_brace) and !self.isAtEnd()) {
            try methods.append(self.allocator, try self.parseMethodDecl());
        }
        _ = self.expect(.r_brace, "期望 '}'") catch {};

        return ast.Decl{
            .impl_decl = .{
                .location = tokenLoc(impl_tok),
                .trait_name = name_tok.lexeme,
                .type_args = try type_args.toOwnedSlice(self.allocator),
                .methods = try methods.toOwnedSlice(self.allocator),
                .visibility = visibility,
            },
        };
    }

    /// 解析 use 声明：use Module.{items}
    fn parseUseDecl(self: *Parser, visibility: ast.Visibility) ParserError!ast.Decl {
        const use_tok = self.advance(); // 消费 use

        var module_path = std.ArrayList([]const u8).empty;
        const first = try self.expect(.identifier, "期望模块名");
        try module_path.append(self.allocator, first.lexeme);

        while (self.matchToken(.dot)) {
            if (self.check(.l_brace)) break;
            const part = try self.expect(.identifier, "期望模块路径段");
            try module_path.append(self.allocator, part.lexeme);
        }

        var items: ?[]ast.UseItem = null;
        if (self.matchToken(.dot)) {
            _ = self.expect(.l_brace, "期望 '{'") catch {};
            var item_list = std.ArrayList(ast.UseItem).empty;
            if (!self.check(.r_brace)) {
                try item_list.append(self.allocator, try self.parseUseItem());
                while (self.matchToken(.comma)) {
                    if (self.check(.r_brace)) break;
                    try item_list.append(self.allocator, try self.parseUseItem());
                }
            }
            _ = self.expect(.r_brace, "期望 '}'") catch {};
            items = try item_list.toOwnedSlice(self.allocator);
        }

        return ast.Decl{
            .use_decl = .{
                .location = tokenLoc(use_tok),
                .module_path = try module_path.toOwnedSlice(self.allocator),
                .items = items,
                .visibility = visibility,
            },
        };
    }

    /// 解析单个 use 导入项
    fn parseUseItem(self: *Parser) ParserError!ast.UseItem {
        const name = try self.expect(.identifier, "期望导入项名");
        var alias: ?[]const u8 = null;
        if (self.matchToken(.kw_as)) {
            const alias_tok = try self.expect(.identifier, "期望别名");
            alias = alias_tok.lexeme;
        }
        return ast.UseItem{
            .name = name.lexeme,
            .alias = alias,
        };
    }

    /// 解析 pack 声明：[pub] pack Name
    fn parsePackDecl(self: *Parser, visibility: ast.Visibility) ParserError!ast.Decl {
        const pack_tok = self.advance(); // 消费 pack
        const name_tok = try self.expect(.identifier, "期望 pack 名");

        return ast.Decl{
            .pack_decl = .{
                .location = tokenLoc(pack_tok),
                .visibility = visibility,
                .name = name_tok.lexeme,
            },
        };
    }

    // ============================================================
    // 类型参数和参数列表解析
    // ============================================================

    fn parseTypeParamList(self: *Parser, type_params: *std.ArrayList(ast.TypeParam)) ParserError!void {
        try type_params.append(self.allocator, try self.parseTypeParam());
        while (self.matchToken(.comma)) {
            try type_params.append(self.allocator, try self.parseTypeParam());
        }
    }

    fn parseTypeParam(self: *Parser) ParserError!ast.TypeParam {
        const name_tok = try self.expect(.identifier, "期望类型参数名");

        var kind: ?*ast.Kind = null;
        if (self.matchToken(.colon)) {
            kind = try self.parseKind();
        }

        var bounds = std.ArrayList(ast.TraitBound).empty;
        if (self.matchToken(.kw_with)) {
            try self.parseTraitBoundListInner(&bounds);
        }

        return ast.TypeParam{
            .location = tokenLoc(name_tok),
            .name = name_tok.lexeme,
            .kind = kind,
            .bounds = try bounds.toOwnedSlice(self.allocator),
        };
    }

    fn parseKind(self: *Parser) ParserError!*ast.Kind {
        return self.parseKindArrow();
    }

    fn parseKindArrow(self: *Parser) ParserError!*ast.Kind {
        const left = try self.parseKindPrimary();
        if (self.matchToken(.minus_gt)) {
            const right = try self.parseKindArrow();
            return self.allocKind(ast.Kind{
                .arrow = .{
                    .param = left,
                    .result = right,
                },
            });
        }
        return left;
    }

    fn parseKindPrimary(self: *Parser) ParserError!*ast.Kind {
        if (self.check(.star)) {
            _ = self.advance();
            return self.allocKind(ast.Kind.star);
        }
        if (self.matchToken(.l_paren)) {
            const kind = try self.parseKindArrow();
            _ = self.expect(.r_paren, "期望 ')'") catch {};
            return kind;
        }
        try self.reportError("期望 Kind（* 或箭头 Kind）");
        return error.UnexpectedToken;
    }

    fn parseParamList(self: *Parser, params: *std.ArrayList(ast.Param)) ParserError!void {
        try params.append(self.allocator, try self.parseParam());
        while (self.matchToken(.comma)) {
            if (self.check(.r_paren)) break;
            try params.append(self.allocator, try self.parseParam());
        }
    }

    fn parseParam(self: *Parser) ParserError!ast.Param {
        var is_var = false;
        // 支持 var 在参数名前面：var data: i32
        if (self.matchToken(.kw_var)) {
            is_var = true;
        } else {
            _ = self.matchToken(.kw_val);
        }

        const name_tok = try self.expect(.identifier, "期望参数名");

        var type_annotation: ?*ast.TypeNode = null;
        if (self.matchToken(.colon)) {
            // 支持 var 在类型注解中：data: var i32
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

    fn parseTraitBoundList(self: *Parser, bounds: *std.ArrayList(ast.TraitBound)) ParserError!void {
        try self.parseTraitBoundListInner(bounds);
    }

    fn parseTraitBoundListInner(self: *Parser, bounds: *std.ArrayList(ast.TraitBound)) ParserError!void {
        try bounds.append(self.allocator, try self.parseTraitBound());
        while (self.matchToken(.comma)) {
            try bounds.append(self.allocator, try self.parseTraitBound());
        }
    }

    fn parseTraitBound(self: *Parser) ParserError!ast.TraitBound {
        const name_tok = try self.expect(.identifier, "期望 Trait 名");

        var type_args = std.ArrayList(*ast.TypeNode).empty;
        if (self.matchToken(.lt)) {
            try self.parseTypeArgList(&type_args);
            _ = self.expect(.gt, "期望 '>'") catch {};
        }

        return ast.TraitBound{
            .trait_name = name_tok.lexeme,
            .type_args = try type_args.toOwnedSlice(self.allocator),
        };
    }

    fn parseTypeArgList(self: *Parser, type_args: *std.ArrayList(*ast.TypeNode)) ParserError!void {
        try type_args.append(self.allocator, try self.parseType());
        while (self.matchToken(.comma)) {
            try type_args.append(self.allocator, try self.parseType());
        }
    }

    // ============================================================
    // 类型注解解析
    // ============================================================

    fn parseType(self: *Parser) ParserError!*ast.TypeNode {
        return self.parseFunctionType();
    }

    fn parseFunctionType(self: *Parser) ParserError!*ast.TypeNode {
        const left = try self.parseNullableType();
        if (self.matchToken(.minus_gt)) {
            var params = std.ArrayList(*ast.TypeNode).empty;
            try params.append(self.allocator, left);
            const ret = try self.parseType();
            return self.allocType(ast.TypeNode{
                .function = .{
                    .location = getTypeNodeLocation(left),
                    .params = try params.toOwnedSlice(self.allocator),
                    .return_type = ret,
                },
            });
        }
        return left;
    }

    fn parseNullableType(self: *Parser) ParserError!*ast.TypeNode {
        var ty = try self.parsePrimaryType();
        while (self.matchToken(.question)) {
            const location = getTypeNodeLocation(ty);
            ty = try self.allocType(ast.TypeNode{
                .nullable = .{
                    .location = location,
                    .inner = ty,
                },
            });
        }
        return ty;
    }

    fn parsePrimaryType(self: *Parser) ParserError!*ast.TypeNode {
        if (self.check(.l_paren)) {
            return self.parseRecordType();
        }

        const name_tok = try self.expect(.identifier, "期望类型名");
        const location = tokenLoc(name_tok);

        if (self.matchToken(.lt)) {
            var args = std.ArrayList(*ast.TypeNode).empty;
            try args.append(self.allocator, try self.parseType());
            while (self.matchToken(.comma)) {
                try args.append(self.allocator, try self.parseType());
            }
            _ = self.expect(.gt, "期望 '>' 关闭类型参数") catch {};

            return self.allocType(ast.TypeNode{
                .generic = .{
                    .location = location,
                    .name = name_tok.lexeme,
                    .args = try args.toOwnedSlice(self.allocator),
                },
            });
        }

        return self.allocType(ast.TypeNode{
            .named = .{
                .location = location,
                .name = name_tok.lexeme,
            },
        });
    }

    fn parseRecordType(self: *Parser) ParserError!*ast.TypeNode {
        const lparen = self.advance(); // 消费 (
        const location = tokenLoc(lparen);

        var fields = std.ArrayList(ast.RecordFieldType).empty;

        if (!self.check(.r_paren)) {
            const name_tok = try self.expect(.identifier, "期望字段名");
            _ = self.expect(.colon, "期望 ':'") catch {};
            const ty = try self.parseType();
            try fields.append(self.allocator, .{
                .name = name_tok.lexeme,
                .ty = ty,
            });

            while (self.matchToken(.comma)) {
                if (self.check(.r_paren)) break;
                const field_name = try self.expect(.identifier, "期望字段名");
                _ = self.expect(.colon, "期望 ':'") catch {};
                const field_ty = try self.parseType();
                try fields.append(self.allocator, .{
                    .name = field_name.lexeme,
                    .ty = field_ty,
                });
            }
        }

        _ = self.expect(.r_paren, "期望 ')'") catch {};

        return self.allocType(ast.TypeNode{
            .record = .{
                .location = location,
                .fields = try fields.toOwnedSlice(self.allocator),
            },
        });
    }

    // ============================================================
    // 表达式解析（按优先级从低到高）
    // ============================================================

    pub fn parseExpr(self: *Parser) ParserError!*ast.Expr {
        return self.parseElvis();
    }

    fn parseElvis(self: *Parser) ParserError!*ast.Expr {
        var left = try self.parseOr();
        while (self.matchToken(.question_question)) {
            const op_tok = self.previous();
            const right = try self.parseOr();
            left = try self.allocExpr(ast.Expr{
                .binary = .{
                    .location = tokenLoc(op_tok),
                    .op = .elvis,
                    .left = left,
                    .right = right,
                },
            });
        }
        return left;
    }

    fn parseOr(self: *Parser) ParserError!*ast.Expr {
        var left = try self.parseAnd();
        while (self.matchToken(.pipe_pipe)) {
            const op_tok = self.previous();
            const right = try self.parseAnd();
            left = try self.allocExpr(ast.Expr{
                .binary = .{
                    .location = tokenLoc(op_tok),
                    .op = .or_op,
                    .left = left,
                    .right = right,
                },
            });
        }
        return left;
    }

    fn parseAnd(self: *Parser) ParserError!*ast.Expr {
        var left = try self.parseEquality();
        while (self.matchToken(.amp_amp)) {
            const op_tok = self.previous();
            const right = try self.parseEquality();
            left = try self.allocExpr(ast.Expr{
                .binary = .{
                    .location = tokenLoc(op_tok),
                    .op = .and_op,
                    .left = left,
                    .right = right,
                },
            });
        }
        return left;
    }

    fn parseEquality(self: *Parser) ParserError!*ast.Expr {
        var left = try self.parseComparison();
        while (true) {
            if (self.matchToken(.eq_eq)) {
                const op_tok = self.previous();
                const right = try self.parseComparison();
                left = try self.allocExpr(ast.Expr{
                    .binary = .{
                        .location = tokenLoc(op_tok),
                        .op = .eq,
                        .left = left,
                        .right = right,
                    },
                });
            } else if (self.matchToken(.bang_eq)) {
                const op_tok = self.previous();
                const right = try self.parseComparison();
                left = try self.allocExpr(ast.Expr{
                    .binary = .{
                        .location = tokenLoc(op_tok),
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
                left = try self.allocExpr(ast.Expr{
                    .binary = .{
                        .location = tokenLoc(op_tok),
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

    fn parseRange(self: *Parser) ParserError!*ast.Expr {
        var left = try self.parseAddition();
        while (true) {
            if (self.matchToken(.dot_dot)) {
                const op_tok = self.previous();
                const right = try self.parseAddition();
                left = try self.allocExpr(ast.Expr{
                    .binary = .{
                        .location = tokenLoc(op_tok),
                        .op = .range,
                        .left = left,
                        .right = right,
                    },
                });
            } else if (self.matchToken(.dot_dot_eq)) {
                const op_tok = self.previous();
                const right = try self.parseAddition();
                left = try self.allocExpr(ast.Expr{
                    .binary = .{
                        .location = tokenLoc(op_tok),
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

    fn parseAddition(self: *Parser) ParserError!*ast.Expr {
        var left = try self.parseMultiplication();
        while (true) {
            if (self.matchToken(.plus)) {
                const op_tok = self.previous();
                const right = try self.parseMultiplication();
                left = try self.allocExpr(ast.Expr{
                    .binary = .{
                        .location = tokenLoc(op_tok),
                        .op = .add,
                        .left = left,
                        .right = right,
                    },
                });
            } else if (self.matchToken(.minus)) {
                const op_tok = self.previous();
                const right = try self.parseMultiplication();
                left = try self.allocExpr(ast.Expr{
                    .binary = .{
                        .location = tokenLoc(op_tok),
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
                left = try self.allocExpr(ast.Expr{
                    .binary = .{
                        .location = tokenLoc(op_tok),
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

    fn parseUnary(self: *Parser) ParserError!*ast.Expr {
        if (self.matchToken(.bang)) {
            const op_tok = self.previous();
            const operand = try self.parseUnary();
            return self.allocExpr(ast.Expr{
                .unary = .{
                    .location = tokenLoc(op_tok),
                    .op = .not,
                    .operand = operand,
                },
            });
        }
        if (self.matchToken(.minus)) {
            const op_tok = self.previous();
            const operand = try self.parseUnary();
            return self.allocExpr(ast.Expr{
                .unary = .{
                    .location = tokenLoc(op_tok),
                    .op = .neg,
                    .operand = operand,
                },
            });
        }
        return self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) ParserError!*ast.Expr {
        var expr_node = try self.parsePrimary();

        while (true) {
            if (self.matchToken(.question)) {
                const op_tok = self.previous();
                expr_node = try self.allocExpr(ast.Expr{
                    .propagate = .{
                        .location = tokenLoc(op_tok),
                        .expr = expr_node,
                    },
                });
            } else if (self.matchToken(.bang)) {
                const op_tok = self.previous();
                expr_node = try self.allocExpr(ast.Expr{
                    .non_null_assert = .{
                        .location = tokenLoc(op_tok),
                        .expr = expr_node,
                    },
                });
            } else if (self.matchToken(.question_dot)) {
                const op_tok = self.previous();
                const field_tok = try self.expect(.identifier, "期望字段或方法名");

                if (self.check(.l_paren)) {
                    var args = std.ArrayList(*ast.Expr).empty;
                    var type_args: ?[]*ast.TypeNode = null;
                    if (self.matchToken(.lt)) {
                        var ta = std.ArrayList(*ast.TypeNode).empty;
                        try self.parseTypeArgList(&ta);
                        _ = self.expect(.gt, "期望 '>'") catch {};
                        type_args = try ta.toOwnedSlice(self.allocator);
                    }
                    _ = self.expect(.l_paren, "期望 '('") catch {};
                    if (!self.check(.r_paren)) {
                        try args.append(self.allocator, try self.parseExpr());
                        while (self.matchToken(.comma)) {
                            try args.append(self.allocator, try self.parseExpr());
                        }
                    }
                    _ = self.expect(.r_paren, "期望 ')'") catch {};

                    expr_node = try self.allocExpr(ast.Expr{
                        .safe_method_call = .{
                            .location = tokenLoc(op_tok),
                            .object = expr_node,
                            .method = field_tok.lexeme,
                            .arguments = try args.toOwnedSlice(self.allocator),
                            .type_args = type_args,
                        },
                    });
                } else {
                    expr_node = try self.allocExpr(ast.Expr{
                        .safe_access = .{
                            .location = tokenLoc(op_tok),
                            .object = expr_node,
                            .field = field_tok.lexeme,
                        },
                    });
                }
            } else if (self.matchToken(.dot)) {
                const op_tok = self.previous();
                const field_tok = try self.expect(.identifier, "期望字段或方法名");

                if (self.check(.l_paren)) {
                    var args = std.ArrayList(*ast.Expr).empty;
                    var type_args: ?[]*ast.TypeNode = null;
                    if (self.matchToken(.lt)) {
                        var ta = std.ArrayList(*ast.TypeNode).empty;
                        try self.parseTypeArgList(&ta);
                        _ = self.expect(.gt, "期望 '>'") catch {};
                        type_args = try ta.toOwnedSlice(self.allocator);
                    }
                    _ = self.expect(.l_paren, "期望 '('") catch {};
                    if (!self.check(.r_paren)) {
                        try args.append(self.allocator, try self.parseExpr());
                        while (self.matchToken(.comma)) {
                            try args.append(self.allocator, try self.parseExpr());
                        }
                    }
                    _ = self.expect(.r_paren, "期望 ')'") catch {};

                    expr_node = try self.allocExpr(ast.Expr{
                        .method_call = .{
                            .location = tokenLoc(op_tok),
                            .object = expr_node,
                            .method = field_tok.lexeme,
                            .arguments = try args.toOwnedSlice(self.allocator),
                            .type_args = type_args,
                        },
                    });
                } else {
                    expr_node = try self.allocExpr(ast.Expr{
                        .field_access = .{
                            .location = tokenLoc(op_tok),
                            .object = expr_node,
                            .field = field_tok.lexeme,
                        },
                    });
                }
            } else if (self.check(.l_paren)) {
                const call_tok = self.peek();
                var args = std.ArrayList(*ast.Expr).empty;
                var type_args: ?[]*ast.TypeNode = null;

                if (self.matchToken(.lt)) {
                    var ta = std.ArrayList(*ast.TypeNode).empty;
                    try self.parseTypeArgList(&ta);
                    if (self.matchToken(.gt)) {
                        type_args = try ta.toOwnedSlice(self.allocator);
                    } else {
                        self.current -= ta.items.len + 1;
                        ta.deinit(self.allocator);
                    }
                }

                _ = self.expect(.l_paren, "期望 '('") catch {};
                if (!self.check(.r_paren)) {
                    try args.append(self.allocator, try self.parseExpr());
                    while (self.matchToken(.comma)) {
                        try args.append(self.allocator, try self.parseExpr());
                    }
                }
                _ = self.expect(.r_paren, "期望 ')'") catch {};

                expr_node = try self.allocExpr(ast.Expr{
                    .call = .{
                        .location = tokenLoc(call_tok),
                        .callee = expr_node,
                        .arguments = try args.toOwnedSlice(self.allocator),
                        .type_args = type_args,
                    },
                });
            } else if (self.matchToken(.l_bracket)) {
                const bracket_tok = self.previous();
                const index = try self.parseExpr();
                _ = self.expect(.r_bracket, "期望 ']'") catch {};

                expr_node = try self.allocExpr(ast.Expr{
                    .index = .{
                        .location = tokenLoc(bracket_tok),
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
            return self.allocExpr(ast.Expr{
                .bool_literal = .{
                    .location = tokenLoc(tok),
                    .value = true,
                },
            });
        }
        if (self.matchToken(.false_literal)) {
            const tok = self.previous();
            return self.allocExpr(ast.Expr{
                .bool_literal = .{
                    .location = tokenLoc(tok),
                    .value = false,
                },
            });
        }

        if (self.matchToken(.char_literal)) {
            const tok = self.previous();
            return self.allocExpr(ast.Expr{
                .char_literal = .{
                    .location = tokenLoc(tok),
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
            return self.allocExpr(ast.Expr{
                .null_literal = tokenLoc(tok),
            });
        }

        // Lambda: fun(params) { body }
        if (self.check(.kw_fun)) {
            if (self.tokens.len > self.current + 1 and self.tokens[self.current + 1].type == .l_paren) {
                return self.parseLambdaFun();
            }
        }

        if (self.matchToken(.kw_if)) {
            return self.parseIfExpr();
        }

        if (self.matchToken(.kw_match)) {
            return self.parseMatchExpr();
        }

        if (self.matchToken(.kw_spawn)) {
            return self.parseSpawnExpr();
        }

        if (self.matchToken(.kw_lazy)) {
            return self.parseLazyExpr();
        }

        if (self.matchToken(.kw_select)) {
            return self.parseSelectExpr();
        }

        if (self.matchToken(.at)) {
            return self.parseMonadExpr();
        }

        // 内联 Trait 值 trait { methods }
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

        if (self.check(.identifier)) {
            // 检查类型转换：Name(expr) 其中 Name 是内建类型
            if (isBuiltinType(self.peek().lexeme)) {
                if (self.tokens.len > self.current + 1 and self.tokens[self.current + 1].type == .l_paren) {
                    return self.parseTypeCast();
                }
            }
            const tok = self.advance();
            return self.allocExpr(ast.Expr{
                .identifier = .{
                    .location = tokenLoc(tok),
                    .name = tok.lexeme,
                },
            });
        }

        try self.reportError("期望表达式");
        return error.UnexpectedToken;
    }

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
        return self.allocExpr(ast.Expr{
            .int_literal = .{
                .location = tokenLoc(tok),
                .raw = raw,
                .suffix = suffix,
            },
        });
    }

    fn parseFloatLiteral(self: *Parser, tok: lexer.Token) ParserError!*ast.Expr {
        var suffix: ?[]const u8 = null;
        const raw = tok.lexeme;
        var i: usize = raw.len;
        while (i > 0) {
            const ch = raw[i - 1];
            if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z')) {
                i -= 1;
            } else {
                break;
            }
        }
        if (i < raw.len) {
            suffix = raw[i..];
        }
        return self.allocExpr(ast.Expr{
            .float_literal = .{
                .location = tokenLoc(tok),
                .raw = raw,
                .suffix = suffix,
            },
        });
    }

    fn parseStringLiteral(self: *Parser, tok: lexer.Token) ParserError!*ast.Expr {
        const raw = tok.lexeme;
        if (!containsInterpolation(raw)) {
            const content = raw[1 .. raw.len - 1];
            const value = try self.unescapeString(content);
            return self.allocExpr(ast.Expr{
                .string_literal = .{
                    .location = tokenLoc(tok),
                    .value = value,
                },
            });
        }

        // 解析字符串插值：将 "Hello, {name}!" 解析为
        // [literal("Hello, "), expression(name), literal("!")]
        var parts = std.ArrayList(ast.InterpolationPart).empty;
        errdefer {
            for (parts.items) |*p| {
                switch (p.*) {
                    .literal => |s| self.allocator.free(s),
                    else => {},
                }
            }
            parts.deinit(self.allocator);
        }

        // 内容区域（去掉首尾引号）
        const content = raw[1 .. raw.len - 1];
        var i: usize = 0;
        var literal_start: usize = 0;

        while (i < content.len) {
            if (content[i] == '\\') {
                // 转义序列：跳过两个字符
                i += 2;
                continue;
            }
            if (content[i] == '{') {
                // 检查 {{ 转义
                if (i + 1 < content.len and content[i + 1] == '{') {
                    i += 2;
                    continue;
                }
                // 保存前面的字面量文本
                if (i > literal_start) {
                    const text = try self.unescapeString(content[literal_start..i]);
                    try parts.append(self.allocator, ast.InterpolationPart{ .literal = text });
                }
                // 找到匹配的 }
                i += 1;
                const expr_start = i;
                var brace_depth: usize = 1;
                while (i < content.len and brace_depth > 0) {
                    if (content[i] == '{') {
                        brace_depth += 1;
                    } else if (content[i] == '}') {
                        brace_depth -= 1;
                    } else if (content[i] == '\\') {
                        i += 1; // 跳过转义
                    }
                    i += 1;
                }
                // expr_start..i-1 是插值表达式文本
                const expr_text = content[expr_start .. i - 1];
                // 对插值表达式文本进行词法分析和语法分析
                const expr = try self.parseInterpolationExpr(expr_text);
                try parts.append(self.allocator, ast.InterpolationPart{ .expression = expr });
                literal_start = i;
                continue;
            }
            i += 1;
        }

        // 保存尾部字面量文本
        if (literal_start < content.len) {
            const text = try self.unescapeString(content[literal_start..]);
            try parts.append(self.allocator, ast.InterpolationPart{ .literal = text });
        }

        return self.allocExpr(ast.Expr{
            .string_interpolation = .{
                .location = tokenLoc(tok),
                .parts = try parts.toOwnedSlice(self.allocator),
            },
        });
    }

    /// 对插值表达式文本进行词法分析和语法分析
    fn parseInterpolationExpr(self: *Parser, text: []const u8) ParserError!*ast.Expr {
        var interp_lex = lexer.Lexer.init(self.allocator, text);
        const tokens = interp_lex.tokenize() catch return error.UnexpectedToken;
        defer self.allocator.free(tokens);

        var interp_parser = Parser.init(self.allocator, tokens);
        // 不需要 deinit，因为分配的节点由外层 parser 管理
        const expr = interp_parser.parseExpr() catch return error.UnexpectedToken;
        return expr;
    }

    /// 处理字符串中的转义序列，返回新分配的字符串
    fn unescapeString(self: *Parser, text: []const u8) ParserError![]const u8 {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '\\' and i + 1 < text.len) {
                const next = text[i + 1];
                switch (next) {
                    'n' => {
                        try result.append(self.allocator, '\n');
                        i += 2;
                    },
                    't' => {
                        try result.append(self.allocator, '\t');
                        i += 2;
                    },
                    'r' => {
                        try result.append(self.allocator, '\r');
                        i += 2;
                    },
                    '\\' => {
                        try result.append(self.allocator, '\\');
                        i += 2;
                    },
                    '"' => {
                        try result.append(self.allocator, '"');
                        i += 2;
                    },
                    '{' => {
                        try result.append(self.allocator, '{');
                        i += 2;
                    },
                    '}' => {
                        try result.append(self.allocator, '}');
                        i += 2;
                    },
                    else => {
                        try result.append(self.allocator, text[i]);
                        i += 1;
                    },
                }
            } else if (text[i] == '{' and i + 1 < text.len and text[i + 1] == '{') {
                // {{ 转义为 {
                try result.append(self.allocator, '{');
                i += 2;
            } else if (text[i] == '}' and i + 1 < text.len and text[i + 1] == '}') {
                // }} 转义为 }
                try result.append(self.allocator, '}');
                i += 2;
            } else {
                try result.append(self.allocator, text[i]);
                i += 1;
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn parseLambdaFun(self: *Parser) ParserError!*ast.Expr {
        const fun_tok = self.advance(); // 消费 fun
        const location = tokenLoc(fun_tok);

        var params = std.ArrayList(ast.Param).empty;
        _ = self.expect(.l_paren, "期望 '('") catch {};
        if (!self.check(.r_paren)) {
            try self.parseParamList(&params);
        }
        _ = self.expect(.r_paren, "期望 ')'") catch {};

        const body_expr = try self.parseExpr();
        const body = ast.LambdaBody{ .block = body_expr };

        return self.allocExpr(ast.Expr{
            .lambda = .{
                .location = location,
                .params = try params.toOwnedSlice(self.allocator),
                .body = body,
            },
        });
    }

    fn parseIfExpr(self: *Parser) ParserError!*ast.Expr {
        const if_tok = self.previous();
        const condition = try self.parseExpr();
        const then_branch = try self.parseExpr();

        var else_branch: ?*ast.Expr = null;
        if (self.matchToken(.kw_else)) {
            else_branch = try self.parseExpr();
        }

        return self.allocExpr(ast.Expr{
            .if_expr = .{
                .location = tokenLoc(if_tok),
                .condition = condition,
                .then_branch = then_branch,
                .else_branch = else_branch,
            },
        });
    }

    fn parseMatchExpr(self: *Parser) ParserError!*ast.Expr {
        const match_tok = self.previous();
        const scrutinee = try self.parseExpr();

        _ = self.expect(.l_brace, "期望 '{'") catch {};

        var arms = std.ArrayList(ast.MatchArm).empty;
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
            try arms.append(self.allocator, arm);
            _ = self.matchToken(.comma); // 逗号可选
        }

        _ = self.expect(.r_brace, "期望 '}'") catch {};

        return self.allocExpr(ast.Expr{
            .match = .{
                .location = tokenLoc(match_tok),
                .scrutinee = scrutinee,
                .arms = try arms.toOwnedSlice(self.allocator),
            },
        });
    }

    fn parseMatchArm(self: *Parser) ParserError!ast.MatchArm {
        const pattern = try self.parsePattern();

        var guard: ?*ast.Expr = null;
        if (self.matchToken(.kw_if)) {
            guard = try self.parseExpr();
        }

        _ = self.expect(.eq_gt, "期望 '=>'") catch {};
        const body = try self.parseExpr();

        return ast.MatchArm{
            .pattern = pattern,
            .guard = guard,
            .body = body,
        };
    }

    fn parseSpawnExpr(self: *Parser) ParserError!*ast.Expr {
        const spawn_tok = self.previous();
        const body = try self.parseExpr();

        return self.allocExpr(ast.Expr{
            .spawn = .{
                .location = tokenLoc(spawn_tok),
                .body = body,
            },
        });
    }

    fn parseLazyExpr(self: *Parser) ParserError!*ast.Expr {
        const lazy_tok = self.previous();
        const expr = try self.parseExpr();

        return self.allocExpr(ast.Expr{
            .lazy = .{
                .location = tokenLoc(lazy_tok),
                .expr = expr,
            },
        });
    }

    fn parseSelectExpr(self: *Parser) ParserError!*ast.Expr {
        const select_tok = self.previous();
        _ = self.expect(.l_brace, "期望 '{'") catch {};

        var arms = std.ArrayList(ast.SelectArm).empty;
        while (!self.check(.r_brace) and !self.isAtEnd()) {
            try arms.append(self.allocator, try self.parseSelectArm());
        }
        _ = self.expect(.r_brace, "期望 '}'") catch {};

        return self.allocExpr(ast.Expr{
            .select = .{
                .location = tokenLoc(select_tok),
                .arms = try arms.toOwnedSlice(self.allocator),
            },
        });
    }

    fn parseSelectArm(self: *Parser) ParserError!ast.SelectArm {
        if (self.checkIdentifier("timeout")) {
            const timeout_tok = self.advance();
            _ = self.expect(.l_paren, "期望 '('") catch {};
            const duration = try self.parseExpr();
            _ = self.expect(.r_paren, "期望 ')'") catch {};
            _ = self.expect(.eq_gt, "期望 '=>'") catch {};
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
        _ = self.expect(.eq_gt, "期望 '=>'") catch {};

        const binding: ?[]const u8 = null;

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

    fn parseMonadExpr(self: *Parser) ParserError!*ast.Expr {
        const at_tok = self.previous();
        const type_tok = try self.expect(.identifier, "期望 Monad 类型名");
        _ = self.expect(.l_brace, "期望 '{'") catch {};

        var bindings = std.ArrayList(ast.MonadBinding).empty;
        // 简化：暂不解析绑定列表
        const result = try self.parseExpr();
        _ = self.expect(.r_brace, "期望 '}'") catch {};

        return self.allocExpr(ast.Expr{
            .monad_comprehension = .{
                .location = tokenLoc(at_tok),
                .monad_type = type_tok.lexeme,
                .bindings = try bindings.toOwnedSlice(self.allocator),
                .result = result,
            },
        });
    }

    fn parseInlineTraitValue(self: *Parser) ParserError!*ast.Expr {
        const trait_tok = self.advance(); // 消费 trait
        _ = self.expect(.l_brace, "期望 '{'") catch {};

        var methods = std.ArrayList(ast.MethodDecl).empty;
        while (!self.check(.r_brace) and !self.isAtEnd()) {
            try methods.append(self.allocator, try self.parseMethodDecl());
        }
        _ = self.expect(.r_brace, "期望 '}'") catch {};

        return self.allocExpr(ast.Expr{
            .inline_trait_value = .{
                .location = tokenLoc(trait_tok),
                .methods = try methods.toOwnedSlice(self.allocator),
            },
        });
    }

    fn parseArrayLiteral(self: *Parser) ParserError!*ast.Expr {
        const bracket_tok = self.previous();

        var elements = std.ArrayList(*ast.Expr).empty;
        if (!self.check(.r_bracket)) {
            try elements.append(self.allocator, try self.parseExpr());
            while (self.matchToken(.comma)) {
                if (self.check(.r_bracket)) break;
                try elements.append(self.allocator, try self.parseExpr());
            }
        }
        _ = self.expect(.r_bracket, "期望 ']'") catch {};

        return self.allocExpr(ast.Expr{
            .array_literal = .{
                .location = tokenLoc(bracket_tok),
                .elements = try elements.toOwnedSlice(self.allocator),
            },
        });
    }

    fn parseBlockExpr(self: *Parser) ParserError!*ast.Expr {
        const brace_tok = self.advance(); // 消费 {
        const location = tokenLoc(brace_tok);

        var statements = std.ArrayList(*ast.Stmt).empty;
        var trailing_expr: ?*ast.Expr = null;

        while (!self.check(.r_brace) and !self.isAtEnd()) {
            if (self.isStmtStart()) {
                const stmt = try self.parseStmt();
                try statements.append(self.allocator, stmt);
            } else {
                // 使用 parseExprOrAssignmentStmt 处理赋值语句（如 x = 10）
                const stmt = try self.parseExprOrAssignmentStmt();
                // 检查是否是尾表达式（纯表达式语句且后面紧跟 }）
                if (stmt.* == .expression and self.check(.r_brace)) {
                    trailing_expr = stmt.expression.expr;
                    break;
                }
                try statements.append(self.allocator, stmt);
            }
        }

        _ = self.expect(.r_brace, "期望 '}'") catch {};

        return self.allocExpr(ast.Expr{
            .block = .{
                .location = location,
                .statements = try statements.toOwnedSlice(self.allocator),
                .trailing_expr = trailing_expr,
            },
        });
    }

    fn parseParenOrRecordOrLambda(self: *Parser) ParserError!*ast.Expr {
        const lparen_tok = self.previous();
        const location = tokenLoc(lparen_tok);

        // 空括号 = 单位值
        if (self.matchToken(.r_paren)) {
            return self.allocExpr(ast.Expr{
                .unit_literal = location,
            });
        }

        const saved = self.current;

        // 尝试解析为 Lambda
        if (self.tryParseLambda(saved, location)) |lambda_expr| {
            return lambda_expr;
        }

        self.current = saved;

        // 尝试解析为记录字面量
        if (self.peek().type == .identifier) {
            const name_tok = self.advance();
            if (self.check(.colon)) {
                _ = self.advance(); // 消费 :
                const value = try self.parseExpr();
                var fields = std.ArrayList(ast.RecordFieldExpr).empty;
                try fields.append(self.allocator, .{
                    .name = name_tok.lexeme,
                    .value = value,
                });
                while (self.matchToken(.comma)) {
                    if (self.check(.r_paren)) break;
                    const field_name = try self.expect(.identifier, "期望字段名");
                    _ = self.expect(.colon, "期望 ':'") catch {};
                    const field_value = try self.parseExpr();
                    try fields.append(self.allocator, .{
                        .name = field_name.lexeme,
                        .value = field_value,
                    });
                }
                _ = self.expect(.r_paren, "期望 ')'") catch {};
                return self.allocExpr(ast.Expr{
                    .record_literal = .{
                        .location = location,
                        .fields = try fields.toOwnedSlice(self.allocator),
                    },
                });
            }
            self.current = saved;
        }

        // 解析第一个表达式
        const first_expr = try self.parseExpr();

        // 如果后面跟着逗号，解析为元组（位置记录）
        if (self.matchToken(.comma)) {
            var fields = std.ArrayList(ast.RecordFieldExpr).empty;
            // 位置键：0, 1, 2, ...
            const key0 = try self.allocator.dupe(u8, "0");
            try fields.append(self.allocator, .{
                .name = key0,
                .value = first_expr,
            });
            var idx: usize = 1;
            if (!self.check(.r_paren)) {
                const elem = try self.parseExpr();
                const key = try intToKey(self.allocator, idx);
                try fields.append(self.allocator, .{
                    .name = key,
                    .value = elem,
                });
                idx += 1;
                while (self.matchToken(.comma)) {
                    if (self.check(.r_paren)) break;
                    const next_elem = try self.parseExpr();
                    const k = try intToKey(self.allocator, idx);
                    try fields.append(self.allocator, .{
                        .name = k,
                        .value = next_elem,
                    });
                    idx += 1;
                }
            }
            _ = self.expect(.r_paren, "期望 ')'") catch {};
            return self.allocExpr(ast.Expr{
                .record_literal = .{
                    .location = location,
                    .fields = try fields.toOwnedSlice(self.allocator),
                },
            });
        }

        // 单个表达式 = 括号表达式
        _ = self.expect(.r_paren, "期望 ')'") catch {};
        return first_expr;
    }

    fn tryParseLambda(self: *Parser, saved: usize, location: ast.SourceLocation) ?*ast.Expr {
        var params = std.ArrayList(ast.Param).empty;
        if (!self.check(.r_paren)) {
            self.parseLambdaParamList(&params) catch return null;
        }
        if (!self.check(.r_paren)) return null;
        _ = self.advance(); // 消费 )

        if (!self.check(.eq_gt)) {
            self.current = saved;
            return null;
        }
        _ = self.advance(); // 消费 =>

        const body_expr = self.parseExpr() catch return null;
        const body = ast.LambdaBody{ .expression = body_expr };

        return self.allocExpr(ast.Expr{
            .lambda = .{
                .location = location,
                .params = params.toOwnedSlice(self.allocator) catch return null,
                .body = body,
            },
        }) catch return null;
    }

    fn parseLambdaParamList(self: *Parser, params: *std.ArrayList(ast.Param)) ParserError!void {
        try params.append(self.allocator, try self.parseLambdaParam());
        while (self.matchToken(.comma)) {
            if (self.check(.r_paren)) break;
            try params.append(self.allocator, try self.parseLambdaParam());
        }
    }

    fn parseLambdaParam(self: *Parser) ParserError!ast.Param {
        var is_var = false;
        if (self.matchToken(.kw_var)) {
            is_var = true;
        } else {
            _ = self.matchToken(.kw_val);
        }

        const name_tok = try self.expect(.identifier, "期望参数名");

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

    fn parseTypeCast(self: *Parser) ParserError!*ast.Expr {
        const name_tok = self.advance(); // 消费类型名
        const location = tokenLoc(name_tok);

        const target_type = try self.allocType(ast.TypeNode{
            .named = .{
                .location = location,
                .name = name_tok.lexeme,
            },
        });

        _ = self.expect(.l_paren, "期望 '('") catch {};
        const expr = try self.parseExpr();
        _ = self.expect(.r_paren, "期望 ')'") catch {};

        return self.allocExpr(ast.Expr{
            .type_cast = .{
                .location = location,
                .target_type = target_type,
                .expr = expr,
            },
        });
    }

    // ============================================================
    // 模式解析
    // ============================================================

    fn parsePattern(self: *Parser) ParserError!*ast.Pattern {
        return self.parseOrPattern();
    }

    fn parseOrPattern(self: *Parser) ParserError!*ast.Pattern {
        var left = try self.parseGuardPattern();
        while (self.matchToken(.pipe)) {
            const pipe_tok = self.previous();
            const right = try self.parseGuardPattern();
            left = try self.allocPattern(ast.Pattern{
                .or_pattern = .{
                    .location = tokenLoc(pipe_tok),
                    .left = left,
                    .right = right,
                },
            });
        }
        return left;
    }

    fn parseGuardPattern(self: *Parser) ParserError!*ast.Pattern {
        const pat = try self.parsePrimaryPattern();
        if (self.matchToken(.kw_if)) {
            const if_tok = self.previous();
            const condition = try self.parseExpr();
            return self.allocPattern(ast.Pattern{
                .guard = .{
                    .location = tokenLoc(if_tok),
                    .pattern = pat,
                    .condition = condition,
                },
            });
        }
        return pat;
    }

    fn parsePrimaryPattern(self: *Parser) ParserError!*ast.Pattern {
        if (self.check(.identifier) and std.mem.eql(u8, self.peek().lexeme, "_")) {
            const tok = self.advance();
            return self.allocPattern(ast.Pattern{
                .wildcard = tokenLoc(tok),
            });
        }

        if (self.matchToken(.null_literal)) {
            const tok = self.previous();
            return self.allocPattern(ast.Pattern{
                .literal = .{ .null = tokenLoc(tok) },
            });
        }

        if (self.matchToken(.true_literal)) {
            return self.allocPattern(ast.Pattern{
                .literal = .{ .bool = true },
            });
        }
        if (self.matchToken(.false_literal)) {
            return self.allocPattern(ast.Pattern{
                .literal = .{ .bool = false },
            });
        }

        if (self.matchToken(.int_literal)) {
            const tok = self.previous();
            return self.allocPattern(ast.Pattern{
                .literal = .{ .int = tok.lexeme },
            });
        }

        if (self.matchToken(.float_literal)) {
            const tok = self.previous();
            return self.allocPattern(ast.Pattern{
                .literal = .{ .float = tok.lexeme },
            });
        }

        if (self.matchToken(.char_literal)) {
            const tok = self.previous();
            return self.allocPattern(ast.Pattern{
                .literal = .{ .char = parseCharValue(tok.lexeme) },
            });
        }

        if (self.matchToken(.string_literal)) {
            const tok = self.previous();
            const value = tok.lexeme[1 .. tok.lexeme.len - 1];
            return self.allocPattern(ast.Pattern{
                .literal = .{ .string = value },
            });
        }

        if (self.matchToken(.l_paren)) {
            return self.parseRecordPattern();
        }

        if (self.check(.identifier)) {
            const name_tok = self.advance();
            if (self.check(.l_paren)) {
                _ = self.advance(); // 消费 (
                var patterns = std.ArrayList(*ast.Pattern).empty;
                if (!self.check(.r_paren)) {
                    try patterns.append(self.allocator, try self.parsePattern());
                    while (self.matchToken(.comma)) {
                        try patterns.append(self.allocator, try self.parsePattern());
                    }
                }
                _ = self.expect(.r_paren, "期望 ')'") catch {};
                return self.allocPattern(ast.Pattern{
                    .constructor = .{
                        .location = tokenLoc(name_tok),
                        .name = name_tok.lexeme,
                        .patterns = try patterns.toOwnedSlice(self.allocator),
                    },
                });
            }
            return self.allocPattern(ast.Pattern{
                .variable = .{
                    .location = tokenLoc(name_tok),
                    .name = name_tok.lexeme,
                },
            });
        }

        try self.reportError("期望模式");
        return error.UnexpectedToken;
    }

    fn parseRecordPattern(self: *Parser) ParserError!*ast.Pattern {
        const lparen = self.previous();
        const location = tokenLoc(lparen);

        var fields = std.ArrayList(ast.PatternRecordField).empty;
        if (!self.check(.r_paren)) {
            // 尝试判断是命名字段 (name: pattern) 还是位置字段 (pattern)
            // 命名字段：identifier 后面跟着 :
            if (self.peek().type == .identifier) {
                const saved = self.current;
                const name_tok = self.advance();
                if (self.check(.colon)) {
                    // 命名字段模式
                    _ = self.advance(); // 消费 :
                    const pattern = try self.parsePattern();
                    try fields.append(self.allocator, .{
                        .name = name_tok.lexeme,
                        .pattern = pattern,
                    });
                    while (self.matchToken(.comma)) {
                        if (self.check(.r_paren)) break;
                        const field_name = try self.expect(.identifier, "期望字段名");
                        _ = self.expect(.colon, "期望 ':'") catch {};
                        const field_pattern = try self.parsePattern();
                        try fields.append(self.allocator, .{
                            .name = field_name.lexeme,
                            .pattern = field_pattern,
                        });
                    }
                    _ = self.expect(.r_paren, "期望 ')'") catch {};
                    return self.allocPattern(ast.Pattern{
                        .record = .{
                            .location = location,
                            .fields = try fields.toOwnedSlice(self.allocator),
                        },
                    });
                }
                // 不是命名字段，回退
                self.current = saved;
            }

            // 位置字段模式（元组模式）：(pattern1, pattern2, ...)
            const first_pattern = try self.parsePattern();
            const key0 = try self.allocator.dupe(u8, "0");
            try fields.append(self.allocator, .{
                .name = key0,
                .pattern = first_pattern,
            });
            var idx: usize = 1;
            while (self.matchToken(.comma)) {
                if (self.check(.r_paren)) break;
                const next_pattern = try self.parsePattern();
                const k = try intToKey(self.allocator, idx);
                try fields.append(self.allocator, .{
                    .name = k,
                    .pattern = next_pattern,
                });
                idx += 1;
            }
        }
        _ = self.expect(.r_paren, "期望 ')'") catch {};

        return self.allocPattern(ast.Pattern{
            .record = .{
                .location = location,
                .fields = try fields.toOwnedSlice(self.allocator),
            },
        });
    }

    // ============================================================
    // 语句解析
    // ============================================================

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

    fn parseStmt(self: *Parser) ParserError!*ast.Stmt {
        if (self.matchToken(.kw_val)) {
            return self.parseValDecl();
        }
        if (self.matchToken(.kw_var)) {
            return self.parseVarDecl();
        }
        if (self.matchToken(.kw_fun)) {
            // 块内 fun 声明：fun name(...) { ... } 转为 val name = fun(...) { ... }
            // 或者 lambda 表达式：fun(x) { ... }
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
            return self.allocStmt(ast.Stmt{
                .break_stmt = .{ .location = tokenLoc(tok) },
            });
        }
        if (self.matchToken(.kw_continue)) {
            const tok = self.previous();
            return self.allocStmt(ast.Stmt{
                .continue_stmt = .{ .location = tokenLoc(tok) },
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

    /// 解析块内 fun 语句
    /// fun name(params): Type { body } → val name = fun(params) { body }
    /// fun(params) { body } → 表达式语句（lambda）
    fn parseFunStmt(self: *Parser) ParserError!*ast.Stmt {
        const fun_tok = self.previous(); // fun 已被消费

        // 检查是否是命名函数：fun name(...)
        if (self.check(.identifier) and !self.checkIdentifier("in")) {
            const name_tok = self.advance();

            // 解析参数列表
            var params = std.ArrayList(ast.Param).empty;
            _ = self.expect(.l_paren, "期望 '('") catch {};
            if (!self.check(.r_paren)) {
                try self.parseParamList(&params);
            }
            _ = self.expect(.r_paren, "期望 ')'") catch {};

            // 返回类型
            var return_type: ?*ast.TypeNode = null;
            if (self.matchToken(.colon)) {
                return_type = try self.parseType();
            }

            // 函数体
            const body_expr = try self.parseExpr();
            const body = ast.LambdaBody{ .block = body_expr };

            // 构建 lambda 表达式
            const lambda_expr = try self.allocExpr(ast.Expr{
                .lambda = .{
                    .location = tokenLoc(fun_tok),
                    .params = try params.toOwnedSlice(self.allocator),
                    .body = body,
                },
            });

            // 返回 val name = lambda
            return self.allocStmt(ast.Stmt{
                .val_decl = .{
                    .location = tokenLoc(fun_tok),
                    .name = name_tok.lexeme,
                    .type_annotation = null,
                    .value = lambda_expr,
                },
            });
        }

        // Lambda 表达式：fun(params) { body }
        // fun 已被消费，需要解析参数和函数体
        var params = std.ArrayList(ast.Param).empty;
        _ = self.expect(.l_paren, "期望 '('") catch {};
        if (!self.check(.r_paren)) {
            try self.parseParamList(&params);
        }
        _ = self.expect(.r_paren, "期望 ')'") catch {};

        const body_expr = try self.parseExpr();
        const body = ast.LambdaBody{ .block = body_expr };

        const lambda_expr = try self.allocExpr(ast.Expr{
            .lambda = .{
                .location = tokenLoc(fun_tok),
                .params = try params.toOwnedSlice(self.allocator),
                .body = body,
            },
        });

        return self.allocStmt(ast.Stmt{
            .expression = .{
                .location = tokenLoc(fun_tok),
                .expr = lambda_expr,
            },
        });
    }

    fn parseValDecl(self: *Parser) ParserError!*ast.Stmt {
        const val_tok = self.previous();
        const name_tok = try self.expect(.identifier, "期望变量名");

        var type_annotation: ?*ast.TypeNode = null;
        if (self.matchToken(.colon)) {
            type_annotation = try self.parseType();
        }

        _ = self.expect(.eq, "期望 '='") catch {};
        const value = try self.parseExpr();

        return self.allocStmt(ast.Stmt{
            .val_decl = .{
                .location = tokenLoc(val_tok),
                .name = name_tok.lexeme,
                .type_annotation = type_annotation,
                .value = value,
            },
        });
    }

    fn parseVarDecl(self: *Parser) ParserError!*ast.Stmt {
        const var_tok = self.previous();
        const name_tok = try self.expect(.identifier, "期望变量名");

        var type_annotation: ?*ast.TypeNode = null;
        if (self.matchToken(.colon)) {
            type_annotation = try self.parseType();
        }

        _ = self.expect(.eq, "期望 '='") catch {};
        const value = try self.parseExpr();

        return self.allocStmt(ast.Stmt{
            .var_decl = .{
                .location = tokenLoc(var_tok),
                .name = name_tok.lexeme,
                .type_annotation = type_annotation,
                .value = value,
            },
        });
    }

    fn parseReturnStmt(self: *Parser) ParserError!*ast.Stmt {
        const return_tok = self.previous();

        var value: ?*ast.Expr = null;
        if (!self.check(.r_brace) and !self.isStmtStart() and !self.isAtEnd()) {
            value = try self.parseExpr();
        }

        return self.allocStmt(ast.Stmt{
            .return_stmt = .{
                .location = tokenLoc(return_tok),
                .value = value,
            },
        });
    }

    fn parseDeferStmt(self: *Parser) ParserError!*ast.Stmt {
        const defer_tok = self.previous();
        const expr = try self.parseExpr();

        // 支持 defer 中包含赋值（如 defer counter = 10）
        if (self.matchToken(.eq)) {
            const value = try self.parseExpr();
            // 将赋值包装为赋值表达式 — 使用 field_assignment 或 assignment
            // 但 defer_stmt.expr 是 *Expr，不是 *Stmt
            // 我们需要将赋值包装为一个特殊的表达式
            // 最简单的方案：将 defer 后面的 "identifier = expr" 解析为一个赋值表达式
            const assign_expr = try self.allocExpr(ast.Expr{
                .assignment_expr = .{
                    .location = getExprLocation(expr),
                    .target = expr,
                    .value = value,
                },
            });
            return self.allocStmt(ast.Stmt{
                .defer_stmt = .{
                    .location = tokenLoc(defer_tok),
                    .expr = assign_expr,
                },
            });
        }

        return self.allocStmt(ast.Stmt{
            .defer_stmt = .{
                .location = tokenLoc(defer_tok),
                .expr = expr,
            },
        });
    }

    fn parseThrowStmt(self: *Parser) ParserError!*ast.Stmt {
        const throw_tok = self.previous();
        const expr = try self.parseExpr();

        return self.allocStmt(ast.Stmt{
            .throw_stmt = .{
                .location = tokenLoc(throw_tok),
                .expr = expr,
            },
        });
    }

    fn parseForStmt(self: *Parser) ParserError!*ast.Stmt {
        const for_tok = self.previous();
        const name_tok = try self.expect(.identifier, "期望迭代变量名");
        _ = self.expect(.kw_in, "期望 'in'") catch {};
        const iterable = try self.parseExpr();
        const body = try self.parseExpr();

        return self.allocStmt(ast.Stmt{
            .for_stmt = .{
                .location = tokenLoc(for_tok),
                .name = name_tok.lexeme,
                .iterable = iterable,
                .body = body,
            },
        });
    }

    fn parseWhileStmt(self: *Parser) ParserError!*ast.Stmt {
        const while_tok = self.previous();
        const condition = try self.parseExpr();
        const body = try self.parseExpr();

        return self.allocStmt(ast.Stmt{
            .while_stmt = .{
                .location = tokenLoc(while_tok),
                .condition = condition,
                .body = body,
            },
        });
    }

    fn parseLoopStmt(self: *Parser) ParserError!*ast.Stmt {
        const loop_tok = self.previous();
        const body = try self.parseExpr();

        return self.allocStmt(ast.Stmt{
            .loop_stmt = .{
                .location = tokenLoc(loop_tok),
                .body = body,
            },
        });
    }

    fn parseExprOrAssignmentStmt(self: *Parser) ParserError!*ast.Stmt {
        const expr = try self.parseExpr();

        if (self.matchToken(.eq)) {
            const eq_tok = self.previous();
            const value = try self.parseExpr();

            switch (expr.*) {
                .identifier => |id| {
                    return self.allocStmt(ast.Stmt{
                        .assignment = .{
                            .location = id.location,
                            .target = expr,
                            .value = value,
                        },
                    });
                },
                .field_access => |fa| {
                    return self.allocStmt(ast.Stmt{
                        .field_assignment = .{
                            .location = tokenLoc(eq_tok),
                            .object = fa.object,
                            .field = fa.field,
                            .value = value,
                        },
                    });
                },
                else => {
                    return self.allocStmt(ast.Stmt{
                        .assignment = .{
                            .location = tokenLoc(eq_tok),
                            .target = expr,
                            .value = value,
                        },
                    });
                },
            }
        }

        return self.allocStmt(ast.Stmt{
            .expression = .{
                .location = getExprLocation(expr),
                .expr = expr,
            },
        });
    }
};

// ============================================================
// 辅助函数
// ============================================================

/// 从 token 获取源位置
fn tokenLoc(token: lexer.Token) ast.SourceLocation {
    return ast.SourceLocation{
        .line = token.line,
        .column = token.column,
    };
}

/// 获取类型节点的源位置
fn getTypeNodeLocation(ty: *const ast.TypeNode) ast.SourceLocation {
    return switch (ty.*) {
        .named => |n| n.location,
        .generic => |g| g.location,
        .nullable => |n| n.location,
        .function => |f| f.location,
        .record => |r| r.location,
        .kind_annotated => |k| k.location,
    };
}

/// 获取表达式的源位置
fn getExprLocation(expr: *const ast.Expr) ast.SourceLocation {
    return switch (expr.*) {
        .int_literal => |e| e.location,
        .float_literal => |e| e.location,
        .bool_literal => |e| e.location,
        .char_literal => |e| e.location,
        .string_literal => |e| e.location,
        .string_interpolation => |e| e.location,
        .null_literal => |l| l,
        .unit_literal => |l| l,
        .identifier => |e| e.location,
        .assignment_expr => |e| e.location,
        .binary => |e| e.location,
        .unary => |e| e.location,
        .call => |e| e.location,
        .method_call => |e| e.location,
        .field_access => |e| e.location,
        .safe_access => |e| e.location,
        .safe_method_call => |e| e.location,
        .non_null_assert => |e| e.location,
        .propagate => |e| e.location,
        .index => |e| e.location,
        .array_literal => |e| e.location,
        .record_literal => |e| e.location,
        .lambda => |e| e.location,
        .if_expr => |e| e.location,
        .block => |e| e.location,
        .match => |e| e.location,
        .type_cast => |e| e.location,
        .spawn => |e| e.location,
        .lazy => |e| e.location,
        .select => |e| e.location,
        .monad_comprehension => |e| e.location,
        .inline_trait_value => |e| e.location,
    };
}

/// 判断标识符是否为内建类型名（用于类型转换判断）
fn isBuiltinType(name: []const u8) bool {
    const builtin_types = [_][]const u8{
        "i8",   "i16",  "i32",  "i64",  "i128",
        "u8",   "u16",  "u32",  "u64",  "u128",
        "f32",  "f64",
        "bool", "string",
    };
    for (builtin_types) |bt| {
        if (std.mem.eql(u8, name, bt)) return true;
    }
    return false;
}

/// 解析字符字面量的值
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

/// 检查字符串是否包含插值
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

/// 将 usize 转换为位置键字符串（用于元组的位置索引）
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
        // 反转
        var i: usize = 0;
        while (i < tmp_len) : (i += 1) {
            buf[i] = tmp[tmp_len - 1 - i];
        }
        len = tmp_len;
    }
    return allocator.dupe(u8, buf[0..len]);
}

fn isDigitOrUnderscore(ch: u8) bool {
    return (ch >= '0' and ch <= '9') or ch == '_';
}

fn isHexOrUnderscore(ch: u8) bool {
    return isDigitOrUnderscore(ch) or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F');
}

// ============================================================
// 测试
// ============================================================

test "解析器 - 基本表达式解析" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "42";
    var lex = lexer.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();

    var parser = Parser.init(allocator, tokens);
    defer parser.deinit();

    const expr = try parser.parseExpr();
    try std.testing.expect(expr.* == .int_literal);
    try std.testing.expectEqualStrings("42", expr.*.int_literal.raw);
}

test "解析器 - 布尔表达式解析" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "true";
    var lex = lexer.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();

    var parser = Parser.init(allocator, tokens);
    defer parser.deinit();

    const expr = try parser.parseExpr();
    try std.testing.expect(expr.* == .bool_literal);
    try std.testing.expectEqual(true, expr.*.bool_literal.value);
}

test "解析器 - 二元运算解析" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "1 + 2";
    var lex = lexer.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();

    var parser = Parser.init(allocator, tokens);
    defer parser.deinit();

    const expr = try parser.parseExpr();
    try std.testing.expect(expr.* == .binary);
    try std.testing.expectEqual(ast.BinaryOp.add, expr.*.binary.op);
    try std.testing.expect(expr.*.binary.left.* == .int_literal);
    try std.testing.expect(expr.*.binary.right.* == .int_literal);
}

test "解析器 - 运算符优先级" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "1 + 2 * 3";
    var lex = lexer.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();

    var parser = Parser.init(allocator, tokens);
    defer parser.deinit();

    const expr = try parser.parseExpr();
    try std.testing.expect(expr.* == .binary);
    try std.testing.expectEqual(ast.BinaryOp.add, expr.*.binary.op);
    try std.testing.expect(expr.*.binary.left.* == .int_literal);
    try std.testing.expect(expr.*.binary.right.* == .binary);
    try std.testing.expectEqual(ast.BinaryOp.mul, expr.*.binary.right.*.binary.op);
}

test "解析器 - val 声明解析" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "val x = 42";
    var lex = lexer.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();

    var parser = Parser.init(allocator, tokens);
    defer parser.deinit();

    const stmt = try parser.parseStmt();
    try std.testing.expect(stmt.* == .val_decl);
    try std.testing.expectEqualStrings("x", stmt.*.val_decl.name);
    try std.testing.expect(stmt.*.val_decl.value.* == .int_literal);
}

test "解析器 - var 声明解析" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "var y : i32 = 10";
    var lex = lexer.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();

    var parser = Parser.init(allocator, tokens);
    defer parser.deinit();

    const stmt = try parser.parseStmt();
    try std.testing.expect(stmt.* == .var_decl);
    try std.testing.expectEqualStrings("y", stmt.*.var_decl.name);
    try std.testing.expect(stmt.*.var_decl.type_annotation != null);
    try std.testing.expect(stmt.*.var_decl.value.* == .int_literal);
}

test "解析器 - 函数声明解析" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "fun add(a: i32, b: i32) : i32 { a + b }";
    var lex = lexer.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();

    var parser = Parser.init(allocator, tokens);
    defer parser.deinit();

    const decl = try parser.parseDecl();
    try std.testing.expect(decl == .fun_decl);
    try std.testing.expectEqualStrings("add", decl.fun_decl.name);
    try std.testing.expectEqual(@as(usize, 2), decl.fun_decl.params.len);
    try std.testing.expect(decl.fun_decl.return_type != null);
}

test "解析器 - 类型声明解析（ADT）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "type Shape = | Circle(f64) | Rectangle(f64, f64)";
    var lex = lexer.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();

    var parser = Parser.init(allocator, tokens);
    defer parser.deinit();

    const decl = try parser.parseDecl();
    try std.testing.expect(decl == .type_decl);
    try std.testing.expectEqualStrings("Shape", decl.type_decl.name);
    try std.testing.expect(decl.type_decl.def == .adt);
    try std.testing.expectEqual(@as(usize, 2), decl.type_decl.def.adt.constructors.len);
}

test "解析器 - 类型声明解析（别名）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "type IntList = List<i32>";
    var lex = lexer.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();

    var parser = Parser.init(allocator, tokens);
    defer parser.deinit();

    const decl = try parser.parseDecl();
    try std.testing.expect(decl == .type_decl);
    try std.testing.expect(decl.type_decl.def == .alias);
}

test "解析器 - 一元运算解析" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "-42";
    var lex = lexer.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();

    var parser = Parser.init(allocator, tokens);
    defer parser.deinit();

    const expr = try parser.parseExpr();
    try std.testing.expect(expr.* == .unary);
    try std.testing.expectEqual(ast.UnaryOp.neg, expr.*.unary.op);
    try std.testing.expect(expr.*.unary.operand.* == .int_literal);
}

test "解析器 - 比较运算解析" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "x < 10";
    var lex = lexer.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();

    var parser = Parser.init(allocator, tokens);
    defer parser.deinit();

    const expr = try parser.parseExpr();
    try std.testing.expect(expr.* == .binary);
    try std.testing.expectEqual(ast.BinaryOp.lt, expr.*.binary.op);
}

test "解析器 - 逻辑运算解析" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "a && b || c";
    var lex = lexer.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();

    var parser = Parser.init(allocator, tokens);
    defer parser.deinit();

    const expr = try parser.parseExpr();
    try std.testing.expect(expr.* == .binary);
    try std.testing.expectEqual(ast.BinaryOp.or_op, expr.*.binary.op);
    try std.testing.expect(expr.*.binary.left.* == .binary);
    try std.testing.expectEqual(ast.BinaryOp.and_op, expr.*.binary.left.*.binary.op);
}
