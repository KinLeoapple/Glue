//! Glue 语言词法分析器
//!
//! 将源代码文本转换为 Token 流，支持：
//! - 所有关键字、运算符、分隔符
//! - 整数字面量（十进制、十六进制、八进制、二进制、下划线分隔、类型后缀）
//! - 浮点字面量（十进制、十六进制、指数、类型后缀）
//! - 字符字面量（含转义序列和 Unicode）
//! - 字符串字面量（含插值和转义）
//! - 注释（单行、多行、嵌套多行）
//! - 源位置追踪

const std = @import("std");

// ============================================================
// Token 类型
// ============================================================

/// Token 类型的穷举枚举
pub const TokenType = enum {
    // --- 字面量 ---
    /// 整数字面量
    int_literal,
    /// 浮点字面量
    float_literal,
    /// 字符字面量
    char_literal,
    /// 字符串字面量
    string_literal,
    /// 布尔字面量 true
    true_literal,
    /// 布尔字面量 false
    false_literal,
    /// null 字面量
    null_literal,

    // --- 关键字 ---
    /// fun
    kw_fun,
    /// type
    kw_type,
    /// trait
    kw_trait,
    /// impl
    kw_impl,
    /// override
    kw_override,
    /// pack
    kw_pack,
    /// pub
    kw_pub,
    /// use
    kw_use,
    /// with
    kw_with,
    /// as
    kw_as,
    /// val
    kw_val,
    /// var
    kw_var,
    /// match
    kw_match,
    /// if
    kw_if,
    /// else
    kw_else,
    /// spawn
    kw_spawn,
    /// channel
    kw_channel,
    /// select
    kw_select,
    /// atomic
    kw_atomic,
    /// loop
    kw_loop,
    /// for
    kw_for,
    /// in
    kw_in,
    /// while
    kw_while,
    /// break
    kw_break,
    /// continue
    kw_continue,
    /// return
    kw_return,
    kw_throw,
    /// lazy
    kw_lazy,
    /// defer
    kw_defer,

    // --- 标识符 ---
    /// 标识符
    identifier,

    // --- 算术运算符 ---
    /// +
    plus,
    /// -
    minus,
    /// *
    star,
    /// /
    slash,
    /// %
    percent,

    // --- 比较运算符 ---
    /// ==
    eq_eq,
    /// !=
    bang_eq,
    /// <
    lt,
    /// >
    gt,
    /// <=
    lt_eq,
    /// >=
    gt_eq,
    /// <- （monad 绑定箭头）
    lt_minus,

    // --- 逻辑运算符 ---
    /// &&
    amp_amp,
    /// ||
    pipe_pipe,
    /// ! (前缀逻辑非)
    bang,

    // --- 位运算符 ---
    /// & (按位与)
    ampersand,
    /// ^ (按位异或)
    caret,

    // --- Nullable 运算符 ---
    /// ?.
    question_dot,
    /// ??
    question_question,
    /// ? (后缀传播操作符)
    question,
    /// ! (后缀非空断言) — 与 bang 相同词法，由语法分析器区分

    // --- 范围运算符 ---
    /// ..
    dot_dot,
    /// ..=
    dot_dot_eq,
    /// ... (spread/ellipsis，用于记录扩展)
    ellipsis,

    // --- 赋值 ---
    /// =
    eq,
    /// +=
    plus_eq,
    /// ++（数组/列表拼接）
    plus_plus,
    /// -=
    minus_eq,
    /// *=
    star_eq,
    /// /=
    slash_eq,
    /// %=
    percent_eq,
    /// &=
    amp_eq,
    /// |=
    pipe_eq,

    // --- 箭头 ---
    /// =>
    eq_gt,
    /// ->
    minus_gt,

    // --- 分隔符 ---
    /// (
    l_paren,
    /// )
    r_paren,
    /// [
    l_bracket,
    /// ]
    r_bracket,
    /// {
    l_brace,
    /// }
    r_brace,
    /// ,
    comma,

    /// :
    colon,
    /// .
    dot,

    // --- 管道 ---
    /// |
    pipe,

    // --- Monad ---
    /// @ (Monad 上下文表达式前缀)
    at,

    // --- 特殊 ---
    /// 文件结束
    eof,
    /// 词法错误
    err,
};

// ============================================================
// Token
// ============================================================

/// 词法单元
pub const Token = struct {
    /// Token 类型
    type: TokenType,
    /// 词素（源代码切片）
    lexeme: []const u8,
    /// 行号（从 1 开始）
    line: u32,
    /// 列号（从 1 开始）
    column: u32,
};

// ============================================================
// 词法分析器错误
// ============================================================

/// 词法分析器可能产生的错误
pub const LexerError = error{
    /// 未终止的字符串
    UnterminatedString,
    /// 未终止的字符字面量
    UnterminatedChar,
    /// 未终止的注释
    UnterminatedComment,
    /// 无效的转义序列
    InvalidEscape,
    /// 无效的 Unicode 转义
    InvalidUnicodeEscape,
    /// 无效的数字字面量
    InvalidNumber,
    /// 无效的十六进制数字
    InvalidHexDigit,
    /// 无效的八进制数字
    InvalidOctalDigit,
    /// 无效的二进制数字
    InvalidBinaryDigit,
    /// 意外的字符
    UnexpectedCharacter,
    /// 内存分配失败
    OutOfMemory,
};

// ============================================================
// 词法分析器
// ============================================================

/// 词法分析器
pub const Lexer = struct {
    /// 源代码
    source: []const u8,
    /// 当前位置
    position: usize,
    /// 当前行号
    line: u32,
    /// 当前列号
    column: u32,
    /// Token 列表
    tokens: std.ArrayList(Token),
    /// 内存分配器
    allocator: std.mem.Allocator,

    /// 初始化词法分析器
    pub fn init(allocator: std.mem.Allocator, source: []const u8) Lexer {
        return Lexer{
            .source = source,
            .position = 0,
            .line = 1,
            .column = 1,
            .tokens = .empty,
            .allocator = allocator,
        };
    }

    /// 释放词法分析器资源
    pub fn deinit(self: *Lexer) void {
        self.tokens.deinit(self.allocator);
    }

    /// 执行词法分析，返回所有 Token（包含 EOF）
    pub fn tokenize(self: *Lexer) LexerError![]Token {
        while (self.position < self.source.len) {
            try self.scanToken();
        }
        // 添加 EOF Token
        try self.tokens.append(self.allocator, Token{
            .type = .eof,
            .lexeme = "",
            .line = self.line,
            .column = self.column,
        });
        return self.tokens.toOwnedSlice(self.allocator);
    }

    // --------------------------------------------------------
    // 内部辅助方法
    // --------------------------------------------------------

    /// 获取当前字符（不前进）
    fn peek(self: *Lexer) ?u8 {
        if (self.position >= self.source.len) return null;
        return self.source[self.position];
    }

    /// 获取下一个字符（不前进）
    fn peekNext(self: *Lexer) ?u8 {
        if (self.position + 1 >= self.source.len) return null;
        return self.source[self.position + 1];
    }

    /// 前进一个字符，更新行列信息
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

    /// 条件前进：当前字符匹配则前进并返回 true
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

    /// 创建 Token
    fn makeToken(self: *Lexer, token_type: TokenType, start: usize, start_line: u32, start_col: u32) Token {
        return Token{
            .type = token_type,
            .lexeme = self.source[start..self.position],
            .line = start_line,
            .column = start_col,
        };
    }

    /// 添加 Token
    fn addToken(self: *Lexer, token_type: TokenType, start: usize, start_line: u32, start_col: u32) LexerError!void {
        try self.tokens.append(self.allocator, self.makeToken(token_type, start, start_line, start_col));
    }

    /// 添加错误 Token
    fn addError(self: *Lexer, start: usize, start_line: u32, start_col: u32) LexerError!void {
        try self.tokens.append(self.allocator, Token{
            .type = .err,
            .lexeme = self.source[start..self.position],
            .line = start_line,
            .column = start_col,
        });
    }

    // --------------------------------------------------------
    // 核心：扫描一个 Token
    // --------------------------------------------------------

    fn scanToken(self: *Lexer) LexerError!void {
        const start = self.position;
        const start_line = self.line;
        const start_col = self.column;
        const ch = self.advance().?;

        switch (ch) {
            // 空白字符：跳过
            ' ', '\t', '\r', '\n' => {},

            // 单行注释 //
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

            // 单字符运算符和分隔符
            '(' => try self.addToken(.l_paren, start, start_line, start_col),
            ')' => try self.addToken(.r_paren, start, start_line, start_col),
            '[' => try self.addToken(.l_bracket, start, start_line, start_col),
            ']' => try self.addToken(.r_bracket, start, start_line, start_col),
            '{' => try self.addToken(.l_brace, start, start_line, start_col),
            '}' => try self.addToken(.r_brace, start, start_line, start_col),
            ',' => try self.addToken(.comma, start, start_line, start_col),
            ';' => {}, // Glue 没有分号，跳过
            ':' => try self.addToken(.colon, start, start_line, start_col),
            '%' => {
                if (self.matchChar('=')) {
                    try self.addToken(.percent_eq, start, start_line, start_col);
                } else {
                    try self.addToken(.percent, start, start_line, start_col);
                }
            },

            // + 或 += 或 ++
            '+' => {
                if (self.matchChar('=')) {
                    try self.addToken(.plus_eq, start, start_line, start_col);
                } else if (self.matchChar('+')) {
                    try self.addToken(.plus_plus, start, start_line, start_col);
                } else {
                    try self.addToken(.plus, start, start_line, start_col);
                }
            },

            // * 或 *=
            '*' => {
                if (self.matchChar('=')) {
                    try self.addToken(.star_eq, start, start_line, start_col);
                } else {
                    try self.addToken(.star, start, start_line, start_col);
                }
            },

            // | 或 || 或 |=
            '|' => {
                if (self.matchChar('|')) {
                    try self.addToken(.pipe_pipe, start, start_line, start_col);
                } else if (self.matchChar('=')) {
                    try self.addToken(.pipe_eq, start, start_line, start_col);
                } else {
                    try self.addToken(.pipe, start, start_line, start_col);
                }
            },

            // = 或 == 或 =>
            '=' => {
                if (self.matchChar('=')) {
                    try self.addToken(.eq_eq, start, start_line, start_col);
                } else if (self.matchChar('>')) {
                    try self.addToken(.eq_gt, start, start_line, start_col);
                } else {
                    try self.addToken(.eq, start, start_line, start_col);
                }
            },

            // ! 或 !=
            '!' => {
                if (self.matchChar('=')) {
                    try self.addToken(.bang_eq, start, start_line, start_col);
                } else {
                    try self.addToken(.bang, start, start_line, start_col);
                }
            },

            // < 或 <= 或 <-（monad 绑定箭头）
            '<' => {
                if (self.matchChar('=')) {
                    try self.addToken(.lt_eq, start, start_line, start_col);
                } else if (self.matchChar('-')) {
                    try self.addToken(.lt_minus, start, start_line, start_col);
                } else {
                    try self.addToken(.lt, start, start_line, start_col);
                }
            },

            // > 或 >=
            '>' => {
                if (self.matchChar('=')) {
                    try self.addToken(.gt_eq, start, start_line, start_col);
                } else {
                    try self.addToken(.gt, start, start_line, start_col);
                }
            },

            // - 或 -> 或 -=
            '-' => {
                if (self.matchChar('>')) {
                    try self.addToken(.minus_gt, start, start_line, start_col);
                } else if (self.matchChar('=')) {
                    try self.addToken(.minus_eq, start, start_line, start_col);
                } else {
                    try self.addToken(.minus, start, start_line, start_col);
                }
            },

            // . 或 .. 或 ..= 或 ...
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
                    // 检查是否为以 . 开头的浮点数（如 .5）
                    if (self.position < self.source.len and isDigit(self.source[self.position])) {
                        try self.scanDotFloat(start, start_line, start_col);
                    } else {
                        try self.addToken(.dot, start, start_line, start_col);
                    }
                }
            },

            // ? 或 ?. 或 ??
            '?' => {
                if (self.matchChar('.')) {
                    try self.addToken(.question_dot, start, start_line, start_col);
                } else if (self.matchChar('?')) {
                    try self.addToken(.question_question, start, start_line, start_col);
                } else {
                    try self.addToken(.question, start, start_line, start_col);
                }
            },

            // & 或 &&
            '&' => {
                if (self.matchChar('&')) {
                    try self.addToken(.amp_amp, start, start_line, start_col);
                } else if (self.matchChar('=')) {
                    try self.addToken(.amp_eq, start, start_line, start_col);
                } else {
                    try self.addToken(.ampersand, start, start_line, start_col);
                }
            },

            // ^ (按位异或)
            '^' => try self.addToken(.caret, start, start_line, start_col),

            // @ (Monad 上下文表达式)
            '@' => try self.addToken(.at, start, start_line, start_col),

            // 字符字面量
            '\'' => try self.scanChar(start, start_line, start_col),

            // 字符串字面量
            '"' => try self.scanString(start, start_line, start_col),

            // 数字字面量
            '0'...'9' => try self.scanNumber(start, start_line, start_col),

            // 标识符和关键字
            'a'...'z', 'A'...'Z', '_' => try self.scanIdentifier(start, start_line, start_col),

            // 不可识别字符
            else => {
                try self.addError(start, start_line, start_col);
            },
        }
    }

    // --------------------------------------------------------
    // 注释处理
    // --------------------------------------------------------

    /// 跳过单行注释
    fn skipLineComment(self: *Lexer) LexerError!void {
        while (self.position < self.source.len) {
            if (self.source[self.position] == '\n') break;
            self.position += 1;
            self.column += 1;
        }
        // 不消耗换行符，让主循环处理
    }

    /// 跳过多行注释（支持嵌套）
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

    // --------------------------------------------------------
    // 数字字面量
    // --------------------------------------------------------

    /// 扫描数字字面量（整数或浮点数）
    fn scanNumber(self: *Lexer, start: usize, start_line: u32, start_col: u32) LexerError!void {
        // 检查十六进制、八进制、二进制前缀
        if (self.source[start] == '0' and self.position < self.source.len) {
            const prefix = self.source[self.position];
            if (prefix == 'x' or prefix == 'X') {
                // 十六进制
                self.position += 1;
                self.column += 1;
                try self.scanHexNumber(start, start_line, start_col);
                return;
            } else if (prefix == 'o' or prefix == 'O') {
                // 八进制
                self.position += 1;
                self.column += 1;
                try self.scanOctalNumber(start, start_line, start_col);
                return;
            } else if (prefix == 'b' or prefix == 'B') {
                // 二进制
                self.position += 1;
                self.column += 1;
                try self.scanBinaryNumber(start, start_line, start_col);
                return;
            }
        }

        // 十进制数字
        while (self.position < self.source.len and isDigit(self.source[self.position])) {
            self.position += 1;
            self.column += 1;
        }

        // 跳过下划线分隔符
        try self.skipUnderscoreDigits(false);

        // 检查是否为浮点数
        var is_float = false;

        // 小数部分：. 后跟数字
        if (self.position < self.source.len and self.source[self.position] == '.') {
            // 排除范围运算符 .. 和 ..=
            if (self.position + 1 < self.source.len and isDigit(self.source[self.position + 1])) {
                is_float = true;
                self.position += 1; // 消费 .
                self.column += 1;
                // 消费小数部分数字
                while (self.position < self.source.len and isDigit(self.source[self.position])) {
                    self.position += 1;
                    self.column += 1;
                }
                // 小数部分的下划线分隔
                try self.skipUnderscoreDigits(false);
            }
            // 如果 . 后面是 . 则不是浮点数，不消费
        }

        // 指数部分：e 或 E
        if (self.position < self.source.len and (self.source[self.position] == 'e' or self.source[self.position] == 'E')) {
            is_float = true;
            self.position += 1;
            self.column += 1;
            // 可选的 +/-
            if (self.position < self.source.len and (self.source[self.position] == '+' or self.source[self.position] == '-')) {
                self.position += 1;
                self.column += 1;
            }
            // 指数数字
            if (self.position < self.source.len and isDigit(self.source[self.position])) {
                while (self.position < self.source.len and isDigit(self.source[self.position])) {
                    self.position += 1;
                    self.column += 1;
                }
            } else {
                return LexerError.InvalidNumber;
            }
        }

        // 类型后缀
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
                // 无效后缀，回退
                const backtrack = self.position - suffix_start;
                self.position = suffix_start;
                self.column -= @intCast(backtrack);
            }
        }

        try self.addToken(if (is_float) .float_literal else .int_literal, start, start_line, start_col);
    }

    /// 跳过下划线分隔的数字（消费 _digit 模式）
    fn skipUnderscoreDigits(self: *Lexer, hex: bool) LexerError!void {
        while (self.position < self.source.len) {
            if (self.source[self.position] == '_' and self.position + 1 < self.source.len) {
                const next = self.source[self.position + 1];
                const valid = if (hex) isHexDigit(next) else isDigit(next);
                if (valid) {
                    self.position += 1; // 跳过下划线
                    self.column += 1;
                    self.position += 1; // 跳过下划线后的数字
                    self.column += 1;
                    // 继续消费剩余数字
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

    /// 扫描以 . 开头的浮点数（如 .5）
    fn scanDotFloat(self: *Lexer, start: usize, start_line: u32, start_col: u32) LexerError!void {
        // 已经消费了 '.'，当前位置是数字
        while (self.position < self.source.len and isDigit(self.source[self.position])) {
            self.position += 1;
            self.column += 1;
        }

        // 下划线分隔
        try self.skipUnderscoreDigits(false);

        // 指数部分
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

        // 类型后缀
        if (self.position < self.source.len and isIdentifierStart(self.source[self.position])) {
            const suffix_start = self.position;
            while (self.position < self.source.len and isIdentifierContinue(self.source[self.position])) {
                self.position += 1;
                self.column += 1;
            }
            const suffix = self.source[suffix_start..self.position];
            if (!isFloatSuffix(suffix)) {
                // 无效后缀，回退
                const backtrack = self.position - suffix_start;
                self.position = suffix_start;
                self.column -= @intCast(backtrack);
            }
        }

        try self.addToken(.float_literal, start, start_line, start_col);
    }

    /// 扫描十六进制数字（0x 前缀已消费）
    fn scanHexNumber(self: *Lexer, start: usize, start_line: u32, start_col: u32) LexerError!void {
        // 检查是否为十六进制浮点数（0x1.5p3 格式）
        var has_digits = false;

        // 消费十六进制整数部分
        while (self.position < self.source.len and isHexDigit(self.source[self.position])) {
            has_digits = true;
            self.position += 1;
            self.column += 1;
        }

        // 跳过下划线
        try self.skipUnderscoreDigits(true);

        // 检查十六进制浮点数的小数部分
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

        // 十六进制浮点数必须有 p/P 指数部分
        if (self.position < self.source.len and (self.source[self.position] == 'p' or self.source[self.position] == 'P')) {
            is_float = true;
            self.position += 1;
            self.column += 1;
            // 可选的 +/-
            if (self.position < self.source.len and (self.source[self.position] == '+' or self.source[self.position] == '-')) {
                self.position += 1;
                self.column += 1;
            }
            // 指数数字（十进制）
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

        // 类型后缀
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

    /// 扫描八进制数字（0o 前缀已消费）
    fn scanOctalNumber(self: *Lexer, start: usize, start_line: u32, start_col: u32) LexerError!void {
        var has_digits = false;
        while (self.position < self.source.len and isOctalDigit(self.source[self.position])) {
            has_digits = true;
            self.position += 1;
            self.column += 1;
        }
        // 下划线分隔
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
        // 类型后缀
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

    /// 扫描二进制数字（0b 前缀已消费）
    fn scanBinaryNumber(self: *Lexer, start: usize, start_line: u32, start_col: u32) LexerError!void {
        var has_digits = false;
        while (self.position < self.source.len and isBinaryDigit(self.source[self.position])) {
            has_digits = true;
            self.position += 1;
            self.column += 1;
        }
        // 下划线分隔
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
        // 类型后缀
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

    // --------------------------------------------------------
    // 字符字面量
    // --------------------------------------------------------

    /// 扫描字符字面量（开头 ' 已消费）
    fn scanChar(self: *Lexer, start: usize, start_line: u32, start_col: u32) LexerError!void {
        if (self.position >= self.source.len) {
            return LexerError.UnterminatedChar;
        }

        // 处理字符内容
        if (self.source[self.position] == '\\') {
            // 转义序列
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
                    // Unicode 转义 \u{1F600}
                    self.position += 1;
                    self.column += 1;
                    if (self.position >= self.source.len or self.source[self.position] != '{') {
                        return LexerError.InvalidUnicodeEscape;
                    }
                    self.position += 1;
                    self.column += 1;
                    // 消费十六进制数字
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
                    // 消费 }
                    self.position += 1;
                    self.column += 1;
                },
                else => {
                    return LexerError.InvalidEscape;
                },
            }
        } else {
            // 普通字符
            self.position += 1;
            self.column += 1;
        }

        // 期望结束的 '
        if (self.position >= self.source.len or self.source[self.position] != '\'') {
            return LexerError.UnterminatedChar;
        }
        self.position += 1;
        self.column += 1;

        try self.addToken(.char_literal, start, start_line, start_col);
    }

    // --------------------------------------------------------
    // 字符串字面量
    // --------------------------------------------------------

    /// 扫描字符串字面量（开头 " 已消费）
    fn scanString(self: *Lexer, start: usize, start_line: u32, start_col: u32) LexerError!void {
        while (self.position < self.source.len) {
            const ch = self.source[self.position];

            if (ch == '"') {
                // 字符串结束
                self.position += 1;
                self.column += 1;
                try self.addToken(.string_literal, start, start_line, start_col);
                return;
            }

            if (ch == '\\') {
                // 转义序列
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
                        // \{ 转义为字面量 {
                        self.position += 1;
                        self.column += 1;
                    },
                    '}' => {
                        // \} 转义为字面量 }
                        self.position += 1;
                        self.column += 1;
                    },
                    else => {
                        return LexerError.InvalidEscape;
                    },
                }
            } else if (ch == '{') {
                // 检查是否为 {{ 转义
                if (self.position + 1 < self.source.len and self.source[self.position + 1] == '{') {
                    // {{ 转义为字面量 {
                    self.position += 2;
                    self.column += 2;
                } else {
                    // 插值开始 { — 在词法分析阶段，我们将整个字符串作为一个 string_literal Token
                    // 插值的解析由语法分析器完成
                    // 这里需要找到匹配的 }
                    self.position += 1;
                    self.column += 1;
                    var brace_depth: u32 = 1;
                    while (self.position < self.source.len and brace_depth > 0) {
                        const inner = self.source[self.position];
                        if (inner == '{') {
                            brace_depth += 1;
                        } else if (inner == '}') {
                            brace_depth -= 1;
                        } else if (inner == '"') {
                            // 嵌套字符串
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
                // 检查是否为 }} 转义
                if (self.position + 1 < self.source.len and self.source[self.position + 1] == '}') {
                    self.position += 2;
                    self.column += 2;
                } else {
                    // 单独的 } 在字符串中不应该出现（除非是插值的结束）
                    self.position += 1;
                    self.column += 1;
                }
            } else if (ch == '\n') {
                // 多行字符串不支持，报错
                return LexerError.UnterminatedString;
            } else {
                self.position += 1;
                self.column += 1;
            }
        }

        return LexerError.UnterminatedString;
    }

    // --------------------------------------------------------
    // 标识符和关键字
    // --------------------------------------------------------

    /// 扫描标识符或关键字
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

// ============================================================
// 辅助函数
// ============================================================

/// 判断字符是否为十进制数字
fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

/// 判断字符是否为十六进制数字
fn isHexDigit(ch: u8) bool {
    return isDigit(ch) or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F');
}

/// 判断字符是否为八进制数字
fn isOctalDigit(ch: u8) bool {
    return ch >= '0' and ch <= '7';
}

/// 判断字符是否为二进制数字
fn isBinaryDigit(ch: u8) bool {
    return ch == '0' or ch == '1';
}

/// 判断字符是否可以作为标识符开头
fn isIdentifierStart(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_';
}

/// 判断字符是否可以继续标识符
fn isIdentifierContinue(ch: u8) bool {
    return isIdentifierStart(ch) or isDigit(ch);
}

/// 关键字映射表
fn keywordType(text: []const u8) TokenType {
    if (std.mem.eql(u8, text, "fun")) return .kw_fun;
    if (std.mem.eql(u8, text, "type")) return .kw_type;
    if (std.mem.eql(u8, text, "trait")) return .kw_trait;
    if (std.mem.eql(u8, text, "impl")) return .kw_impl;
    if (std.mem.eql(u8, text, "override")) return .kw_override;
    if (std.mem.eql(u8, text, "pack")) return .kw_pack;
    if (std.mem.eql(u8, text, "pub")) return .kw_pub;
    if (std.mem.eql(u8, text, "use")) return .kw_use;
    if (std.mem.eql(u8, text, "with")) return .kw_with;
    if (std.mem.eql(u8, text, "as")) return .kw_as;
    if (std.mem.eql(u8, text, "val")) return .kw_val;
    if (std.mem.eql(u8, text, "var")) return .kw_var;
    if (std.mem.eql(u8, text, "match")) return .kw_match;
    if (std.mem.eql(u8, text, "if")) return .kw_if;
    if (std.mem.eql(u8, text, "else")) return .kw_else;
    if (std.mem.eql(u8, text, "spawn")) return .kw_spawn;
    if (std.mem.eql(u8, text, "channel")) return .kw_channel;
    if (std.mem.eql(u8, text, "select")) return .kw_select;
    if (std.mem.eql(u8, text, "atomic")) return .kw_atomic;
    if (std.mem.eql(u8, text, "loop")) return .kw_loop;
    if (std.mem.eql(u8, text, "for")) return .kw_for;
    if (std.mem.eql(u8, text, "in")) return .kw_in;
    if (std.mem.eql(u8, text, "while")) return .kw_while;
    if (std.mem.eql(u8, text, "break")) return .kw_break;
    if (std.mem.eql(u8, text, "continue")) return .kw_continue;
    if (std.mem.eql(u8, text, "true")) return .true_literal;
    if (std.mem.eql(u8, text, "false")) return .false_literal;
    if (std.mem.eql(u8, text, "null")) return .null_literal;
    if (std.mem.eql(u8, text, "return")) return .kw_return;
    if (std.mem.eql(u8, text, "throw")) return .kw_throw;
    if (std.mem.eql(u8, text, "lazy")) return .kw_lazy;
    if (std.mem.eql(u8, text, "defer")) return .kw_defer;
    return .identifier;
}

/// 判断是否为有效的整数类型后缀
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

/// 判断是否为有效的浮点类型后缀
fn isFloatSuffix(suffix: []const u8) bool {
    const valid = [_][]const u8{ "f16", "f32", "f64", "f128" };
    for (valid) |v| {
        if (std.mem.eql(u8, suffix, v)) return true;
    }
    return false;
}