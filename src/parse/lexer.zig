//! 词法分析器（Lexer）
//!
//! 将 Glue 源码字符串逐字符扫描为 Token 序列，支持关键字、标识符、
//! 整数（含二/八/十六进制）、浮点数、字符与字符串字面量（含插值），
//! 以及各类运算符与分隔符。Token 同时携带行列号信息以便错误定位。

const std = @import("std");

/// 词法单元类型：覆盖所有字面量、关键字、运算符与分隔符
pub const TokenType = enum {
    int_literal,
    float_literal,
    char_literal,
    string_literal,
    true_literal,
    false_literal,
    null_literal,
    kw_fun,
    kw_type,
    kw_trait,
    kw_override,
    kw_pack,
    kw_pub,
    kw_import,
    kw_with,
    kw_as,
    kw_val,
    kw_var,
    kw_match,
    kw_if,
    kw_else,
    kw_async,
    kw_channel,
    kw_select,
    kw_atomic,
    kw_spawn,
    kw_loop,
    kw_for,
    kw_in,
    kw_while,
    kw_break,
    kw_continue,
    kw_return,
    kw_throw,
    kw_lazy,
    kw_defer,
    identifier,
    plus,
    minus,
    star,
    slash,
    percent,
    eq_eq,
    bang_eq,
    lt,
    gt,
    lt_eq,
    gt_eq,
    lt_minus,
    amp_amp,
    pipe_pipe,
    bang,
    ampersand,
    caret,
    question_dot,
    question_question,
    question,
    dot_dot,
    dot_dot_eq,
    ellipsis,
    eq,
    plus_eq,
    plus_plus,
    minus_eq,
    star_eq,
    slash_eq,
    percent_eq,
    amp_eq,
    pipe_eq,
    caret_eq,
    lt_lt,
    gt_gt,
    lt_lt_eq,
    gt_gt_eq,
    tilde,
    eq_gt,
    minus_gt,
    l_paren,
    r_paren,
    l_bracket,
    r_bracket,
    l_brace,
    r_brace,
    comma,
    colon,
    dot,
    pipe,
    eof,
    err,
};

/// 词法单元：类型、字面文本、行列号
pub const Token = struct {
    type: TokenType,
    lexeme: []const u8,
    line: u32,
    column: u32,
};

/// 词法分析可能产生的错误
pub const LexerError = error{
    UnterminatedString,
    UnterminatedChar,
    UnterminatedComment,
    InvalidEscape,
    InvalidUnicodeEscape,
    InvalidNumber,
    InvalidHexDigit,
    InvalidOctalDigit,
    InvalidBinaryDigit,
    UnexpectedCharacter,
    OutOfMemory,
};

/// 词法分析器：持有源码、扫描位置与已生成 Token 列表
pub const Lexer = struct {
    source: []const u8,
    position: usize,
    line: u32,
    column: u32,
    tokens: std.ArrayList(Token),
    allocator: std.mem.Allocator,

    /// 创建词法分析器，预估 Token 容量以减少扩容
    pub fn init(allocator: std.mem.Allocator, source: []const u8) Lexer {
        var lexer = Lexer{
            .source = source,
            .position = 0,
            .line = 1,
            .column = 1,
            .tokens = .empty,
            .allocator = allocator,
        };
        const est_tokens = source.len / 5 + 16;
        lexer.tokens.ensureTotalCapacity(allocator, est_tokens) catch {};
        return lexer;
    }

    /// 释放 Token 列表
    pub fn deinit(self: *Lexer) void {
        self.tokens.deinit(self.allocator);
    }

    /// 扫描整个源码并返回 Token 切片，末尾追加 eof
    pub fn tokenize(self: *Lexer) LexerError![]Token {
        while (self.position < self.source.len) {
            try self.scanToken();
        }
        try self.tokens.append(self.allocator, Token{
            .type = .eof,
            .lexeme = "",
            .line = self.line,
            .column = self.column,
        });
        return self.tokens.toOwnedSlice(self.allocator);
    }

    /// 查看当前位置字符（不前进）
    fn peek(self: *Lexer) ?u8 {
        if (self.position >= self.source.len) return null;
        return self.source[self.position];
    }

    /// 查看下一位置字符（不前进）
    fn peekNext(self: *Lexer) ?u8 {
        if (self.position + 1 >= self.source.len) return null;
        return self.source[self.position + 1];
    }

    /// 消费当前字符并前进，遇到换行时同步更新行列号
    fn advance(self: *Lexer) ?u8 {
        if (self.position >= self.source.len) return null;
        const ch = self.source[self.position];
        self.position += 1;
        if (ch == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        return ch;
    }

    /// 当当前字符等于预期时消费并前进，返回是否匹配
    fn matchChar(self: *Lexer, expected: u8) bool {
        if (self.position >= self.source.len) return false;
        if (self.source[self.position] != expected) return false;
        self.position += 1;
        if (expected == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        return true;
    }

    /// 根据起止位置与行列号构造 Token
    fn makeToken(self: *Lexer, token_type: TokenType, start: usize, start_line: u32, start_col: u32) Token {
        return Token{
            .type = token_type,
            .lexeme = self.source[start..self.position],
            .line = start_line,
            .column = start_col,
        };
    }

    /// 构造并追加一个 Token
    fn addToken(self: *Lexer, token_type: TokenType, start: usize, start_line: u32, start_col: u32) LexerError!void {
        try self.tokens.append(self.allocator, self.makeToken(token_type, start, start_line, start_col));
    }

    /// 追加一个错误 Token（type 为 .err）
    fn addError(self: *Lexer, start: usize, start_line: u32, start_col: u32) LexerError!void {
        try self.tokens.append(self.allocator, Token{
            .type = .err,
            .lexeme = self.source[start..self.position],
            .line = start_line,
            .column = start_col,
        });
    }

    /// 扫描单个词法单元：根据首字符分派到对应的处理分支
    fn scanToken(self: *Lexer) LexerError!void {
        const start = self.position;
        const start_line = self.line;
        const start_col = self.column;
        const ch = self.advance().?;
        switch (ch) {
            // 空白字符直接跳过
            ' ', '\t', '\r', '\n' => {},
            '/' => {
                if (self.matchChar('/')) {
                    try self.skipLineComment();
                } else if (self.matchChar('*')) {
                    try self.skipBlockComment();
                } else if (self.matchChar('=')) {
                    try self.addToken(.slash_eq, start, start_line, start_col);
                } else {
                    try self.addToken(.slash, start, start_line, start_col);
                }
            },
            '(' => try self.addToken(.l_paren, start, start_line, start_col),
            ')' => try self.addToken(.r_paren, start, start_line, start_col),
            '[' => try self.addToken(.l_bracket, start, start_line, start_col),
            ']' => try self.addToken(.r_bracket, start, start_line, start_col),
            '{' => try self.addToken(.l_brace, start, start_line, start_col),
            '}' => try self.addToken(.r_brace, start, start_line, start_col),
            ',' => try self.addToken(.comma, start, start_line, start_col),
            ';' => {},
            ':' => try self.addToken(.colon, start, start_line, start_col),
            '%' => {
                if (self.matchChar('=')) {
                    try self.addToken(.percent_eq, start, start_line, start_col);
                } else {
                    try self.addToken(.percent, start, start_line, start_col);
                }
            },
            '+' => {
                if (self.matchChar('=')) {
                    try self.addToken(.plus_eq, start, start_line, start_col);
                } else if (self.matchChar('+')) {
                    try self.addToken(.plus_plus, start, start_line, start_col);
                } else {
                    try self.addToken(.plus, start, start_line, start_col);
                }
            },
            '*' => {
                if (self.matchChar('=')) {
                    try self.addToken(.star_eq, start, start_line, start_col);
                } else {
                    try self.addToken(.star, start, start_line, start_col);
                }
            },
            '|' => {
                if (self.matchChar('|')) {
                    try self.addToken(.pipe_pipe, start, start_line, start_col);
                } else if (self.matchChar('=')) {
                    try self.addToken(.pipe_eq, start, start_line, start_col);
                } else {
                    try self.addToken(.pipe, start, start_line, start_col);
                }
            },
            '=' => {
                if (self.matchChar('=')) {
                    try self.addToken(.eq_eq, start, start_line, start_col);
                } else if (self.matchChar('>')) {
                    try self.addToken(.eq_gt, start, start_line, start_col);
                } else {
                    try self.addToken(.eq, start, start_line, start_col);
                }
            },
            '!' => {
                if (self.matchChar('=')) {
                    try self.addToken(.bang_eq, start, start_line, start_col);
                } else {
                    try self.addToken(.bang, start, start_line, start_col);
                }
            },
            '<' => {
                if (self.matchChar('<')) {
                    if (self.matchChar('=')) {
                        try self.addToken(.lt_lt_eq, start, start_line, start_col);
                    } else {
                        try self.addToken(.lt_lt, start, start_line, start_col);
                    }
                } else if (self.matchChar('=')) {
                    try self.addToken(.lt_eq, start, start_line, start_col);
                } else if (self.matchChar('-')) {
                    try self.addToken(.lt_minus, start, start_line, start_col);
                } else {
                    try self.addToken(.lt, start, start_line, start_col);
                }
            },
            '>' => {
                if (self.matchChar('>')) {
                    if (self.matchChar('=')) {
                        try self.addToken(.gt_gt_eq, start, start_line, start_col);
                    } else {
                        try self.addToken(.gt_gt, start, start_line, start_col);
                    }
                } else if (self.matchChar('=')) {
                    try self.addToken(.gt_eq, start, start_line, start_col);
                } else {
                    try self.addToken(.gt, start, start_line, start_col);
                }
            },
            '-' => {
                if (self.matchChar('>')) {
                    try self.addToken(.minus_gt, start, start_line, start_col);
                } else if (self.matchChar('=')) {
                    try self.addToken(.minus_eq, start, start_line, start_col);
                } else {
                    try self.addToken(.minus, start, start_line, start_col);
                }
            },
            '.' => {
                if (self.matchChar('.')) {
                    if (self.matchChar('=')) {
                        try self.addToken(.dot_dot_eq, start, start_line, start_col);
                    } else if (self.matchChar('.')) {
                        try self.addToken(.ellipsis, start, start_line, start_col);
                    } else {
                        try self.addToken(.dot_dot, start, start_line, start_col);
                    }
                } else {
                    // 单独点号后跟数字时，按 .浮点数 处理（如 .5）
                    if (self.position < self.source.len and isDigit(self.source[self.position])) {
                        try self.scanDotFloat(start, start_line, start_col);
                    } else {
                        try self.addToken(.dot, start, start_line, start_col);
                    }
                }
            },
            '?' => {
                if (self.matchChar('.')) {
                    try self.addToken(.question_dot, start, start_line, start_col);
                } else if (self.matchChar('?')) {
                    try self.addToken(.question_question, start, start_line, start_col);
                } else {
                    try self.addToken(.question, start, start_line, start_col);
                }
            },
            '&' => {
                if (self.matchChar('&')) {
                    try self.addToken(.amp_amp, start, start_line, start_col);
                } else if (self.matchChar('=')) {
                    try self.addToken(.amp_eq, start, start_line, start_col);
                } else {
                    try self.addToken(.ampersand, start, start_line, start_col);
                }
            },
            '^' => {
                if (self.matchChar('=')) {
                    try self.addToken(.caret_eq, start, start_line, start_col);
                } else {
                    try self.addToken(.caret, start, start_line, start_col);
                }
            },
            '~' => try self.addToken(.tilde, start, start_line, start_col),
            '\'' => try self.scanChar(start, start_line, start_col),
            '"' => try self.scanString(start, start_line, start_col),
            '0'...'9' => try self.scanNumber(start, start_line, start_col),
            'a'...'z', 'A'...'Z', '_' => try self.scanIdentifier(start, start_line, start_col),
            else => {
                try self.addError(start, start_line, start_col);
            },
        }
    }

    /// 跳过行注释（// 到行尾）
    fn skipLineComment(self: *Lexer) LexerError!void {
        while (self.position < self.source.len) {
            if (self.source[self.position] == '\n') break;
            self.position += 1;
            self.column += 1;
        }
    }

    /// 跳过块注释（/* */，支持嵌套）
    fn skipBlockComment(self: *Lexer) LexerError!void {
        var depth: u32 = 1;
        while (self.position < self.source.len and depth > 0) {
            const ch = self.source[self.position];
            if (ch == '/' and self.position + 1 < self.source.len and self.source[self.position + 1] == '*') {
                depth += 1;
                self.position += 2;
                self.column += 2;
            } else if (ch == '*' and self.position + 1 < self.source.len and self.source[self.position + 1] == '/') {
                depth -= 1;
                self.position += 2;
                self.column += 2;
            } else if (ch == '\n') {
                self.position += 1;
                self.line += 1;
                self.column = 1;
            } else {
                self.position += 1;
                self.column += 1;
            }
        }
        if (depth > 0) {
            return LexerError.UnterminatedComment;
        }
    }

    /// 扫描数字字面量，自动识别二/八/十六进制前缀、小数点、指数与类型后缀
    fn scanNumber(self: *Lexer, start: usize, start_line: u32, start_col: u32) LexerError!void {
        if (self.source[start] == '0' and self.position < self.source.len) {
            const prefix = self.source[self.position];
            if (prefix == 'x' or prefix == 'X') {
                self.position += 1;
                self.column += 1;
                try self.scanHexNumber(start, start_line, start_col);
                return;
            } else if (prefix == 'o' or prefix == 'O') {
                self.position += 1;
                self.column += 1;
                try self.scanOctalNumber(start, start_line, start_col);
                return;
            } else if (prefix == 'b' or prefix == 'B') {
                self.position += 1;
                self.column += 1;
                try self.scanBinaryNumber(start, start_line, start_col);
                return;
            }
        }
        while (self.position < self.source.len and isDigit(self.source[self.position])) {
            self.position += 1;
            self.column += 1;
        }
        try self.skipUnderscoreDigits(false);
        var is_float = false;
        // 小数部分
        if (self.position < self.source.len and self.source[self.position] == '.') {
            if (self.position + 1 < self.source.len and isDigit(self.source[self.position + 1])) {
                is_float = true;
                self.position += 1;
                self.column += 1;
                while (self.position < self.source.len and isDigit(self.source[self.position])) {
                    self.position += 1;
                    self.column += 1;
                }
                try self.skipUnderscoreDigits(false);
            }
        }
        // 指数部分
        if (self.position < self.source.len and (self.source[self.position] == 'e' or self.source[self.position] == 'E')) {
            is_float = true;
            self.position += 1;
            self.column += 1;
            if (self.position < self.source.len and (self.source[self.position] == '+' or self.source[self.position] == '-')) {
                self.position += 1;
                self.column += 1;
            }
            if (self.position < self.source.len and isDigit(self.source[self.position])) {
                while (self.position < self.source.len and isDigit(self.source[self.position])) {
                    self.position += 1;
                    self.column += 1;
                }
            } else {
                return LexerError.InvalidNumber;
            }
        }
        // 类型后缀（如 i32、f64），非法后缀则回退
        if (self.position < self.source.len and isIdentifierStart(self.source[self.position])) {
            const suffix_start = self.position;
            while (self.position < self.source.len and isIdentifierContinue(self.source[self.position])) {
                self.position += 1;
                self.column += 1;
            }
            const suffix = self.source[suffix_start..self.position];
            if (isFloatSuffix(suffix)) {
                is_float = true;
            } else if (!isIntSuffix(suffix)) {
                const backtrack = self.position - suffix_start;
                self.position = suffix_start;
                self.column -= @intCast(backtrack);
            }
        }
        try self.addToken(if (is_float) .float_literal else .int_literal, start, start_line, start_col);
    }

    /// 跳过数字中的下划线分隔符（如 1_000），hex 控制是否按十六进制判断
    fn skipUnderscoreDigits(self: *Lexer, hex: bool) LexerError!void {
        while (self.position < self.source.len) {
            if (self.source[self.position] == '_' and self.position + 1 < self.source.len) {
                const next = self.source[self.position + 1];
                const valid = if (hex) isHexDigit(next) else isDigit(next);
                if (valid) {
                    self.position += 1;
                    self.column += 1;
                    self.position += 1;
                    self.column += 1;
                    while (self.position < self.source.len) {
                        const ch = self.source[self.position];
                        const ok = if (hex) isHexDigit(ch) else isDigit(ch);
                        if (!ok) break;
                        self.position += 1;
                        self.column += 1;
                    }
                } else {
                    break;
                }
            } else {
                break;
            }
        }
    }

    /// 扫描以点号开头的浮点数（如 .5）
    fn scanDotFloat(self: *Lexer, start: usize, start_line: u32, start_col: u32) LexerError!void {
        while (self.position < self.source.len and isDigit(self.source[self.position])) {
            self.position += 1;
            self.column += 1;
        }
        try self.skipUnderscoreDigits(false);
        if (self.position < self.source.len and (self.source[self.position] == 'e' or self.source[self.position] == 'E')) {
            self.position += 1;
            self.column += 1;
            if (self.position < self.source.len and (self.source[self.position] == '+' or self.source[self.position] == '-')) {
                self.position += 1;
                self.column += 1;
            }
            if (self.position < self.source.len and isDigit(self.source[self.position])) {
                while (self.position < self.source.len and isDigit(self.source[self.position])) {
                    self.position += 1;
                    self.column += 1;
                }
            } else {
                return LexerError.InvalidNumber;
            }
        }
        if (self.position < self.source.len and isIdentifierStart(self.source[self.position])) {
            const suffix_start = self.position;
            while (self.position < self.source.len and isIdentifierContinue(self.source[self.position])) {
                self.position += 1;
                self.column += 1;
            }
            const suffix = self.source[suffix_start..self.position];
            if (!isFloatSuffix(suffix)) {
                const backtrack = self.position - suffix_start;
                self.position = suffix_start;
                self.column -= @intCast(backtrack);
            }
        }
        try self.addToken(.float_literal, start, start_line, start_col);
    }

    /// 扫描十六进制数字字面量（0x 前缀），支持十六进制小数与 p 指数
    fn scanHexNumber(self: *Lexer, start: usize, start_line: u32, start_col: u32) LexerError!void {
        var has_digits = false;
        while (self.position < self.source.len and isHexDigit(self.source[self.position])) {
            has_digits = true;
            self.position += 1;
            self.column += 1;
        }
        try self.skipUnderscoreDigits(true);
        var is_float = false;
        if (self.position < self.source.len and self.source[self.position] == '.') {
            if (self.position + 1 < self.source.len and (isHexDigit(self.source[self.position + 1]) or self.source[self.position + 1] == 'p' or self.source[self.position + 1] == 'P')) {
                is_float = true;
                self.position += 1;
                self.column += 1;
                while (self.position < self.source.len and isHexDigit(self.source[self.position])) {
                    self.position += 1;
                    self.column += 1;
                }
                try self.skipUnderscoreDigits(true);
            }
        }
        if (self.position < self.source.len and (self.source[self.position] == 'p' or self.source[self.position] == 'P')) {
            is_float = true;
            self.position += 1;
            self.column += 1;
            if (self.position < self.source.len and (self.source[self.position] == '+' or self.source[self.position] == '-')) {
                self.position += 1;
                self.column += 1;
            }
            if (self.position < self.source.len and isDigit(self.source[self.position])) {
                while (self.position < self.source.len and isDigit(self.source[self.position])) {
                    self.position += 1;
                    self.column += 1;
                }
            } else {
                return LexerError.InvalidNumber;
            }
        }
        if (!has_digits) {
            return LexerError.InvalidHexDigit;
        }
        if (self.position < self.source.len and isIdentifierStart(self.source[self.position])) {
            const suffix_start = self.position;
            while (self.position < self.source.len and isIdentifierContinue(self.source[self.position])) {
                self.position += 1;
                self.column += 1;
            }
            const suffix = self.source[suffix_start..self.position];
            if (!isIntSuffix(suffix) and !isFloatSuffix(suffix)) {
                const backtrack = self.position - suffix_start;
                self.position = suffix_start;
                self.column -= @intCast(backtrack);
            }
        }
        try self.addToken(if (is_float) .float_literal else .int_literal, start, start_line, start_col);
    }

    /// 扫描八进制数字字面量（0o 前缀）
    fn scanOctalNumber(self: *Lexer, start: usize, start_line: u32, start_col: u32) LexerError!void {
        var has_digits = false;
        while (self.position < self.source.len and isOctalDigit(self.source[self.position])) {
            has_digits = true;
            self.position += 1;
            self.column += 1;
        }
        while (self.position < self.source.len) {
            if (self.source[self.position] == '_' and self.position + 1 < self.source.len and isOctalDigit(self.source[self.position + 1])) {
                has_digits = true;
                self.position += 1;
                self.column += 1;
                self.position += 1;
                self.column += 1;
                while (self.position < self.source.len and isOctalDigit(self.source[self.position])) {
                    self.position += 1;
                    self.column += 1;
                }
            } else {
                break;
            }
        }
        if (!has_digits) {
            return LexerError.InvalidOctalDigit;
        }
        if (self.position < self.source.len and isIdentifierStart(self.source[self.position])) {
            const suffix_start = self.position;
            while (self.position < self.source.len and isIdentifierContinue(self.source[self.position])) {
                self.position += 1;
                self.column += 1;
            }
            const suffix = self.source[suffix_start..self.position];
            if (!isIntSuffix(suffix)) {
                const backtrack = self.position - suffix_start;
                self.position = suffix_start;
                self.column -= @intCast(backtrack);
            }
        }
        try self.addToken(.int_literal, start, start_line, start_col);
    }

    /// 扫描二进制数字字面量（0b 前缀）
    fn scanBinaryNumber(self: *Lexer, start: usize, start_line: u32, start_col: u32) LexerError!void {
        var has_digits = false;
        while (self.position < self.source.len and isBinaryDigit(self.source[self.position])) {
            has_digits = true;
            self.position += 1;
            self.column += 1;
        }
        while (self.position < self.source.len) {
            if (self.source[self.position] == '_' and self.position + 1 < self.source.len and isBinaryDigit(self.source[self.position + 1])) {
                has_digits = true;
                self.position += 1;
                self.column += 1;
                self.position += 1;
                self.column += 1;
                while (self.position < self.source.len and isBinaryDigit(self.source[self.position])) {
                    self.position += 1;
                    self.column += 1;
                }
            } else {
                break;
            }
        }
        if (!has_digits) {
            return LexerError.InvalidBinaryDigit;
        }
        if (self.position < self.source.len and isIdentifierStart(self.source[self.position])) {
            const suffix_start = self.position;
            while (self.position < self.source.len and isIdentifierContinue(self.source[self.position])) {
                self.position += 1;
                self.column += 1;
            }
            const suffix = self.source[suffix_start..self.position];
            if (!isIntSuffix(suffix)) {
                const backtrack = self.position - suffix_start;
                self.position = suffix_start;
                self.column -= @intCast(backtrack);
            }
        }
        try self.addToken(.int_literal, start, start_line, start_col);
    }

    /// 扫描字符字面量（'x'），支持转义与 Unicode 转义 \u{...}
    fn scanChar(self: *Lexer, start: usize, start_line: u32, start_col: u32) LexerError!void {
        if (self.position >= self.source.len) {
            return LexerError.UnterminatedChar;
        }
        if (self.source[self.position] == '\\') {
            self.position += 1;
            self.column += 1;
            if (self.position >= self.source.len) {
                return LexerError.UnterminatedChar;
            }
            const escaped = self.source[self.position];
            switch (escaped) {
                'n', 't', 'r', '\\', '\'', '0' => {
                    self.position += 1;
                    self.column += 1;
                },
                'u' => {
                    self.position += 1;
                    self.column += 1;
                    if (self.position >= self.source.len or self.source[self.position] != '{') {
                        return LexerError.InvalidUnicodeEscape;
                    }
                    self.position += 1;
                    self.column += 1;
                    var digit_count: usize = 0;
                    while (self.position < self.source.len and self.source[self.position] != '}') {
                        if (!isHexDigit(self.source[self.position])) {
                            return LexerError.InvalidUnicodeEscape;
                        }
                        self.position += 1;
                        self.column += 1;
                        digit_count += 1;
                    }
                    if (digit_count == 0 or self.position >= self.source.len) {
                        return LexerError.InvalidUnicodeEscape;
                    }
                    self.position += 1;
                    self.column += 1;
                },
                else => {
                    return LexerError.InvalidEscape;
                },
            }
        } else {
            self.position += 1;
            self.column += 1;
        }
        if (self.position >= self.source.len or self.source[self.position] != '\'') {
            return LexerError.UnterminatedChar;
        }
        self.position += 1;
        self.column += 1;
        try self.addToken(.char_literal, start, start_line, start_col);
    }

    /// 扫描字符串字面量，支持转义、{{ }} 字面花括号与 {表达式} 插值
    fn scanString(self: *Lexer, start: usize, start_line: u32, start_col: u32) LexerError!void {
        while (self.position < self.source.len) {
            const ch = self.source[self.position];
            if (ch == '"') {
                self.position += 1;
                self.column += 1;
                try self.addToken(.string_literal, start, start_line, start_col);
                return;
            }
            if (ch == '\\') {
                self.position += 1;
                self.column += 1;
                if (self.position >= self.source.len) {
                    return LexerError.UnterminatedString;
                }
                const escaped = self.source[self.position];
                switch (escaped) {
                    '"', '\\', 'n', 't', 'r' => {
                        self.position += 1;
                        self.column += 1;
                    },
                    '{' => {
                        self.position += 1;
                        self.column += 1;
                    },
                    '}' => {
                        self.position += 1;
                        self.column += 1;
                    },
                    else => {
                        return LexerError.InvalidEscape;
                    },
                }
            } else if (ch == '{') {
                // {{ 表示字面 {，否则进入插值表达式扫描
                if (self.position + 1 < self.source.len and self.source[self.position + 1] == '{') {
                    self.position += 2;
                    self.column += 2;
                } else {
                    self.position += 1;
                    self.column += 1;
                    var brace_depth: u32 = 1;
                    while (self.position < self.source.len and brace_depth > 0) {
                        const inner = self.source[self.position];
                        if (inner == '\\') {
                            self.position += 1;
                            self.column += 1;
                            if (self.position < self.source.len) {
                                self.position += 1;
                                self.column += 1;
                            }
                            continue;
                        } else if (inner == '{') {
                            brace_depth += 1;
                        } else if (inner == '}') {
                            brace_depth -= 1;
                        } else if (inner == '"') {
                            // 插值表达式中嵌套的字符串字面量
                            self.position += 1;
                            self.column += 1;
                            while (self.position < self.source.len and self.source[self.position] != '"') {
                                if (self.source[self.position] == '\\') {
                                    self.position += 1;
                                    self.column += 1;
                                    if (self.position < self.source.len) {
                                        self.position += 1;
                                        self.column += 1;
                                    }
                                } else {
                                    if (self.source[self.position] == '\n') {
                                        self.line += 1;
                                        self.column = 1;
                                    } else {
                                        self.column += 1;
                                    }
                                    self.position += 1;
                                }
                            }
                            if (self.position < self.source.len) {
                                self.position += 1;
                                self.column += 1;
                            }
                            continue;
                        }
                        if (inner == '\n') {
                            self.line += 1;
                            self.column = 1;
                        } else {
                            self.column += 1;
                        }
                        self.position += 1;
                    }
                }
            } else if (ch == '}') {
                // }} 表示字面 }
                if (self.position + 1 < self.source.len and self.source[self.position + 1] == '}') {
                    self.position += 2;
                    self.column += 2;
                } else {
                    self.position += 1;
                    self.column += 1;
                }
            } else if (ch == '\n') {
                return LexerError.UnterminatedString;
            } else {
                self.position += 1;
                self.column += 1;
            }
        }
        return LexerError.UnterminatedString;
    }

    /// 扫描标识符或关键字，通过关键字表判定最终 Token 类型
    fn scanIdentifier(self: *Lexer, start: usize, start_line: u32, start_col: u32) LexerError!void {
        while (self.position < self.source.len and isIdentifierContinue(self.source[self.position])) {
            self.position += 1;
            self.column += 1;
        }
        const text = self.source[start..self.position];
        const token_type = keywordType(text);
        try self.addToken(token_type, start, start_line, start_col);
    }
};

/// 判断是否为十进制数字
fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

/// 判断是否为十六进制数字
fn isHexDigit(ch: u8) bool {
    return isDigit(ch) or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F');
}

/// 判断是否为八进制数字
fn isOctalDigit(ch: u8) bool {
    return ch >= '0' and ch <= '7';
}

/// 判断是否为二进制数字
fn isBinaryDigit(ch: u8) bool {
    return ch == '0' or ch == '1';
}

/// 判断字符是否可作为标识符首字符
fn isIdentifierStart(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_';
}

/// 判断字符是否可作为标识符后续字符
fn isIdentifierContinue(ch: u8) bool {
    return isIdentifierStart(ch) or isDigit(ch);
}

/// 关键字映射表，编译期构造
const KEYWORDS = std.StaticStringMap(TokenType).initComptime(.{
    .{ "fun", .kw_fun },
    .{ "type", .kw_type },
    .{ "trait", .kw_trait },
    .{ "override", .kw_override },
    .{ "pack", .kw_pack },
    .{ "pub", .kw_pub },
    .{ "import", .kw_import },
    .{ "with", .kw_with },
    .{ "as", .kw_as },
    .{ "val", .kw_val },
    .{ "var", .kw_var },
    .{ "match", .kw_match },
    .{ "if", .kw_if },
    .{ "else", .kw_else },
    .{ "async", .kw_async },
    .{ "channel", .kw_channel },
    .{ "select", .kw_select },
    .{ "atomic", .kw_atomic },
    .{ "spawn", .kw_spawn },
    .{ "loop", .kw_loop },
    .{ "for", .kw_for },
    .{ "in", .kw_in },
    .{ "while", .kw_while },
    .{ "break", .kw_break },
    .{ "continue", .kw_continue },
    .{ "true", .true_literal },
    .{ "false", .false_literal },
    .{ "null", .null_literal },
    .{ "return", .kw_return },
    .{ "throw", .kw_throw },
    .{ "lazy", .kw_lazy },
    .{ "defer", .kw_defer },
});

/// 查询文本是否为关键字，否则返回 identifier
fn keywordType(text: []const u8) TokenType {
    return KEYWORDS.get(text) orelse .identifier;
}

/// 判断后缀是否为合法整数类型后缀
fn isIntSuffix(suffix: []const u8) bool {
    const valid = [_][]const u8{
        "i8",  "i16", "i32", "i64", "i128",
        "u8",  "u16", "u32", "u64", "u128",
    };
    for (valid) |v| {
        if (std.mem.eql(u8, suffix, v)) return true;
    }
    return false;
}

/// 判断后缀是否为合法浮点类型后缀
fn isFloatSuffix(suffix: []const u8) bool {
    const valid = [_][]const u8{ "f16", "f32", "f64", "f128" };
    for (valid) |v| {
        if (std.mem.eql(u8, suffix, v)) return true;
    }
    return false;
}
