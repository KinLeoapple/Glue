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
    tokens: []lexer.Token,
    current: usize,
    allocator: std.mem.Allocator,
    errors: std.ArrayList(ParseError),
    allocated_exprs: std.ArrayList(*ast.Expr),
    allocated_stmts: std.ArrayList(*ast.Stmt),
    allocated_types: std.ArrayList(*ast.TypeNode),
    allocated_patterns: std.ArrayList(*ast.Pattern),
    allocated_kinds: std.ArrayList(*ast.Kind),
    /// 是否拥有 tokens 缓冲（init 复制以便就地拆分 `>=`/`>>`，deinit 释放）
    owns_tokens: bool,

    /// 初始化解析器
    pub fn init(allocator: std.mem.Allocator, tokens: []const lexer.Token) Parser {
        // 复制一份可变 token 缓冲：闭合泛型尖括号时需把 `>=` 就地拆成 `>` + `=`
        // （词法器贪婪地把 `>=` 合成单 token，导致 `Type<T>=` 无法解析）。
        // 复制失败则退回只读切片（拆分能力降级，但不影响其它解析）。
        const owned: ?[]lexer.Token = allocator.dupe(lexer.Token, tokens) catch null;
        return Parser{
            .tokens = owned orelse @constCast(tokens),
            .current = 0,
            .allocator = allocator,
            .errors = .empty,
            .allocated_exprs = .empty,
            .allocated_stmts = .empty,
            .allocated_types = .empty,
            .allocated_patterns = .empty,
            .allocated_kinds = .empty,
            .owns_tokens = owned != null,
        };
    }

    /// 释放解析器资源
    pub fn deinit(self: *Parser) void {
        if (self.owns_tokens) self.allocator.free(self.tokens);
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

    /// 闭合泛型尖括号 `>`。
    /// 词法器会把 `>=` 贪婪合成单个 `gt_eq`，把 `>>` 切成两个 `gt`。
    /// 这里统一处理闭合点：
    ///   - 当前是 `gt`：正常消费。
    ///   - 当前是 `gt_eq`：只消费它的 `>` 部分，把该 token 就地改写成 `eq`
    ///     （`current` 不前进），使后续读到一个独立的 `=`。这样 `Type<T>= v`
    ///     能正确解析，无需用户加空格。
    /// owns_tokens 为 false（复制失败降级）时无法就地改写，退回普通 expect(.gt)。
    fn expectCloseAngle(self: *Parser, message: []const u8) ParserError!void {
        if (self.check(.gt)) {
            _ = self.advance();
            return;
        }
        if (self.owns_tokens and self.current < self.tokens.len and self.tokens[self.current].type == .gt_eq) {
            // 拆分：把 `>=` 改写为 `=`，列号右移 1，相当于已消费了前面的 `>`
            self.tokens[self.current].type = .eq;
            self.tokens[self.current].column +%= 1;
            return;
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
            // 声明关键字开头：必然是声明，解析失败则同步到下一声明，
            // 不回退到 parseExpr（否则会对声明残余 token 产生误导性次生错误，
            // 如缺前导 `|` 的枚举在真正诊断后再报一次 "expected expression"）。
            const at_decl_kw = self.check(.kw_fun) or self.check(.kw_type) or
                self.check(.kw_trait) or self.check(.kw_impl) or
                self.check(.kw_import) or self.check(.kw_pack) or self.check(.kw_pub);

            // 先尝试解析为声明
            if (self.tryParseDecl()) |decl| {
                try declarations.append(self.allocator, decl);
                continue;
            }

            if (at_decl_kw) {
                self.synchronize();
                continue;
            }

            // 声明解析失败，尝试解析为顶层表达式或赋值语句
            const before_expr = self.current;
            const expr = self.parseExpr() catch {
                // 表达式也解析失败，同步到下一个语句开始
                self.synchronize();
                continue;
            };

            // 如果 parseExpr 没有消费任何 token，跳过当前 token 避免无限循环
            if (self.current == before_expr) {
                _ = self.advance();
                continue;
            }

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

        // 如果解析过程中有错误，返回错误让调用者报告
        if (self.errors.items.len > 0) {
            return error.UnexpectedToken;
        }

        return ast.Module{
            .name = module_name,
            .source_path = null,
            .declarations = try declarations.toOwnedSlice(self.allocator),
        };
    }

    /// 尝试解析顶层声明，失败返回 null
    /// 注意：失败时解析器位置可能已改变，调用者需用 synchronize 跳过无法解析的内容
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
        if (self.check(.kw_import)) {
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
        if (self.check(.kw_import)) {
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

        try self.reportError("expected top-level declaration (fun/type/trait/impl/use/pack/val/var)");
        return error.UnexpectedToken;
    }

    /// 解析函数声明：fun name<T>(params) : ReturnType with Bounds { body }
    fn parseFunDecl(self: *Parser, visibility: ast.Visibility) ParserError!ast.Decl {
        const fun_tok = self.advance(); // 消费 fun
        const name_tok = try self.expect(.identifier, "expected function name");

        // 类型参数
        var type_params = std.ArrayList(ast.TypeParam).empty;
        if (self.matchToken(.lt)) {
            try self.parseTypeParamList(&type_params);
            self.expectCloseAngle("expected '>' to close type parameter list") catch {};
        }

        // 参数列表
        var params = std.ArrayList(ast.Param).empty;
        _ = self.expect(.l_paren, "expected '(' to start parameter list") catch {};
        if (!self.check(.r_paren)) {
            try self.parseParamList(&params);
        }
        _ = self.expect(.r_paren, "expected ')' to close parameter list") catch {};

        // 返回类型
        var return_type: ?*ast.TypeNode = null;
        if (self.matchToken(.colon)) {
            return_type = self.parseType() catch |err| {
                return err;
            };
        }

        // Trait 约束 with Bounds
        var bounds = std.ArrayList(ast.TraitBound).empty;
        if (self.matchToken(.kw_with)) {
            try self.parseTraitBoundList(&bounds);
        }

        // 函数体
        const body = self.parseExpr() catch |err| {
            return err;
        };

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

    /// 解析类型声明：type Name<T>: Trait1, Trait2 = ... with T: ConcreteType { methods }
    fn parseTypeDecl(self: *Parser, visibility: ast.Visibility) ParserError!ast.Decl {
        const type_tok = self.advance(); // 消费 type
        const name_tok = try self.expect(.identifier, "expected type name");

        // 类型参数
        var type_params = std.ArrayList(ast.TypeParam).empty;
        if (self.matchToken(.lt)) {
            try self.parseTypeParamList(&type_params);
            self.expectCloseAngle("expected '>' to close type parameter list") catch {};
        }

        // 实现的 trait 列表：: Trait1, Trait2
        var implemented_traits = std.ArrayList(ast.TraitBound).empty;
        if (self.matchToken(.colon)) {
            try self.parseTraitBoundList(&implemented_traits);
        }

        _ = self.expect(.eq, "expected '=' to define type body") catch {};

        var def = try self.parseTypeDef();

        // 修正 error_newtype 的 name：文档语法 type FileError = Error("msg")
        // 中 FileError 才是类型名，Error("msg") 只是定义体
        if (def == .error_newtype) {
            def.error_newtype.name = name_tok.lexeme;
        }

        // 类型特化约束：with T: ConcreteType
        var type_constraints = std.ArrayList(ast.TypeConstraint).empty;
        if (self.matchToken(.kw_with)) {
            try self.parseTypeConstraints(&type_constraints);
        }

        // 方法块：{ methods }
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
                .type_params = try type_params.toOwnedSlice(self.allocator),
                .implemented_traits = try implemented_traits.toOwnedSlice(self.allocator),
                .type_constraints = try type_constraints.toOwnedSlice(self.allocator),
                .def = def,
                .methods = try methods.toOwnedSlice(self.allocator),
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
        // 文档 §2.5.1: 多构造器枚举每个构造器须以 `|` 起始（含首个）。
        // 形如 `type Color = Red | Green`（缺前导 `|`）会把 Red 当别名解析后撞上 `|`，
        // 原先报误导性的 "expected expression"。这里给出可操作的诊断。
        if (self.check(.pipe)) {
            try self.reportError("each variant of a sum type must be prefixed with '|', including the first; for example `type Color = | Red | Green`");
            return ParserError.UnexpectedToken;
        }
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
            _ = self.expect(.r_paren, "expected ')' to close constructor fields") catch {
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
            _ = self.expect(.r_paren, "expected ')' to close constructor fields") catch {
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
        _ = self.expect(.r_paren, "expected ')'") catch return null;
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
                    // 支持尾随逗号：(name: str, age: i32,)
                    if (self.check(.r_paren)) break;
                    const field_name = self.expect(.identifier, "expected field name") catch return null;
                    _ = self.expect(.colon, "expected ':'") catch return null;
                    const field_ty = self.parseType() catch return null;
                    fields.append(self.allocator, .{
                        .name = field_name.lexeme,
                        .ty = field_ty,
                    }) catch return null;
                }
                _ = self.expect(.r_paren, "expected ')'") catch return null;
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
        _ = self.expect(.r_paren, "expected ')'") catch return null;
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
                try associated_types.append(self.allocator, try self.parseAssociatedType());
            } else {
                try methods.append(self.allocator, try self.parseMethodDecl());
            }
        }
        _ = self.expect(.r_brace, "expected '}' to close trait body") catch {};

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

        // 委托语法：= TraitName.method_name
        // 文档 2.7.2: fun to_string(self): str = Serializable.to_string
        var delegate: ?ast.DelegateInfo = null;
        var body: ?*ast.Expr = null;

        if (self.matchToken(.eq)) {
            // 解析 TraitName.method_name
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
            .type_params = try type_params.toOwnedSlice(self.allocator),
            .params = try params.toOwnedSlice(self.allocator),
            .return_type = return_type,
            .body = body,
            .is_override = is_override,
            .delegate = delegate,
            .visibility = visibility,
        };
    }

    /// 解析 Impl 声明：impl TraitName<Type> { methods }
    fn parseImplDecl(self: *Parser, visibility: ast.Visibility) ParserError!ast.Decl {
        const impl_tok = self.advance(); // 消费 impl
        const name_tok = try self.expect(.identifier, "expected trait name");

        var type_args = std.ArrayList(*ast.TypeNode).empty;
        if (self.matchToken(.lt)) {
            try self.parseTypeArgList(&type_args);
            self.expectCloseAngle("expected '>'") catch {};
        }

        // 提取目标类型名（如 impl Comparable<i32> 中的 "i32"）
        var type_name: []const u8 = "";
        if (type_args.items.len > 0) {
            switch (type_args.items[0].*) {
                .named => |n| type_name = n.name,
                .generic => |g| type_name = g.name,
                else => {},
            }
        }

        // 条件约束 with Bounds（参数化条件实现）：impl Show<Box<T>> with Show<T>
        // 与 parseFunDecl 同构，复用 parseTraitBoundList。
        var bounds = std.ArrayList(ast.TraitBound).empty;
        if (self.matchToken(.kw_with)) {
            try self.parseTraitBoundList(&bounds);
        }

        var assoc_type_defs = std.ArrayList(ast.AssociatedTypeDef).empty;
        var methods = std.ArrayList(ast.MethodDecl).empty;
        _ = self.expect(.l_brace, "expected '{'") catch {};
        while (!self.check(.r_brace) and !self.isAtEnd()) {
            // 解析关联类型定义：type Item = i32
            if (self.check(.kw_type)) {
                const type_tok = self.advance();
                const assoc_name = try self.expect(.identifier, "expected associated type name");
                if (self.matchToken(.eq)) {
                    const actual_type = try self.parseType();
                    try assoc_type_defs.append(self.allocator, ast.AssociatedTypeDef{
                        .location = tokenLoc(type_tok),
                        .name = assoc_name.lexeme,
                        .actual_type = actual_type,
                    });
                }
            } else {
                try methods.append(self.allocator, try self.parseMethodDecl());
            }
        }
        _ = self.expect(.r_brace, "expected '}'") catch {};

        return ast.Decl{
            .impl_decl = .{
                .location = tokenLoc(impl_tok),
                .trait_name = name_tok.lexeme,
                .type_name = type_name,
                .type_args = try type_args.toOwnedSlice(self.allocator),
                .associated_type_defs = try assoc_type_defs.toOwnedSlice(self.allocator),
                .methods = try methods.toOwnedSlice(self.allocator),
                .bounds = try bounds.toOwnedSlice(self.allocator),
                .visibility = visibility,
            },
        };
    }

    /// 解析 use 声明：use Module.{items}
    fn parseUseDecl(self: *Parser, visibility: ast.Visibility) ParserError!ast.Decl {
        const use_tok = self.advance(); // 消费 use

        var module_path = std.ArrayList([]const u8).empty;
        const first = try self.expect(.identifier, "expected module name");
        try module_path.append(self.allocator, first.lexeme);

        while (self.matchToken(.dot)) {
            if (self.check(.l_brace)) break;
            const part = try self.expect(.identifier, "expected module path segment");
            try module_path.append(self.allocator, part.lexeme);
        }

        var items: ?[]ast.ImportItem = null;
        // `use Mod.{...}` 进入 brace 列表前的 `.` 已被上面的 while 消费，
        // 此时 previous() 是 `.`、当前是 `{`；`use Mod.Sub.{...}` 同理。
        // 因此条件是「当前已在 `{`」或「再吃一个 `.` 后是 `{`」。
        if (self.check(.l_brace) or self.matchToken(.dot)) {
            _ = self.expect(.l_brace, "expected '{'") catch {};
            var item_list = std.ArrayList(ast.ImportItem).empty;
            if (!self.check(.r_brace)) {
                try item_list.append(self.allocator, try self.parseImportItem());
                while (self.matchToken(.comma)) {
                    if (self.check(.r_brace)) break;
                    try item_list.append(self.allocator, try self.parseImportItem());
                }
            }
            _ = self.expect(.r_brace, "expected '}'") catch {};
            items = try item_list.toOwnedSlice(self.allocator);
        }

        return ast.Decl{
            .import_decl = .{
                .location = tokenLoc(use_tok),
                .module_path = try module_path.toOwnedSlice(self.allocator),
                .items = items,
                .visibility = visibility,
            },
        };
    }

    /// 解析单个 use 导入项
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

    /// 解析 pack 声明：[pub] pack Name
    fn parsePackDecl(self: *Parser, visibility: ast.Visibility) ParserError!ast.Decl {
        const pack_tok = self.advance(); // 消费 pack
        const name_tok = try self.expect(.identifier, "expected pack name");

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
        const name_tok = try self.expect(.identifier, "expected type parameter name");

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
            _ = self.expect(.r_paren, "expected ')'") catch {};
            return kind;
        }
        try self.reportError("expected kind (* or arrow kind)");
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

        const name_tok = try self.expect(.identifier, "expected parameter name");
        // 复制参数名以确保生命周期独立于源代码
        const name_copy = try self.allocator.dupe(u8, name_tok.lexeme);

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
            .name = name_copy,
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
        const name_tok = try self.expect(.identifier, "expected trait name");

        var type_args = std.ArrayList(*ast.TypeNode).empty;
        if (self.matchToken(.lt)) {
            try self.parseTypeArgList(&type_args);
            self.expectCloseAngle("expected '>'") catch {};
        }

        return ast.TraitBound{
            .trait_name = name_tok.lexeme,
            .type_args = try type_args.toOwnedSlice(self.allocator),
        };
    }

    /// 解析类型特化约束：with T: ConcreteType, U: AnotherType
    fn parseTypeConstraints(self: *Parser, constraints: *std.ArrayList(ast.TypeConstraint)) ParserError!void {
        try constraints.append(self.allocator, try self.parseTypeConstraint());
        while (self.matchToken(.comma)) {
            try constraints.append(self.allocator, try self.parseTypeConstraint());
        }
    }

    /// 解析单个类型约束：T: ConcreteType
    fn parseTypeConstraint(self: *Parser) ParserError!ast.TypeConstraint {
        const type_param_tok = try self.expect(.identifier, "expected type parameter name");
        _ = try self.expect(.colon, "expected ':' after type parameter");
        const concrete_type = try self.parseType();

        return ast.TypeConstraint{
            .type_param = type_param_tok.lexeme,
            .concrete_type = concrete_type,
        };
    }

    /// 解析方法块：{ fun method1() { ... } fun method2() { ... } }
    fn parseMethodBlock(self: *Parser, methods: *std.ArrayList(ast.MethodDecl)) ParserError!void {
        while (!self.check(.r_brace) and !self.isAtEnd()) {
            // 解析方法声明
            const method = try self.parseMethodDecl();
            try methods.append(self.allocator, method);
        }
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
        // 文档 §2.8.2 函数类型语法：
        //   A -> B            单参数（由下方 left -> ret 处理）
        //   () -> C           零参数
        //   (A, B) -> C       多参数（语法糖，flat fn_type）
        // 普通 `(field: T, ...)` 是记录类型，由 parsePrimaryType 处理。
        // 仅当 `(` ... 匹配的 `)` 后紧跟 `->` 时，才把括号组解释为函数类型形参列表。
        if (self.check(.l_paren) and self.parenGroupFollowedByArrow()) {
            const loc = tokenLoc(self.peek());
            _ = self.advance(); // (
            var params = std.ArrayList(*ast.TypeNode).empty;
            if (!self.check(.r_paren)) {
                try params.append(self.allocator, try self.parseType());
                while (self.matchToken(.comma)) {
                    if (self.check(.r_paren)) break;
                    try params.append(self.allocator, try self.parseType());
                }
            }
            _ = self.expect(.r_paren, "expected ')'") catch {};
            _ = self.expect(.minus_gt, "expected '->'") catch {};
            const ret = try self.parseType();
            return self.allocType(ast.TypeNode{
                .function = .{
                    .location = loc,
                    .params = try params.toOwnedSlice(self.allocator),
                    .return_type = ret,
                },
            });
        }

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

    /// 从当前 `(` 向前扫描到与之匹配的 `)`，判断其后是否紧跟 `->`。
    /// 用于在类型位置区分函数类型 `(A, B) -> C` 与记录类型 `(name: T, ...)`。
    /// 只看括号配平，不解析内容；嵌套括号/尖括号一并计入深度。
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

    fn parseNullableType(self: *Parser) ParserError!*ast.TypeNode {
        var ty = try self.parsePrimaryType();
        while (self.matchToken(.question)) {
            const location = getTypeNodeLocation(ty);
            // 文档 D20: T?? 扁平化为 T?
            // 如果内部已经是 nullable，直接复用（不嵌套）
            switch (ty.*) {
                .nullable => {
                    // T? 已经是 nullable，T?? 等价于 T?，跳过嵌套
                },
                else => {
                    ty = try self.allocType(ast.TypeNode{
                        .nullable = .{
                            .location = location,
                            .inner = ty,
                        },
                    });
                },
            }
        }
        return ty;
    }

    fn parsePrimaryType(self: *Parser) ParserError!*ast.TypeNode {
        if (self.check(.l_paren)) {
            return self.parseRecordType();
        }

        const name_tok = try self.expect(.identifier, "expected type name");
        const location = tokenLoc(name_tok);

        var ty: *ast.TypeNode = undefined;

        if (self.matchToken(.lt)) {
            var args = std.ArrayList(*ast.TypeNode).empty;
            try args.append(self.allocator, try self.parseType());
            while (self.matchToken(.comma)) {
                try args.append(self.allocator, try self.parseType());
            }
            self.expectCloseAngle("expected '>' to close type parameters") catch {};

            ty = try self.allocType(ast.TypeNode{
                .generic = .{
                    .location = location,
                    .name = name_tok.lexeme,
                    .args = try args.toOwnedSlice(self.allocator),
                },
            });
        } else {
            ty = try self.allocType(ast.TypeNode{
                .named = .{
                    .location = location,
                    .name = name_tok.lexeme,
                },
            });
        }

        // 支持 T[N] 和 T[] 数组类型语法（命名类型与泛型类型均可，如 i32[]、Spawn<i32>[]）
        while (self.matchToken(.l_bracket)) {
            const arr_location = tokenLoc(name_tok);
            var size: ?u64 = null;
            if (!self.check(.r_bracket)) {
                // 解析大小表达式（必须是整数）
                const size_tok = try self.expect(.int_literal, "expected array size");
                size = std.fmt.parseInt(u64, size_tok.lexeme, 10) catch {
                    try self.reportError("array size must be a positive integer");
                    return error.UnexpectedToken;
                };
            }
            _ = self.expect(.r_bracket, "expected ']'") catch {};
            ty = try self.allocType(ast.TypeNode{
                .array = .{
                    .location = arr_location,
                    .element_type = ty,
                    .size = size,
                },
            });
        }

        return ty;
    }

    fn parseRecordType(self: *Parser) ParserError!*ast.TypeNode {
        const lparen = self.advance(); // 消费 (
        const location = tokenLoc(lparen);

        var fields = std.ArrayList(ast.RecordFieldType).empty;

        if (!self.check(.r_paren)) {
            const name_tok = try self.expect(.identifier, "expected field name");
            _ = self.expect(.colon, "expected ':'") catch {};
            const ty = try self.parseType();
            try fields.append(self.allocator, .{
                .name = name_tok.lexeme,
                .ty = ty,
            });

            while (self.matchToken(.comma)) {
                if (self.check(.r_paren)) break;
                const field_name = try self.expect(.identifier, "expected field name");
                _ = self.expect(.colon, "expected ':'") catch {};
                const field_ty = try self.parseType();
                try fields.append(self.allocator, .{
                    .name = field_name.lexeme,
                    .ty = field_ty,
                });
            }
        }

        _ = self.expect(.r_paren, "expected ')'") catch {};

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
        var left = try self.parseBitOr();
        while (self.matchToken(.amp_amp)) {
            const op_tok = self.previous();
            const right = try self.parseBitOr();
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

    fn parseBitOr(self: *Parser) ParserError!*ast.Expr {
        var left = try self.parseBitXor();
        while (self.matchToken(.pipe)) {
            const op_tok = self.previous();
            const right = try self.parseBitXor();
            left = try self.allocExpr(ast.Expr{
                .binary = .{
                    .location = tokenLoc(op_tok),
                    .op = .bit_or,
                    .left = left,
                    .right = right,
                },
            });
        }
        return left;
    }

    fn parseBitXor(self: *Parser) ParserError!*ast.Expr {
        var left = try self.parseBitAnd();
        while (self.matchToken(.caret)) {
            const op_tok = self.previous();
            const right = try self.parseBitAnd();
            left = try self.allocExpr(ast.Expr{
                .binary = .{
                    .location = tokenLoc(op_tok),
                    .op = .bit_xor,
                    .left = left,
                    .right = right,
                },
            });
        }
        return left;
    }

    fn parseBitAnd(self: *Parser) ParserError!*ast.Expr {
        var left = try self.parseEquality();
        while (self.matchToken(.ampersand)) {
            const op_tok = self.previous();
            const right = try self.parseEquality();
            left = try self.allocExpr(ast.Expr{
                .binary = .{
                    .location = tokenLoc(op_tok),
                    .op = .bit_and,
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
            } else if (self.matchToken(.plus_plus)) {
                // ++：数组/列表拼接，与 + 同优先级、左结合
                const op_tok = self.previous();
                const right = try self.parseMultiplication();
                left = try self.allocExpr(ast.Expr{
                    .binary = .{
                        .location = tokenLoc(op_tok),
                        .op = .concat_list,
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
            // 优化：-int_literal 合并为负整数字面量，避免 -2147483648 等边界值溢出
            if (self.check(.int_literal)) {
                const lit_tok = self.advance();
                return self.parseNegativeIntLiteral(op_tok, lit_tok);
            }
            // 优化：-float_literal 合并为负浮点字面量
            if (self.check(.float_literal)) {
                const lit_tok = self.advance();
                return self.parseNegativeFloatLiteral(op_tok, lit_tok);
            }
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
                const field_tok = try self.expect(.identifier, "expected field or method name");

                if (self.check(.l_paren)) {
                    var args = std.ArrayList(*ast.Expr).empty;
                    var type_args: ?[]*ast.TypeNode = null;
                    if (self.matchToken(.lt)) {
                        var ta = std.ArrayList(*ast.TypeNode).empty;
                        try self.parseTypeArgList(&ta);
                        self.expectCloseAngle("expected '>'") catch {};
                        type_args = try ta.toOwnedSlice(self.allocator);
                    }
                    _ = self.expect(.l_paren, "expected '('") catch {};
                    if (!self.check(.r_paren)) {
                        try args.append(self.allocator, try self.parseExpr());
                        while (self.matchToken(.comma)) {
                            try args.append(self.allocator, try self.parseExpr());
                        }
                    }
                    _ = self.expect(.r_paren, "expected ')'") catch {};

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
                const field_tok = try self.expect(.identifier, "expected field or method name");

                if (self.check(.l_paren)) {
                    var args = std.ArrayList(*ast.Expr).empty;
                    var type_args: ?[]*ast.TypeNode = null;
                    if (self.matchToken(.lt)) {
                        var ta = std.ArrayList(*ast.TypeNode).empty;
                        try self.parseTypeArgList(&ta);
                        self.expectCloseAngle("expected '>'") catch {};
                        type_args = try ta.toOwnedSlice(self.allocator);
                    }
                    _ = self.expect(.l_paren, "expected '('") catch {};
                    if (!self.check(.r_paren)) {
                        try args.append(self.allocator, try self.parseExpr());
                        while (self.matchToken(.comma)) {
                            try args.append(self.allocator, try self.parseExpr());
                        }
                    }
                    _ = self.expect(.r_paren, "expected ')'") catch {};

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
                // 文档 D69: 禁止链式调用 f(a)(b)
                // 默认柯里化下，f(a)(b) 是语法错误，必须绑定中间结果
                if (expr_node.* == .call) {
                    const tok = self.peek();
                    try self.errors.append(self.allocator, ParseError{
                        .line = tok.line,
                        .column = tok.column,
                        .message = "chained call f(a)(b) is not allowed; use default currying: bind the partial result to a variable first",
                    });
                    return error.UnexpectedToken;
                }
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

                _ = self.expect(.l_paren, "expected '('") catch {};
                if (!self.check(.r_paren)) {
                    try args.append(self.allocator, try self.parseExpr());
                    while (self.matchToken(.comma)) {
                        try args.append(self.allocator, try self.parseExpr());
                    }
                }
                _ = self.expect(.r_paren, "expected ')'") catch {};

                expr_node = try self.allocExpr(ast.Expr{
                    .call = .{
                        .location = tokenLoc(call_tok),
                        .callee = expr_node,
                        .arguments = try args.toOwnedSlice(self.allocator),
                        .type_args = type_args,
                    },
                });
            } else if (self.check(.lt) and self.isTurbofishCall()) {
                // Turbofish 泛型调用：callee<TypeArgs>(args)，如 channel<i32>(0)
                // 仅当 <...> 之后紧跟 ( 时才解析为调用，否则交给比较运算符。
                // isTurbofishCall() 已确认该形态，这里的解析必定成功。
                _ = self.matchToken(.lt);
                var ta = std.ArrayList(*ast.TypeNode).empty;
                try self.parseTypeArgList(&ta);
                self.expectCloseAngle("expected '>'") catch {};
                const type_args: ?[]*ast.TypeNode = try ta.toOwnedSlice(self.allocator);

                // 禁止链式调用 f(a)(b)（与下方 l_paren 分支一致）
                if (expr_node.* == .call) {
                    const tok = self.peek();
                    try self.errors.append(self.allocator, ParseError{
                        .line = tok.line,
                        .column = tok.column,
                        .message = "chained call f(a)(b) is not allowed; use default currying: bind the partial result to a variable first",
                    });
                    return error.UnexpectedToken;
                }
                const call_tok = self.peek();
                var args = std.ArrayList(*ast.Expr).empty;
                _ = self.expect(.l_paren, "expected '('") catch {};
                if (!self.check(.r_paren)) {
                    try args.append(self.allocator, try self.parseExpr());
                    while (self.matchToken(.comma)) {
                        try args.append(self.allocator, try self.parseExpr());
                    }
                }
                _ = self.expect(.r_paren, "expected ')'") catch {};

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
                _ = self.expect(.r_bracket, "expected ']'") catch {};

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

    /// 前瞻：判断当前位置的 `<` 是否开启一个 turbofish 泛型调用 `<TypeArgs>(`。
    /// 从当前 `<` 开始，平衡嵌套的 `<`/`>`（`>>` 在本语言中词法上是两个 `gt`），
    /// 在匹配到最外层 `>` 后检查紧随的 token 是否为 `(`。
    /// 不消费任何 token——只读 self.tokens。
    /// 这样 `a < b` 比较不会被误判，而 `channel<i32>(0)` / `foo<A, B>(x)` 会被识别。
    fn isTurbofishCall(self: *Parser) bool {
        if (!self.check(.lt)) return false;
        var i = self.current + 1;
        var depth: usize = 1;
        // 限定一个合理的前瞻上限，避免在病态输入上扫描过远
        var steps: usize = 0;
        while (i < self.tokens.len and steps < 256) : (steps += 1) {
            const tt = self.tokens[i].type;
            switch (tt) {
                .lt => depth += 1,
                .gt => {
                    depth -= 1;
                    if (depth == 0) {
                        // 最外层 `>` 之后必须紧跟 `(` 才是调用
                        return i + 1 < self.tokens.len and self.tokens[i + 1].type == .l_paren;
                    }
                },
                // 这些 token 不可能出现在类型实参列表中，提前否决
                // （类型实参里只会出现标识符、`<` `>` `,` `?` `(` `)` `->` 等）
                .l_brace, .r_brace, .eq, .eq_gt, .eof => return false,
                else => {},
            }
            i += 1;
        }
        return false;
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

        if (self.matchToken(.kw_atomic)) {
            return self.parseAtomicExpr();
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

        // `type` 是关键字（type Foo = ...），但内建函数 type(x) 也用这个名字。
        // 仅当 `type` 紧跟 `(` 时，按内建函数标识符处理；否则仍是类型定义关键字。
        if (self.check(.kw_type) and
            self.tokens.len > self.current + 1 and
            self.tokens[self.current + 1].type == .l_paren)
        {
            const tok = self.advance();
            return self.allocExpr(ast.Expr{
                .identifier = .{
                    .location = tokenLoc(tok),
                    .name = tok.lexeme,
                },
            });
        }

        if (self.check(.identifier) or self.check(.kw_val) or self.check(.kw_var) or self.check(.kw_channel)) {
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

        try self.reportError("expected expression");
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
                .raw = raw[0..i],
                .suffix = suffix,
            },
        });
    }

    /// 解析负整数字面量（如 -2147483648），将负号合并到 raw 中
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
        // 合并负号：raw = "-" + lit_raw（不含后缀）
        const neg_raw = try std.fmt.allocPrint(self.allocator, "-{s}", .{lit_raw[0..i]});
        return self.allocExpr(ast.Expr{
            .int_literal = .{
                .location = tokenLoc(lit_tok),
                .raw = neg_raw,
                .suffix = suffix,
            },
        });
    }

    /// 解析负浮点字面量（如 -3.14），将负号合并到 raw 中
    fn parseNegativeFloatLiteral(self: *Parser, minus_tok: lexer.Token, lit_tok: lexer.Token) ParserError!*ast.Expr {
        _ = minus_tok;
        var suffix: ?[]const u8 = null;
        const lit_raw = lit_tok.lexeme;
        var i: usize = lit_raw.len;
        // 后缀可能包含字母和数字（如 f16, f128），先跳过末尾数字，再跳过字母
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
        // 确保至少有一个字母开头（避免把纯数字当作后缀）
        if (i < lit_raw.len and i > 0 and ((lit_raw[i] >= 'a' and lit_raw[i] <= 'z') or (lit_raw[i] >= 'A' and lit_raw[i] <= 'Z'))) {
            suffix = lit_raw[i..];
        } else {
            i = lit_raw.len;
        }
        // 合并负号：raw = "-" + lit_raw（不含后缀）
        const neg_raw = try std.fmt.allocPrint(self.allocator, "-{s}", .{lit_raw[0..i]});
        return self.allocExpr(ast.Expr{
            .float_literal = .{
                .location = tokenLoc(lit_tok),
                .raw = neg_raw,
                .suffix = suffix,
            },
        });
    }

    fn parseFloatLiteral(self: *Parser, tok: lexer.Token) ParserError!*ast.Expr {
        var suffix: ?[]const u8 = null;
        const raw = tok.lexeme;
        var i: usize = raw.len;
        // 后缀可能包含字母和数字（如 f16, f128），先跳过末尾数字，再跳过字母
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
        // 确保至少有一个字母开头（避免把纯数字当作后缀）
        if (i < raw.len and i > 0 and ((raw[i] >= 'a' and raw[i] <= 'z') or (raw[i] >= 'A' and raw[i] <= 'Z'))) {
            suffix = raw[i..];
        } else {
            i = raw.len;
        }
        return self.allocExpr(ast.Expr{
            .float_literal = .{
                .location = tokenLoc(tok),
                .raw = raw[0..i],
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
        _ = self.expect(.l_paren, "expected '('") catch {};
        if (!self.check(.r_paren)) {
            try self.parseParamList(&params);
        }
        _ = self.expect(.r_paren, "expected ')'") catch {};

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

        _ = self.expect(.l_brace, "expected '{'") catch {};

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

        _ = self.expect(.r_brace, "expected '}'") catch {};

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

        _ = self.expect(.eq_gt, "expected '=>'") catch {};
        // match 分支体通常是表达式，但 throw/return/break/continue 是语句。
        // 允许它们作为裸分支体（如 `Nil => throw Err(...)`），包装成单语句块表达式。
        const body = if (self.check(.kw_throw) or self.check(.kw_return) or
            self.check(.kw_break) or self.check(.kw_continue))
        blk: {
            const stmt_tok = self.peek();
            const stmt = try self.parseStmt();
            var stmts = std.ArrayList(*ast.Stmt).empty;
            try stmts.append(self.allocator, stmt);
            break :blk try self.allocExpr(ast.Expr{
                .block = .{
                    .location = tokenLoc(stmt_tok),
                    .statements = try stmts.toOwnedSlice(self.allocator),
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

    fn parseSpawnExpr(self: *Parser) ParserError!*ast.Expr {
        const spawn_tok = self.previous();
        // spawn body 只解析一个基本表达式（通常是 block），
        // 不贪婪消费后续的方法调用/字段访问（如 .await()）
        const body = try self.parsePrimary();

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

    /// atomic expr — 解析为 atomic_expr AST 节点
    /// 文档 §3.4.1: `atomic expr` 在堆上创建原子值，返回 Atomic<T> 引用
    /// atomic 是关键字前缀表达式，不是函数调用
    fn parseAtomicExpr(self: *Parser) ParserError!*ast.Expr {
        const atomic_tok = self.previous();
        const value_expr = try self.parsePrimary();

        return self.allocExpr(ast.Expr{
            .atomic_expr = .{
                .location = tokenLoc(atomic_tok),
                .value = value_expr,
            },
        }) catch return error.OutOfMemory;
    }

    fn parseSelectExpr(self: *Parser) ParserError!*ast.Expr {
        const select_tok = self.previous();
        _ = self.expect(.l_brace, "expected '{'") catch {};

        var arms = std.ArrayList(ast.SelectArm).empty;
        while (!self.check(.r_brace) and !self.isAtEnd()) {
            try arms.append(self.allocator, try self.parseSelectArm());
            // 消费可选的逗号分隔符
            _ = self.matchToken(.comma);
        }
        _ = self.expect(.r_brace, "expected '}'") catch {};

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

        // 文档 §3.5.3: 接收分支支持两种形态
        //   ch.recv() => name => body   绑定收到的值到 name
        //   ch.recv() => body           不绑定
        // 区分：第一个 `=>` 之后若是「标识符 紧跟 `=>`」，则该标识符是绑定名。
        var binding: ?[]const u8 = null;
        if (self.check(.identifier) and
            self.current + 1 < self.tokens.len and
            self.tokens[self.current + 1].type == .eq_gt)
        {
            const name_tok = self.advance(); // 标识符
            _ = self.advance(); // 第二个 `=>`
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

    fn parseMonadExpr(self: *Parser) ParserError!*ast.Expr {
        const at_tok = self.previous();
        const type_tok = try self.expect(.identifier, "expected monad type name");
        _ = self.expect(.l_brace, "expected '{'") catch {};

        // 文档 §2.11.2: @M { x <- e1  y <- e2  result }
        // 解析零或多个绑定 `name <- expr`，最后一个非绑定表达式是 result。
        // 绑定的判定：标识符紧跟 `<-`。
        var bindings = std.ArrayList(ast.MonadBinding).empty;
        var result: ?*ast.Expr = null;
        while (!self.check(.r_brace) and !self.isAtEnd()) {
            if (self.check(.identifier) and
                self.current + 1 < self.tokens.len and
                self.tokens[self.current + 1].type == .lt_minus)
            {
                const name_tok = self.advance(); // 标识符
                _ = self.advance(); // <-
                const bind_expr = try self.parseExpr();
                try bindings.append(self.allocator, ast.MonadBinding{
                    .name = name_tok.lexeme,
                    .expr = bind_expr,
                });
            } else {
                // 非绑定：作为 result 表达式（应是块内最后一个表达式）
                result = try self.parseExpr();
                break;
            }
        }
        _ = self.expect(.r_brace, "expected '}'") catch {};

        const result_expr = result orelse blk: {
            // 没有显式 result：用 unit 占位（理论上 monad 块应以结果表达式结尾）
            break :blk try self.allocExpr(ast.Expr{ .unit_literal = tokenLoc(at_tok) });
        };

        return self.allocExpr(ast.Expr{
            .monad_comprehension = .{
                .location = tokenLoc(at_tok),
                .monad_type = type_tok.lexeme,
                .bindings = try bindings.toOwnedSlice(self.allocator),
                .result = result_expr,
            },
        });
    }

    fn parseInlineTraitValue(self: *Parser) ParserError!*ast.Expr {
        const trait_tok = self.advance(); // 消费 trait
        _ = self.expect(.l_brace, "expected '{'") catch {};

        var methods = std.ArrayList(ast.MethodDecl).empty;
        while (!self.check(.r_brace) and !self.isAtEnd()) {
            try methods.append(self.allocator, try self.parseMethodDecl());
        }
        _ = self.expect(.r_brace, "expected '}'") catch {};

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
        _ = self.expect(.r_bracket, "expected ']'") catch {};

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
                const stmt = self.parseStmt() catch |err| {
                    return err;
                };
                // 匿名 lambda（fun(...){...}）经 parseFunStmt 包装成 .expression 语句。
                // 若它是块内最后一项（后紧跟 }），应作为尾表达式，使块的求值/类型
                // 结果为该 lambda（函数类型），而非 Unit。命名 fun 会变成 val_decl，
                // 不受影响。
                if (stmt.* == .expression and self.check(.r_brace)) {
                    trailing_expr = stmt.expression.expr;
                    break;
                }
                try statements.append(self.allocator, stmt);
            } else {
                // 使用 parseExprOrAssignmentStmt 处理赋值语句（如 x = 10）
                const stmt = self.parseExprOrAssignmentStmt() catch |err| {
                    return err;
                };
                // 检查是否是尾表达式（纯表达式语句且后面紧跟 }）
                if (stmt.* == .expression and self.check(.r_brace)) {
                    trailing_expr = stmt.expression.expr;
                    break;
                }
                try statements.append(self.allocator, stmt);
            }
        }

        _ = self.expect(.r_brace, "expected '}'") catch {};

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

        // 尝试解析为记录字面量（可能包含 ...spread 扩展）
        // Phase 3: 支持 (...expr, field: val) 记录扩展语法
        if (self.peek().type == .identifier or self.peek().type == .ellipsis) {
            // 检查是否以 ... 开头（记录扩展）
            if (self.peek().type == .ellipsis) {
                _ = self.advance(); // 消费 ...
                const base_expr = try self.parseExpr();
                var updates = std.ArrayList(ast.RecordFieldExpr).empty;
                // 解析后续的 , field: val
                while (self.matchToken(.comma)) {
                    if (self.check(.r_paren)) break;
                    const field_name = try self.expect(.identifier, "expected field name");
                    _ = self.expect(.colon, "expected ':'") catch {};
                    const field_value = try self.parseExpr();
                    try updates.append(self.allocator, .{
                        .name = field_name.lexeme,
                        .value = field_value,
                    });
                }
                _ = self.expect(.r_paren, "expected ')'") catch {};
                return self.allocExpr(ast.Expr{
                    .record_extend = .{
                        .location = location,
                        .base = base_expr,
                        .updates = try updates.toOwnedSlice(self.allocator),
                    },
                });
            }

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
                    // 支持 ...spread 在字段列表中间
                    if (self.check(.ellipsis)) {
                        _ = self.advance(); // 消费 ...
                        const base_expr = try self.parseExpr();
                        var updates = std.ArrayList(ast.RecordFieldExpr).empty;
                        // 将已有的字段加入 updates
                        for (fields.items) |f| {
                            try updates.append(self.allocator, f);
                        }
                        // 解析后续的 , field: val
                        while (self.matchToken(.comma)) {
                            if (self.check(.r_paren)) break;
                            const field_name = try self.expect(.identifier, "expected field name");
                            _ = self.expect(.colon, "expected ':'") catch {};
                            const field_value = try self.parseExpr();
                            try updates.append(self.allocator, .{
                                .name = field_name.lexeme,
                                .value = field_value,
                            });
                        }
                        _ = self.expect(.r_paren, "expected ')'") catch {};
                        return self.allocExpr(ast.Expr{
                            .record_extend = .{
                                .location = location,
                                .base = base_expr,
                                .updates = try updates.toOwnedSlice(self.allocator),
                            },
                        });
                    }
                    const field_name = try self.expect(.identifier, "expected field name");
                    _ = self.expect(.colon, "expected ':'") catch {};
                    const field_value = try self.parseExpr();
                    try fields.append(self.allocator, .{
                        .name = field_name.lexeme,
                        .value = field_value,
                    });
                }
                _ = self.expect(.r_paren, "expected ')'") catch {};
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

        // 文档 D71: 无匿名元组，记录必须有命名字段
        // (expr, expr, ...) 语法被禁止
        if (self.matchToken(.comma)) {
            const loc = tokenLoc(lparen_tok);
            try self.errors.append(self.allocator, ParseError{
                .line = loc.line,
                .column = loc.column,
                .message = "anonymous tuples are not allowed; use named record fields like (name: value, ...)",
            });
            // 错误恢复：跳到右括号
            while (!self.check(.r_paren) and !self.isAtEnd()) {
                _ = self.advance();
            }
            _ = self.matchToken(.r_paren);
            // 返回第一个表达式作为恢复结果
            return first_expr;
        }

        // 单个表达式 = 括号表达式
        _ = self.expect(.r_paren, "expected ')'") catch {};
        return first_expr;
    }

    fn tryParseLambda(self: *Parser, saved: usize, location: ast.SourceLocation) ?*ast.Expr {
        const saved_error_count = self.errors.items.len;
        var params = std.ArrayList(ast.Param).empty;
        if (!self.check(.r_paren)) {
            self.parseLambdaParamList(&params) catch {
                // 回滚尝试 lambda 时产生的虚假错误消息
                self.errors.shrinkRetainingCapacity(saved_error_count);
                return null;
            };
        }
        if (!self.check(.r_paren)) {
            self.errors.shrinkRetainingCapacity(saved_error_count);
            return null;
        }
        _ = self.advance(); // 消费 )

        if (!self.check(.eq_gt)) {
            self.current = saved;
            self.errors.shrinkRetainingCapacity(saved_error_count);
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

    fn parseTypeCast(self: *Parser) ParserError!*ast.Expr {
        const name_tok = self.advance(); // 消费类型名
        const location = tokenLoc(name_tok);

        const target_type = try self.allocType(ast.TypeNode{
            .named = .{
                .location = location,
                .name = name_tok.lexeme,
            },
        });

        _ = self.expect(.l_paren, "expected '('") catch {};
        const expr = try self.parseExpr();
        _ = self.expect(.r_paren, "expected ')'") catch {};

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
        var left = try self.parsePrimaryPattern();
        while (self.matchToken(.pipe)) {
            const pipe_tok = self.previous();
            const right = try self.parsePrimaryPattern();
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

        // kw_val/kw_var 在模式上下文中作为变量名使用
        // 例如 Ok(val) 中的 val 会被词法分析器识别为 kw_val
        if (self.check(.kw_val) or self.check(.kw_var)) {
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
                _ = self.expect(.r_paren, "expected ')'") catch {};
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
                _ = self.expect(.r_paren, "expected ')'") catch {};
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

        try self.reportError("expected pattern");
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
                        const field_name = try self.expect(.identifier, "expected field name");
                        _ = self.expect(.colon, "expected ':'") catch {};
                        const field_pattern = try self.parsePattern();
                        try fields.append(self.allocator, .{
                            .name = field_name.lexeme,
                            .pattern = field_pattern,
                        });
                    }
                    _ = self.expect(.r_paren, "expected ')'") catch {};
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
        _ = self.expect(.r_paren, "expected ')'") catch {};

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
            _ = self.expect(.l_paren, "expected '('") catch {};
            if (!self.check(.r_paren)) {
                try self.parseParamList(&params);
            }
            _ = self.expect(.r_paren, "expected ')'") catch {};

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
        _ = self.expect(.l_paren, "expected '('") catch {};
        if (!self.check(.r_paren)) {
            try self.parseParamList(&params);
        }
        _ = self.expect(.r_paren, "expected ')'") catch {};

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
        const name_tok = try self.expect(.identifier, "expected variable name");

        var type_annotation: ?*ast.TypeNode = null;
        if (self.matchToken(.colon)) {
            type_annotation = try self.parseType();
        }

        _ = self.expect(.eq, "expected '='") catch {};
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
        const name_tok = try self.expect(.identifier, "expected variable name");

        var type_annotation: ?*ast.TypeNode = null;
        if (self.matchToken(.colon)) {
            type_annotation = try self.parseType();
        }

        _ = self.expect(.eq, "expected '='") catch {};
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
        const name_tok = try self.expect(.identifier, "expected iterator variable name");
        _ = self.expect(.kw_in, "expected 'in'") catch {};
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

        // 复合赋值运算符：+=, -=, *=, /=, %=, &=, |=
        const compound_op = self.peekCompoundAssign();
        if (compound_op != null) {
            _ = self.advance();
            const op_tok = self.previous();
            const value = try self.parseExpr();
            const op = compound_op.?;

            return self.allocStmt(ast.Stmt{
                .compound_assignment = .{
                    .location = tokenLoc(op_tok),
                    .target = expr,
                    .op = op,
                    .value = value,
                },
            });
        }

        return self.allocStmt(ast.Stmt{
            .expression = .{
                .location = getExprLocation(expr),
                .expr = expr,
            },
        });
    }

    /// 检查当前 token 是否为复合赋值运算符，返回对应的 CompoundAssignOp
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
            else => null,
        };
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
        .self_type => |s| s.location,
        .generic => |g| g.location,
        .nullable => |n| n.location,
        .function => |f| f.location,
        .record => |r| r.location,
        .array => |a| a.location,
        .kind_annotated => |k| k.location,
    };
}

/// 获取表达式的源位置
fn getExprLocation(expr: *const ast.Expr) ast.SourceLocation {
    return ast.exprLocation(expr);
}

/// 判断标识符是否为内建类型名（用于类型转换判断）
fn isBuiltinType(name: []const u8) bool {
    const builtin_types = [_][]const u8{
        "i8",   "i16",  "i32",  "i64",  "i128",
        "u8",   "u16",  "u32",  "u64",  "u128",
        "f32",  "f64",
        "bool", "str",
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
