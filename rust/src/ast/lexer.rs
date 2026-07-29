//! 词法分析器（Lexer）
//!
//! 将 Glue 源码字符串逐字符扫描为 Token 序列，支持关键字、标识符、
//! 整数（含二/八/十六进制）、浮点数、字符与字符串字面量（含插值），
//! 以及各类运算符与分隔符。Token 同时携带行列号信息以便错误定位。
//!
//! 语义对应 Zig 原版 `src/parse/lexer.zig`，但用 Rust 惯例重写。
//! 分号 `;` 被当作空白字符跳过；遇到词法错误时生成 `Err` token 并继续扫描，
//! 以便 parser 能收集更多错误。

// =========================================================================
// TokenKind：覆盖所有字面量、关键字、运算符与分隔符
// =========================================================================

/// 词法单元类型：覆盖所有字面量、关键字、运算符与分隔符
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TokenKind {
    // --- 字面量（7 种）---
    IntLiteral,
    FloatLiteral,
    CharLiteral,
    StringLiteral,
    TrueLiteral,
    FalseLiteral,
    NullLiteral,

    // --- 关键字（28 种）---
    KwFun,
    KwType,
    KwTrait,
    KwOverride,
    KwPack,
    KwPub,
    KwImport,
    KwWith,
    KwAs,
    KwVal,
    KwVar,
    KwMatch,
    KwIf,
    KwElse,
    KwAsync,
    KwChannel,
    KwSelect,
    KwAtomic,
    KwLoop,
    KwFor,
    KwIn,
    KwWhile,
    KwBreak,
    KwContinue,
    KwReturn,
    KwThrow,
    KwLazy,
    KwDefer,

    // 标识符
    Identifier,

    // --- 运算符（42 种）---
    Plus,
    Minus,
    Star,
    Slash,
    Percent,
    EqEq,
    BangEq,
    RefEq,
    RefNeq,
    Lt,
    Gt,
    LtEq,
    GtEq,
    LtMinus,
    AmpAmp,
    PipePipe,
    Bang,
    Ampersand,
    Caret,
    QuestionDot,
    QuestionQuestion,
    Question,
    DotDot,
    DotDotEq,
    Ellipsis,
    Eq,
    PlusEq,
    PlusPlus,
    MinusEq,
    StarEq,
    SlashEq,
    PercentEq,
    AmpEq,
    PipeEq,
    CaretEq,
    LtLt,
    GtGt,
    LtLtEq,
    GtGtEq,
    Tilde,
    EqGt,
    MinusGt,

    // --- 分隔符（10 种）---
    LParen,
    RParen,
    LBracket,
    RBracket,
    LBrace,
    RBrace,
    Comma,
    Colon,
    Dot,
    Pipe,

    // --- 特殊（2 种）---
    Eof,
    Err,
}

// =========================================================================
// Token
// =========================================================================

/// 词法单元：类型、字面文本（零拷贝引用源码）、行列号
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Token<'a> {
    pub kind: TokenKind,
    pub lexeme: &'a str,
    pub line: u32,
    pub column: u32,
}

// =========================================================================
// LexerError
// =========================================================================

/// 词法分析可能产生的错误类型
#[derive(Debug, Clone)]
pub enum LexerError {
    UnterminatedString,
    UnterminatedChar,
    UnterminatedComment,
    InvalidEscape,
    InvalidUnicodeEscape,
    InvalidNumber,
    InvalidHexDigit,
    InvalidOctalDigit,
    InvalidBinaryDigit,
}

// =========================================================================
// Lexer
// =========================================================================

/// 词法分析器：持有源码、扫描位置与行列号
pub struct Lexer<'a> {
    source: &'a str,
    bytes: &'a [u8],
    pos: usize,
    line: u32,
    column: u32,
}

impl<'a> Lexer<'a> {
    /// 创建词法分析器
    pub fn new(source: &'a str) -> Self {
        Self {
            source,
            bytes: source.as_bytes(),
            pos: 0,
            line: 1,
            column: 1,
        }
    }

    /// 扫描整个源码并返回 Token 列表，末尾追加 `Eof`。
    ///
    /// 遇到词法错误时生成 `Err` token 并继续扫描（不中断），
    /// 以便 parser 能收集更多错误。
    pub fn tokenize(&mut self) -> Vec<Token<'a>> {
        let mut tokens = Vec::new();
        while self.pos < self.bytes.len() {
            let start = self.pos;
            let start_line = self.line;
            let start_col = self.column;
            match self.scan_token() {
                Ok(Some(tok)) => tokens.push(tok),
                Ok(None) => {}
                Err(_) => {
                    // 生成错误 Token，覆盖已消费的范围，继续扫描
                    tokens.push(Token {
                        kind: TokenKind::Err,
                        lexeme: &self.source[start..self.pos],
                        line: start_line,
                        column: start_col,
                    });
                }
            }
        }
        tokens.push(Token {
            kind: TokenKind::Eof,
            lexeme: "",
            line: self.line,
            column: self.column,
        });
        tokens
    }

    // --- 基础字符操作 ---

    /// 查看当前位置字符（不前进）
    #[allow(dead_code)]
    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    /// 查看下一位置字符（不前进）
    #[allow(dead_code)]
    fn peek_next(&self) -> Option<u8> {
        self.bytes.get(self.pos + 1).copied()
    }

    /// 消费当前字符并前进，遇到换行时同步更新行列号
    fn advance(&mut self) -> Option<u8> {
        let ch = *self.bytes.get(self.pos)?;
        self.pos += 1;
        if ch == b'\n' {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        Some(ch)
    }

    /// 当当前字符等于预期时消费并前进，返回是否匹配
    fn match_char(&mut self, expected: u8) -> bool {
        if self.pos >= self.bytes.len() {
            return false;
        }
        if self.bytes[self.pos] != expected {
            return false;
        }
        self.pos += 1;
        if expected == b'\n' {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        true
    }

    /// 根据起止位置与行列号构造 Token（lexeme 零拷贝引用源码）
    fn make_token(&self, kind: TokenKind, start: usize, start_line: u32, start_col: u32) -> Token<'a> {
        Token {
            kind,
            lexeme: &self.source[start..self.pos],
            line: start_line,
            column: start_col,
        }
    }

    // --- 单个词法单元扫描 ---

    /// 扫描单个词法单元：根据首字符分派到对应处理分支。
    /// 返回 `Ok(None)` 表示空白/注释/分号（不产生 Token）。
    fn scan_token(&mut self) -> Result<Option<Token<'a>>, LexerError> {
        let start = self.pos;
        let start_line = self.line;
        let start_col = self.column;
        let ch = match self.advance() {
            Some(c) => c,
            None => return Ok(None),
        };
        match ch {
            // 空白字符直接跳过
            b' ' | b'\t' | b'\r' | b'\n' => Ok(None),
            b'/' => {
                if self.match_char(b'/') {
                    self.skip_line_comment();
                    Ok(None)
                } else if self.match_char(b'*') {
                    self.skip_block_comment()?;
                    Ok(None)
                } else if self.match_char(b'=') {
                    Ok(Some(self.make_token(TokenKind::SlashEq, start, start_line, start_col)))
                } else {
                    Ok(Some(self.make_token(TokenKind::Slash, start, start_line, start_col)))
                }
            }
            b'(' => Ok(Some(self.make_token(TokenKind::LParen, start, start_line, start_col))),
            b')' => Ok(Some(self.make_token(TokenKind::RParen, start, start_line, start_col))),
            b'[' => Ok(Some(self.make_token(TokenKind::LBracket, start, start_line, start_col))),
            b']' => Ok(Some(self.make_token(TokenKind::RBracket, start, start_line, start_col))),
            b'{' => Ok(Some(self.make_token(TokenKind::LBrace, start, start_line, start_col))),
            b'}' => Ok(Some(self.make_token(TokenKind::RBrace, start, start_line, start_col))),
            b',' => Ok(Some(self.make_token(TokenKind::Comma, start, start_line, start_col))),
            // 分号被当作空白字符跳过
            b';' => Ok(None),
            b':' => Ok(Some(self.make_token(TokenKind::Colon, start, start_line, start_col))),
            b'%' => {
                if self.match_char(b'=') {
                    Ok(Some(self.make_token(TokenKind::PercentEq, start, start_line, start_col)))
                } else {
                    Ok(Some(self.make_token(TokenKind::Percent, start, start_line, start_col)))
                }
            }
            b'+' => {
                if self.match_char(b'=') {
                    Ok(Some(self.make_token(TokenKind::PlusEq, start, start_line, start_col)))
                } else if self.match_char(b'+') {
                    Ok(Some(self.make_token(TokenKind::PlusPlus, start, start_line, start_col)))
                } else {
                    Ok(Some(self.make_token(TokenKind::Plus, start, start_line, start_col)))
                }
            }
            b'*' => {
                if self.match_char(b'=') {
                    Ok(Some(self.make_token(TokenKind::StarEq, start, start_line, start_col)))
                } else {
                    Ok(Some(self.make_token(TokenKind::Star, start, start_line, start_col)))
                }
            }
            b'|' => {
                if self.match_char(b'|') {
                    Ok(Some(self.make_token(TokenKind::PipePipe, start, start_line, start_col)))
                } else if self.match_char(b'=') {
                    Ok(Some(self.make_token(TokenKind::PipeEq, start, start_line, start_col)))
                } else {
                    Ok(Some(self.make_token(TokenKind::Pipe, start, start_line, start_col)))
                }
            }
            b'=' => {
                if self.match_char(b'=') {
                    if self.match_char(b'=') {
                        Ok(Some(self.make_token(TokenKind::RefEq, start, start_line, start_col)))
                    } else {
                        Ok(Some(self.make_token(TokenKind::EqEq, start, start_line, start_col)))
                    }
                } else if self.match_char(b'>') {
                    Ok(Some(self.make_token(TokenKind::EqGt, start, start_line, start_col)))
                } else {
                    Ok(Some(self.make_token(TokenKind::Eq, start, start_line, start_col)))
                }
            }
            b'!' => {
                if self.match_char(b'=') {
                    if self.match_char(b'=') {
                        Ok(Some(self.make_token(TokenKind::RefNeq, start, start_line, start_col)))
                    } else {
                        Ok(Some(self.make_token(TokenKind::BangEq, start, start_line, start_col)))
                    }
                } else {
                    Ok(Some(self.make_token(TokenKind::Bang, start, start_line, start_col)))
                }
            }
            b'<' => {
                if self.match_char(b'<') {
                    if self.match_char(b'=') {
                        Ok(Some(self.make_token(TokenKind::LtLtEq, start, start_line, start_col)))
                    } else {
                        Ok(Some(self.make_token(TokenKind::LtLt, start, start_line, start_col)))
                    }
                } else if self.match_char(b'=') {
                    Ok(Some(self.make_token(TokenKind::LtEq, start, start_line, start_col)))
                } else if self.match_char(b'-') {
                    Ok(Some(self.make_token(TokenKind::LtMinus, start, start_line, start_col)))
                } else {
                    Ok(Some(self.make_token(TokenKind::Lt, start, start_line, start_col)))
                }
            }
            b'>' => {
                if self.match_char(b'>') {
                    if self.match_char(b'=') {
                        Ok(Some(self.make_token(TokenKind::GtGtEq, start, start_line, start_col)))
                    } else {
                        Ok(Some(self.make_token(TokenKind::GtGt, start, start_line, start_col)))
                    }
                } else if self.match_char(b'=') {
                    Ok(Some(self.make_token(TokenKind::GtEq, start, start_line, start_col)))
                } else {
                    Ok(Some(self.make_token(TokenKind::Gt, start, start_line, start_col)))
                }
            }
            b'-' => {
                if self.match_char(b'>') {
                    Ok(Some(self.make_token(TokenKind::MinusGt, start, start_line, start_col)))
                } else if self.match_char(b'=') {
                    Ok(Some(self.make_token(TokenKind::MinusEq, start, start_line, start_col)))
                } else {
                    Ok(Some(self.make_token(TokenKind::Minus, start, start_line, start_col)))
                }
            }
            b'.' => {
                if self.match_char(b'.') {
                    if self.match_char(b'=') {
                        Ok(Some(self.make_token(TokenKind::DotDotEq, start, start_line, start_col)))
                    } else if self.match_char(b'.') {
                        Ok(Some(self.make_token(TokenKind::Ellipsis, start, start_line, start_col)))
                    } else {
                        Ok(Some(self.make_token(TokenKind::DotDot, start, start_line, start_col)))
                    }
                } else {
                    // 单独点号后跟数字时，按 .浮点数 处理（如 .5）
                    if self.pos < self.bytes.len() && is_digit(self.bytes[self.pos]) {
                        self.scan_dot_float(start, start_line, start_col)
                    } else {
                        Ok(Some(self.make_token(TokenKind::Dot, start, start_line, start_col)))
                    }
                }
            }
            b'?' => {
                if self.match_char(b'.') {
                    Ok(Some(self.make_token(TokenKind::QuestionDot, start, start_line, start_col)))
                } else if self.match_char(b'?') {
                    Ok(Some(self.make_token(TokenKind::QuestionQuestion, start, start_line, start_col)))
                } else {
                    Ok(Some(self.make_token(TokenKind::Question, start, start_line, start_col)))
                }
            }
            b'&' => {
                if self.match_char(b'&') {
                    Ok(Some(self.make_token(TokenKind::AmpAmp, start, start_line, start_col)))
                } else if self.match_char(b'=') {
                    Ok(Some(self.make_token(TokenKind::AmpEq, start, start_line, start_col)))
                } else {
                    Ok(Some(self.make_token(TokenKind::Ampersand, start, start_line, start_col)))
                }
            }
            b'^' => {
                if self.match_char(b'=') {
                    Ok(Some(self.make_token(TokenKind::CaretEq, start, start_line, start_col)))
                } else {
                    Ok(Some(self.make_token(TokenKind::Caret, start, start_line, start_col)))
                }
            }
            b'~' => Ok(Some(self.make_token(TokenKind::Tilde, start, start_line, start_col))),
            b'\'' => self.scan_char(start, start_line, start_col),
            b'"' => self.scan_string(start, start_line, start_col),
            b'0'..=b'9' => self.scan_number(start, start_line, start_col),
            b'a'..=b'z' | b'A'..=b'Z' | b'_' => self.scan_identifier(start, start_line, start_col),
            // 未知字符：生成错误 Token（不中断扫描）
            _ => Ok(Some(self.make_token(TokenKind::Err, start, start_line, start_col))),
        }
    }

    // --- 注释 ---

    /// 跳过行注释（// 到行尾，不消费换行符）
    fn skip_line_comment(&mut self) {
        while self.pos < self.bytes.len() {
            if self.bytes[self.pos] == b'\n' {
                break;
            }
            self.pos += 1;
            self.column += 1;
        }
    }

    /// 跳过块注释（/* */，支持嵌套）
    fn skip_block_comment(&mut self) -> Result<(), LexerError> {
        let mut depth: u32 = 1;
        while self.pos < self.bytes.len() && depth > 0 {
            let ch = self.bytes[self.pos];
            if ch == b'/' && self.pos + 1 < self.bytes.len() && self.bytes[self.pos + 1] == b'*' {
                depth += 1;
                self.pos += 2;
                self.column += 2;
            } else if ch == b'*' && self.pos + 1 < self.bytes.len() && self.bytes[self.pos + 1] == b'/' {
                depth -= 1;
                self.pos += 2;
                self.column += 2;
            } else if ch == b'\n' {
                self.pos += 1;
                self.line += 1;
                self.column = 1;
            } else {
                self.pos += 1;
                self.column += 1;
            }
        }
        if depth > 0 {
            return Err(LexerError::UnterminatedComment);
        }
        Ok(())
    }

    // --- 数字 ---

    /// 扫描数字字面量，自动识别二/八/十六进制前缀、小数点、指数与类型后缀
    fn scan_number(&mut self, start: usize, start_line: u32, start_col: u32) -> Result<Option<Token<'a>>, LexerError> {
        if self.bytes[start] == b'0' && self.pos < self.bytes.len() {
            let prefix = self.bytes[self.pos];
            if prefix == b'x' || prefix == b'X' {
                self.pos += 1;
                self.column += 1;
                return self.scan_hex_number(start, start_line, start_col);
            } else if prefix == b'o' || prefix == b'O' {
                self.pos += 1;
                self.column += 1;
                return self.scan_octal_number(start, start_line, start_col);
            } else if prefix == b'b' || prefix == b'B' {
                self.pos += 1;
                self.column += 1;
                return self.scan_binary_number(start, start_line, start_col);
            }
        }
        while self.pos < self.bytes.len() && is_digit(self.bytes[self.pos]) {
            self.pos += 1;
            self.column += 1;
        }
        self.skip_underscore_digits(false);
        let mut is_float = false;
        // 小数部分
        if self.pos < self.bytes.len() && self.bytes[self.pos] == b'.' {
            if self.pos + 1 < self.bytes.len() && is_digit(self.bytes[self.pos + 1]) {
                is_float = true;
                self.pos += 1;
                self.column += 1;
                while self.pos < self.bytes.len() && is_digit(self.bytes[self.pos]) {
                    self.pos += 1;
                    self.column += 1;
                }
                self.skip_underscore_digits(false);
            }
        }
        // 指数部分
        if self.pos < self.bytes.len() && (self.bytes[self.pos] == b'e' || self.bytes[self.pos] == b'E') {
            is_float = true;
            self.pos += 1;
            self.column += 1;
            if self.pos < self.bytes.len() && (self.bytes[self.pos] == b'+' || self.bytes[self.pos] == b'-') {
                self.pos += 1;
                self.column += 1;
            }
            if self.pos < self.bytes.len() && is_digit(self.bytes[self.pos]) {
                while self.pos < self.bytes.len() && is_digit(self.bytes[self.pos]) {
                    self.pos += 1;
                    self.column += 1;
                }
            } else {
                return Err(LexerError::InvalidNumber);
            }
        }
        // 类型后缀（如 i32、f64），非法后缀则回退
        if self.pos < self.bytes.len() && is_identifier_start(self.bytes[self.pos]) {
            let suffix_start = self.pos;
            while self.pos < self.bytes.len() && is_identifier_continue(self.bytes[self.pos]) {
                self.pos += 1;
                self.column += 1;
            }
            let suffix = &self.source[suffix_start..self.pos];
            if is_float_suffix(suffix) {
                is_float = true;
            } else if !is_int_suffix(suffix) {
                let backtrack = self.pos - suffix_start;
                self.pos = suffix_start;
                self.column = self.column.saturating_sub(backtrack as u32);
            }
        }
        let kind = if is_float { TokenKind::FloatLiteral } else { TokenKind::IntLiteral };
        Ok(Some(self.make_token(kind, start, start_line, start_col)))
    }

    /// 跳过数字中的下划线分隔符（如 1_000），`hex` 控制是否按十六进制判断
    fn skip_underscore_digits(&mut self, hex: bool) {
        while self.pos < self.bytes.len() {
            if self.bytes[self.pos] == b'_' && self.pos + 1 < self.bytes.len() {
                let next = self.bytes[self.pos + 1];
                let valid = if hex { is_hex_digit(next) } else { is_digit(next) };
                if valid {
                    self.pos += 1;
                    self.column += 1;
                    self.pos += 1;
                    self.column += 1;
                    while self.pos < self.bytes.len() {
                        let ch = self.bytes[self.pos];
                        let ok = if hex { is_hex_digit(ch) } else { is_digit(ch) };
                        if !ok {
                            break;
                        }
                        self.pos += 1;
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
    fn scan_dot_float(&mut self, start: usize, start_line: u32, start_col: u32) -> Result<Option<Token<'a>>, LexerError> {
        while self.pos < self.bytes.len() && is_digit(self.bytes[self.pos]) {
            self.pos += 1;
            self.column += 1;
        }
        self.skip_underscore_digits(false);
        if self.pos < self.bytes.len() && (self.bytes[self.pos] == b'e' || self.bytes[self.pos] == b'E') {
            self.pos += 1;
            self.column += 1;
            if self.pos < self.bytes.len() && (self.bytes[self.pos] == b'+' || self.bytes[self.pos] == b'-') {
                self.pos += 1;
                self.column += 1;
            }
            if self.pos < self.bytes.len() && is_digit(self.bytes[self.pos]) {
                while self.pos < self.bytes.len() && is_digit(self.bytes[self.pos]) {
                    self.pos += 1;
                    self.column += 1;
                }
            } else {
                return Err(LexerError::InvalidNumber);
            }
        }
        // .浮点数 仅允许浮点类型后缀，非法后缀则回退
        if self.pos < self.bytes.len() && is_identifier_start(self.bytes[self.pos]) {
            let suffix_start = self.pos;
            while self.pos < self.bytes.len() && is_identifier_continue(self.bytes[self.pos]) {
                self.pos += 1;
                self.column += 1;
            }
            let suffix = &self.source[suffix_start..self.pos];
            if !is_float_suffix(suffix) {
                let backtrack = self.pos - suffix_start;
                self.pos = suffix_start;
                self.column = self.column.saturating_sub(backtrack as u32);
            }
        }
        Ok(Some(self.make_token(TokenKind::FloatLiteral, start, start_line, start_col)))
    }

    /// 扫描十六进制数字字面量（0x 前缀），支持十六进制小数与 p 指数
    fn scan_hex_number(&mut self, start: usize, start_line: u32, start_col: u32) -> Result<Option<Token<'a>>, LexerError> {
        let mut has_digits = false;
        while self.pos < self.bytes.len() && is_hex_digit(self.bytes[self.pos]) {
            has_digits = true;
            self.pos += 1;
            self.column += 1;
        }
        self.skip_underscore_digits(true);
        let mut is_float = false;
        if self.pos < self.bytes.len() && self.bytes[self.pos] == b'.' {
            if self.pos + 1 < self.bytes.len()
                && (is_hex_digit(self.bytes[self.pos + 1])
                    || self.bytes[self.pos + 1] == b'p'
                    || self.bytes[self.pos + 1] == b'P')
            {
                is_float = true;
                self.pos += 1;
                self.column += 1;
                while self.pos < self.bytes.len() && is_hex_digit(self.bytes[self.pos]) {
                    self.pos += 1;
                    self.column += 1;
                }
                self.skip_underscore_digits(true);
            }
        }
        if self.pos < self.bytes.len() && (self.bytes[self.pos] == b'p' || self.bytes[self.pos] == b'P') {
            is_float = true;
            self.pos += 1;
            self.column += 1;
            if self.pos < self.bytes.len() && (self.bytes[self.pos] == b'+' || self.bytes[self.pos] == b'-') {
                self.pos += 1;
                self.column += 1;
            }
            if self.pos < self.bytes.len() && is_digit(self.bytes[self.pos]) {
                while self.pos < self.bytes.len() && is_digit(self.bytes[self.pos]) {
                    self.pos += 1;
                    self.column += 1;
                }
            } else {
                return Err(LexerError::InvalidNumber);
            }
        }
        if !has_digits {
            return Err(LexerError::InvalidHexDigit);
        }
        // 类型后缀，非法则回退
        if self.pos < self.bytes.len() && is_identifier_start(self.bytes[self.pos]) {
            let suffix_start = self.pos;
            while self.pos < self.bytes.len() && is_identifier_continue(self.bytes[self.pos]) {
                self.pos += 1;
                self.column += 1;
            }
            let suffix = &self.source[suffix_start..self.pos];
            if !is_int_suffix(suffix) && !is_float_suffix(suffix) {
                let backtrack = self.pos - suffix_start;
                self.pos = suffix_start;
                self.column = self.column.saturating_sub(backtrack as u32);
            }
        }
        let kind = if is_float { TokenKind::FloatLiteral } else { TokenKind::IntLiteral };
        Ok(Some(self.make_token(kind, start, start_line, start_col)))
    }

    /// 扫描八进制数字字面量（0o 前缀）
    fn scan_octal_number(&mut self, start: usize, start_line: u32, start_col: u32) -> Result<Option<Token<'a>>, LexerError> {
        let mut has_digits = false;
        while self.pos < self.bytes.len() && is_octal_digit(self.bytes[self.pos]) {
            has_digits = true;
            self.pos += 1;
            self.column += 1;
        }
        while self.pos < self.bytes.len() {
            if self.bytes[self.pos] == b'_'
                && self.pos + 1 < self.bytes.len()
                && is_octal_digit(self.bytes[self.pos + 1])
            {
                has_digits = true;
                self.pos += 1;
                self.column += 1;
                self.pos += 1;
                self.column += 1;
                while self.pos < self.bytes.len() && is_octal_digit(self.bytes[self.pos]) {
                    self.pos += 1;
                    self.column += 1;
                }
            } else {
                break;
            }
        }
        if !has_digits {
            return Err(LexerError::InvalidOctalDigit);
        }
        // 仅允许整数类型后缀，非法则回退
        if self.pos < self.bytes.len() && is_identifier_start(self.bytes[self.pos]) {
            let suffix_start = self.pos;
            while self.pos < self.bytes.len() && is_identifier_continue(self.bytes[self.pos]) {
                self.pos += 1;
                self.column += 1;
            }
            let suffix = &self.source[suffix_start..self.pos];
            if !is_int_suffix(suffix) {
                let backtrack = self.pos - suffix_start;
                self.pos = suffix_start;
                self.column = self.column.saturating_sub(backtrack as u32);
            }
        }
        Ok(Some(self.make_token(TokenKind::IntLiteral, start, start_line, start_col)))
    }

    /// 扫描二进制数字字面量（0b 前缀）
    fn scan_binary_number(&mut self, start: usize, start_line: u32, start_col: u32) -> Result<Option<Token<'a>>, LexerError> {
        let mut has_digits = false;
        while self.pos < self.bytes.len() && is_binary_digit(self.bytes[self.pos]) {
            has_digits = true;
            self.pos += 1;
            self.column += 1;
        }
        while self.pos < self.bytes.len() {
            if self.bytes[self.pos] == b'_'
                && self.pos + 1 < self.bytes.len()
                && is_binary_digit(self.bytes[self.pos + 1])
            {
                has_digits = true;
                self.pos += 1;
                self.column += 1;
                self.pos += 1;
                self.column += 1;
                while self.pos < self.bytes.len() && is_binary_digit(self.bytes[self.pos]) {
                    self.pos += 1;
                    self.column += 1;
                }
            } else {
                break;
            }
        }
        if !has_digits {
            return Err(LexerError::InvalidBinaryDigit);
        }
        if self.pos < self.bytes.len() && is_identifier_start(self.bytes[self.pos]) {
            let suffix_start = self.pos;
            while self.pos < self.bytes.len() && is_identifier_continue(self.bytes[self.pos]) {
                self.pos += 1;
                self.column += 1;
            }
            let suffix = &self.source[suffix_start..self.pos];
            if !is_int_suffix(suffix) {
                let backtrack = self.pos - suffix_start;
                self.pos = suffix_start;
                self.column = self.column.saturating_sub(backtrack as u32);
            }
        }
        Ok(Some(self.make_token(TokenKind::IntLiteral, start, start_line, start_col)))
    }

    // --- 字符 ---

    /// 扫描字符字面量（'x'），支持转义与 Unicode 转义 \u{...}
    fn scan_char(&mut self, start: usize, start_line: u32, start_col: u32) -> Result<Option<Token<'a>>, LexerError> {
        if self.pos >= self.bytes.len() {
            return Err(LexerError::UnterminatedChar);
        }
        if self.bytes[self.pos] == b'\\' {
            self.pos += 1;
            self.column += 1;
            if self.pos >= self.bytes.len() {
                return Err(LexerError::UnterminatedChar);
            }
            let escaped = self.bytes[self.pos];
            match escaped {
                b'n' | b't' | b'r' | b'\\' | b'\'' | b'0' => {
                    self.pos += 1;
                    self.column += 1;
                }
                b'u' => {
                    self.pos += 1;
                    self.column += 1;
                    if self.pos >= self.bytes.len() || self.bytes[self.pos] != b'{' {
                        return Err(LexerError::InvalidUnicodeEscape);
                    }
                    self.pos += 1;
                    self.column += 1;
                    let mut digit_count: usize = 0;
                    while self.pos < self.bytes.len() && self.bytes[self.pos] != b'}' {
                        if !is_hex_digit(self.bytes[self.pos]) {
                            return Err(LexerError::InvalidUnicodeEscape);
                        }
                        self.pos += 1;
                        self.column += 1;
                        digit_count += 1;
                    }
                    if digit_count == 0 || self.pos >= self.bytes.len() {
                        return Err(LexerError::InvalidUnicodeEscape);
                    }
                    self.pos += 1;
                    self.column += 1;
                }
                _ => {
                    return Err(LexerError::InvalidEscape);
                }
            }
        } else {
            self.pos += 1;
            self.column += 1;
        }
        if self.pos >= self.bytes.len() || self.bytes[self.pos] != b'\'' {
            return Err(LexerError::UnterminatedChar);
        }
        self.pos += 1;
        self.column += 1;
        Ok(Some(self.make_token(TokenKind::CharLiteral, start, start_line, start_col)))
    }

    // --- 字符串 ---

    /// 扫描字符串字面量，支持转义、`{{` `}}` 字面花括号与 `{表达式}` 插值。
    ///
    /// 整个字符串字面量（含插值部分）被作为单个 `StringLiteral` Token，
    /// lexeme 包含原始文本。字符串中不允许裸换行。
    fn scan_string(&mut self, start: usize, start_line: u32, start_col: u32) -> Result<Option<Token<'a>>, LexerError> {
        while self.pos < self.bytes.len() {
            let ch = self.bytes[self.pos];
            if ch == b'"' {
                self.pos += 1;
                self.column += 1;
                return Ok(Some(self.make_token(TokenKind::StringLiteral, start, start_line, start_col)));
            }
            if ch == b'\\' {
                self.pos += 1;
                self.column += 1;
                if self.pos >= self.bytes.len() {
                    return Err(LexerError::UnterminatedString);
                }
                let escaped = self.bytes[self.pos];
                match escaped {
                    b'"' | b'\\' | b'n' | b't' | b'r' | b'{' | b'}' => {
                        self.pos += 1;
                        self.column += 1;
                    }
                    _ => {
                        return Err(LexerError::InvalidEscape);
                    }
                }
            } else if ch == b'{' {
                // {{ 表示字面 {，否则进入插值表达式扫描
                if self.pos + 1 < self.bytes.len() && self.bytes[self.pos + 1] == b'{' {
                    self.pos += 2;
                    self.column += 2;
                } else {
                    self.pos += 1;
                    self.column += 1;
                    let mut brace_depth: u32 = 1;
                    while self.pos < self.bytes.len() && brace_depth > 0 {
                        let inner = self.bytes[self.pos];
                        if inner == b'\\' {
                            self.pos += 1;
                            self.column += 1;
                            if self.pos < self.bytes.len() {
                                self.pos += 1;
                                self.column += 1;
                            }
                            continue;
                        } else if inner == b'{' {
                            brace_depth += 1;
                        } else if inner == b'}' {
                            brace_depth -= 1;
                        } else if inner == b'"' {
                            // 插值表达式中嵌套的字符串字面量
                            self.pos += 1;
                            self.column += 1;
                            while self.pos < self.bytes.len() && self.bytes[self.pos] != b'"' {
                                if self.bytes[self.pos] == b'\\' {
                                    self.pos += 1;
                                    self.column += 1;
                                    if self.pos < self.bytes.len() {
                                        self.pos += 1;
                                        self.column += 1;
                                    }
                                } else {
                                    if self.bytes[self.pos] == b'\n' {
                                        self.line += 1;
                                        self.column = 1;
                                    } else {
                                        self.column += 1;
                                    }
                                    self.pos += 1;
                                }
                            }
                            if self.pos < self.bytes.len() {
                                self.pos += 1;
                                self.column += 1;
                            }
                            continue;
                        }
                        if inner == b'\n' {
                            self.line += 1;
                            self.column = 1;
                        } else {
                            self.column += 1;
                        }
                        self.pos += 1;
                    }
                }
            } else if ch == b'}' {
                // }} 表示字面 }
                if self.pos + 1 < self.bytes.len() && self.bytes[self.pos + 1] == b'}' {
                    self.pos += 2;
                    self.column += 2;
                } else {
                    self.pos += 1;
                    self.column += 1;
                }
            } else if ch == b'\n' {
                return Err(LexerError::UnterminatedString);
            } else {
                self.pos += 1;
                self.column += 1;
            }
        }
        Err(LexerError::UnterminatedString)
    }

    // --- 标识符 ---

    /// 扫描标识符或关键字，通过关键字表判定最终 Token 类型
    fn scan_identifier(&mut self, start: usize, start_line: u32, start_col: u32) -> Result<Option<Token<'a>>, LexerError> {
        while self.pos < self.bytes.len() && is_identifier_continue(self.bytes[self.pos]) {
            self.pos += 1;
            self.column += 1;
        }
        let text = &self.source[start..self.pos];
        let kind = keyword_type(text);
        Ok(Some(self.make_token(kind, start, start_line, start_col)))
    }
}

// =========================================================================
// 辅助函数
// =========================================================================

/// 判断是否为十进制数字
fn is_digit(ch: u8) -> bool {
    ch.is_ascii_digit()
}

/// 判断是否为十六进制数字
fn is_hex_digit(ch: u8) -> bool {
    ch.is_ascii_hexdigit()
}

/// 判断是否为八进制数字
fn is_octal_digit(ch: u8) -> bool {
    (b'0'..=b'7').contains(&ch)
}

/// 判断是否为二进制数字
fn is_binary_digit(ch: u8) -> bool {
    ch == b'0' || ch == b'1'
}

/// 判断字符是否可作为标识符首字符（仅 ASCII）
fn is_identifier_start(ch: u8) -> bool {
    ch.is_ascii_alphabetic() || ch == b'_'
}

/// 判断字符是否可作为标识符后续字符（仅 ASCII）
fn is_identifier_continue(ch: u8) -> bool {
    is_identifier_start(ch) || is_digit(ch)
}

/// 查询文本是否为关键字，否则返回 `Identifier`
fn keyword_type(text: &str) -> TokenKind {
    match text {
        "fun" => TokenKind::KwFun,
        "type" => TokenKind::KwType,
        "trait" => TokenKind::KwTrait,
        "override" => TokenKind::KwOverride,
        "pack" => TokenKind::KwPack,
        "pub" => TokenKind::KwPub,
        "import" => TokenKind::KwImport,
        "with" => TokenKind::KwWith,
        "as" => TokenKind::KwAs,
        "val" => TokenKind::KwVal,
        "var" => TokenKind::KwVar,
        "match" => TokenKind::KwMatch,
        "if" => TokenKind::KwIf,
        "else" => TokenKind::KwElse,
        "async" => TokenKind::KwAsync,
        "channel" => TokenKind::KwChannel,
        "select" => TokenKind::KwSelect,
        "atomic" => TokenKind::KwAtomic,
        "loop" => TokenKind::KwLoop,
        "for" => TokenKind::KwFor,
        "in" => TokenKind::KwIn,
        "while" => TokenKind::KwWhile,
        "break" => TokenKind::KwBreak,
        "continue" => TokenKind::KwContinue,
        "return" => TokenKind::KwReturn,
        "throw" => TokenKind::KwThrow,
        "lazy" => TokenKind::KwLazy,
        "defer" => TokenKind::KwDefer,
        "true" => TokenKind::TrueLiteral,
        "false" => TokenKind::FalseLiteral,
        "null" => TokenKind::NullLiteral,
        _ => TokenKind::Identifier,
    }
}

/// 判断后缀是否为合法整数类型后缀
fn is_int_suffix(suffix: &str) -> bool {
    matches!(
        suffix,
        "i8" | "i16" | "i32" | "i64" | "i128" | "u8" | "u16" | "u32" | "u64" | "u128" | "isize" | "usize"
    )
}

/// 判断后缀是否为合法浮点类型后缀
fn is_float_suffix(suffix: &str) -> bool {
    matches!(suffix, "f16" | "f32" | "f64" | "f128")
}

// =========================================================================
// 测试
// =========================================================================

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(src: &str) -> Vec<TokenKind> {
        let mut lexer = Lexer::new(src);
        lexer.tokenize().into_iter().map(|t| t.kind).collect()
    }

    fn lexemes(src: &str) -> Vec<&str> {
        let mut lexer = Lexer::new(src);
        lexer.tokenize().into_iter().map(|t| t.lexeme).collect()
    }

    #[test]
    fn test_keywords_and_literals() {
        assert_eq!(
            kinds("fun type trait override pack pub import with as val var"),
            vec![
                TokenKind::KwFun,
                TokenKind::KwType,
                TokenKind::KwTrait,
                TokenKind::KwOverride,
                TokenKind::KwPack,
                TokenKind::KwPub,
                TokenKind::KwImport,
                TokenKind::KwWith,
                TokenKind::KwAs,
                TokenKind::KwVal,
                TokenKind::KwVar,
                TokenKind::Eof,
            ]
        );
        assert_eq!(
            kinds("match if else async channel select atomic loop for in while break continue"),
            vec![
                TokenKind::KwMatch,
                TokenKind::KwIf,
                TokenKind::KwElse,
                TokenKind::KwAsync,
                TokenKind::KwChannel,
                TokenKind::KwSelect,
                TokenKind::KwAtomic,
                TokenKind::KwLoop,
                TokenKind::KwFor,
                TokenKind::KwIn,
                TokenKind::KwWhile,
                TokenKind::KwBreak,
                TokenKind::KwContinue,
                TokenKind::Eof,
            ]
        );
        assert_eq!(
            kinds("return throw lazy defer true false null"),
            vec![
                TokenKind::KwReturn,
                TokenKind::KwThrow,
                TokenKind::KwLazy,
                TokenKind::KwDefer,
                TokenKind::TrueLiteral,
                TokenKind::FalseLiteral,
                TokenKind::NullLiteral,
                TokenKind::Eof,
            ]
        );
    }

    #[test]
    fn test_identifiers() {
        assert_eq!(
            kinds("foo bar_baz _x _123 ABC"),
            vec![
                TokenKind::Identifier,
                TokenKind::Identifier,
                TokenKind::Identifier,
                TokenKind::Identifier,
                TokenKind::Identifier,
                TokenKind::Eof,
            ]
        );
        assert_eq!(lexemes("foo bar_baz"), vec!["foo", "bar_baz", ""]);
    }

    #[test]
    fn test_integer_literals() {
        assert_eq!(
            kinds("42 0 1_000 0x1F 0o17 0b1010"),
            vec![
                TokenKind::IntLiteral,
                TokenKind::IntLiteral,
                TokenKind::IntLiteral,
                TokenKind::IntLiteral,
                TokenKind::IntLiteral,
                TokenKind::IntLiteral,
                TokenKind::Eof,
            ]
        );
        assert_eq!(lexemes("42 1_000 0x1F 0o17 0b1010"), vec!["42", "1_000", "0x1F", "0o17", "0b1010", ""]);
    }

    #[test]
    fn test_integer_suffix() {
        assert_eq!(
            kinds("42i32 100u64 0xFFu8"),
            vec![TokenKind::IntLiteral, TokenKind::IntLiteral, TokenKind::IntLiteral, TokenKind::Eof]
        );
        assert_eq!(lexemes("42i32 100u64"), vec!["42i32", "100u64", ""]);
    }

    #[test]
    fn test_underscore_prefixed_suffix_fallback() {
        // 下划线开头的后缀（如 _u8）不是合法类型后缀，回退为标识符
        assert_eq!(
            kinds("0xFF_u8"),
            vec![TokenKind::IntLiteral, TokenKind::Identifier, TokenKind::Eof]
        );
        assert_eq!(lexemes("0xFF_u8"), vec!["0xFF", "_u8", ""]);
    }

    #[test]
    fn test_invalid_suffix_fallback() {
        // 非法后缀回退：42 后 abc 不是合法类型后缀，回退为标识符
        assert_eq!(
            kinds("42abc"),
            vec![TokenKind::IntLiteral, TokenKind::Identifier, TokenKind::Eof]
        );
        assert_eq!(lexemes("42abc"), vec!["42", "abc", ""]);
    }

    #[test]
    fn test_float_literals() {
        assert_eq!(
            kinds("3.14 1e10 .5 1.5e-3 0x1p4 1.0f64"),
            vec![
                TokenKind::FloatLiteral,
                TokenKind::FloatLiteral,
                TokenKind::FloatLiteral,
                TokenKind::FloatLiteral,
                TokenKind::FloatLiteral,
                TokenKind::FloatLiteral,
                TokenKind::Eof,
            ]
        );
        assert_eq!(lexemes("3.14 .5 1.5e-3"), vec!["3.14", ".5", "1.5e-3", ""]);
    }

    #[test]
    fn test_float_suffix_forces_float() {
        // 即使没有小数点，浮点后缀也强制为浮点
        assert_eq!(kinds("10f64"), vec![TokenKind::FloatLiteral, TokenKind::Eof]);
    }

    #[test]
    fn test_dot_float_invalid_suffix_fallback() {
        // .5abc：abc 非浮点后缀，回退为标识符
        assert_eq!(
            kinds(".5abc"),
            vec![TokenKind::FloatLiteral, TokenKind::Identifier, TokenKind::Eof]
        );
        assert_eq!(lexemes(".5abc"), vec![".5", "abc", ""]);
    }

    #[test]
    fn test_char_literals() {
        assert_eq!(
            kinds("'a' '\\n' '\\'' '\\\\' '\\0' '\\u{1F600}'"),
            vec![
                TokenKind::CharLiteral,
                TokenKind::CharLiteral,
                TokenKind::CharLiteral,
                TokenKind::CharLiteral,
                TokenKind::CharLiteral,
                TokenKind::CharLiteral,
                TokenKind::Eof,
            ]
        );
        assert_eq!(lexemes("'a' '\\u{1F600}'"), vec!["'a'", "'\\u{1F600}'", ""]);
    }

    #[test]
    fn test_string_literal_basic() {
        assert_eq!(kinds("\"hello\""), vec![TokenKind::StringLiteral, TokenKind::Eof]);
        assert_eq!(lexemes("\"hello\""), vec!["\"hello\"", ""]);
    }

    #[test]
    fn test_string_literal_braces() {
        // {{ 与 }} 表示字面花括号，仍是单个字符串 Token
        assert_eq!(kinds("\"{{x}}\""), vec![TokenKind::StringLiteral, TokenKind::Eof]);
        assert_eq!(lexemes("\"{{x}}\""), vec!["\"{{x}}\"", ""]);
    }

    #[test]
    fn test_string_interpolation() {
        // {1+2} 插值表达式，整个字符串作为单个 Token
        assert_eq!(kinds("\"a{1+2}b\""), vec![TokenKind::StringLiteral, TokenKind::Eof]);
        assert_eq!(lexemes("\"a{1+2}b\""), vec!["\"a{1+2}b\"", ""]);
    }

    #[test]
    fn test_string_interpolation_nested_braces() {
        // 嵌套花括号
        assert_eq!(kinds("\"a{f({x:1})}b\""), vec![TokenKind::StringLiteral, TokenKind::Eof]);
        assert_eq!(lexemes("\"a{f({x:1})}b\""), vec!["\"a{f({x:1})}b\"", ""]);
    }

    #[test]
    fn test_string_interpolation_nested_string() {
        // 插值表达式中嵌套字符串字面量（转义形式：\" 走转义分支）
        assert_eq!(kinds("\"a{\\\"x\\\"}b\""), vec![TokenKind::StringLiteral, TokenKind::Eof]);
        assert_eq!(lexemes("\"a{\\\"x\\\"}b\""), vec!["\"a{\\\"x\\\"}b\"", ""]);
        // 插值表达式中嵌套裸字符串字面量（走嵌套字符串扫描分支）
        assert_eq!(kinds("\"a{\"x\"}b\""), vec![TokenKind::StringLiteral, TokenKind::Eof]);
        assert_eq!(lexemes("\"a{\"x\"}b\""), vec!["\"a{\"x\"}b\"", ""]);
    }

    #[test]
    fn test_string_escapes() {
        assert_eq!(
            kinds("\"a\\nb\\tc\\\\d\\\"e\\{f\\}g\""),
            vec![TokenKind::StringLiteral, TokenKind::Eof]
        );
    }

    #[test]
    fn test_line_comment() {
        assert_eq!(kinds("// comment\n42"), vec![TokenKind::IntLiteral, TokenKind::Eof]);
        assert_eq!(kinds("42 // trailing"), vec![TokenKind::IntLiteral, TokenKind::Eof]);
    }

    #[test]
    fn test_block_comment() {
        assert_eq!(kinds("/* x */ 42"), vec![TokenKind::IntLiteral, TokenKind::Eof]);
        // 嵌套块注释
        assert_eq!(kinds("/* /* */ */ 42"), vec![TokenKind::IntLiteral, TokenKind::Eof]);
    }

    #[test]
    fn test_semicolon_skipped() {
        // 分号被当作空白字符跳过，不产生 Token
        assert_eq!(kinds("42;"), vec![TokenKind::IntLiteral, TokenKind::Eof]);
        assert_eq!(kinds("a;b;c"), vec![TokenKind::Identifier, TokenKind::Identifier, TokenKind::Identifier, TokenKind::Eof]);
    }

    #[test]
    fn test_operators() {
        let cases: &[(&str, TokenKind)] = &[
            ("+", TokenKind::Plus),
            ("-", TokenKind::Minus),
            ("*", TokenKind::Star),
            ("/", TokenKind::Slash),
            ("%", TokenKind::Percent),
            ("==", TokenKind::EqEq),
            ("!=", TokenKind::BangEq),
            ("===", TokenKind::RefEq),
            ("!==", TokenKind::RefNeq),
            ("<", TokenKind::Lt),
            (">", TokenKind::Gt),
            ("<=", TokenKind::LtEq),
            (">=", TokenKind::GtEq),
            ("<-", TokenKind::LtMinus),
            ("&&", TokenKind::AmpAmp),
            ("||", TokenKind::PipePipe),
            ("!", TokenKind::Bang),
            ("&", TokenKind::Ampersand),
            ("^", TokenKind::Caret),
            ("?.", TokenKind::QuestionDot),
            ("??", TokenKind::QuestionQuestion),
            ("?", TokenKind::Question),
            ("..", TokenKind::DotDot),
            ("..=", TokenKind::DotDotEq),
            ("...", TokenKind::Ellipsis),
            ("=", TokenKind::Eq),
            ("+=", TokenKind::PlusEq),
            ("++", TokenKind::PlusPlus),
            ("-=", TokenKind::MinusEq),
            ("*=", TokenKind::StarEq),
            ("/=", TokenKind::SlashEq),
            ("%=", TokenKind::PercentEq),
            ("&=", TokenKind::AmpEq),
            ("|=", TokenKind::PipeEq),
            ("^=", TokenKind::CaretEq),
            ("<<", TokenKind::LtLt),
            (">>", TokenKind::GtGt),
            ("<<=", TokenKind::LtLtEq),
            (">>=", TokenKind::GtGtEq),
            ("~", TokenKind::Tilde),
            ("=>", TokenKind::EqGt),
            ("->", TokenKind::MinusGt),
        ];
        for (input, expected) in cases {
            let toks = Lexer::new(input).tokenize();
            assert_eq!(toks[0].kind, *expected, "input {:?}", input);
            assert_eq!(toks[1].kind, TokenKind::Eof, "input {:?}", input);
            assert_eq!(toks[0].lexeme, *input, "lexeme for {:?}", input);
        }
    }

    #[test]
    fn test_delimiters() {
        assert_eq!(
            kinds("( ) [ ] { } , : . |"),
            vec![
                TokenKind::LParen,
                TokenKind::RParen,
                TokenKind::LBracket,
                TokenKind::RBracket,
                TokenKind::LBrace,
                TokenKind::RBrace,
                TokenKind::Comma,
                TokenKind::Colon,
                TokenKind::Dot,
                TokenKind::Pipe,
                TokenKind::Eof,
            ]
        );
    }

    #[test]
    fn test_unexpected_character() {
        // 未知字符生成 Err Token，继续扫描
        let toks = Lexer::new("@").tokenize();
        assert_eq!(toks[0].kind, TokenKind::Err);
        assert_eq!(toks[1].kind, TokenKind::Eof);
    }

    #[test]
    fn test_unterminated_string() {
        let toks = Lexer::new("\"abc").tokenize();
        assert!(toks.iter().any(|t| t.kind == TokenKind::Err));
        assert_eq!(toks.last().unwrap().kind, TokenKind::Eof);
    }

    #[test]
    fn test_unterminated_char() {
        let toks = Lexer::new("'a").tokenize();
        assert!(toks.iter().any(|t| t.kind == TokenKind::Err));
    }

    #[test]
    fn test_unterminated_block_comment() {
        let toks = Lexer::new("/* abc").tokenize();
        assert!(toks.iter().any(|t| t.kind == TokenKind::Err));
    }

    #[test]
    fn test_newline_in_string_errors() {
        let toks = Lexer::new("\"a\nb\"").tokenize();
        assert!(toks.iter().any(|t| t.kind == TokenKind::Err));
    }

    #[test]
    fn test_invalid_escape_errors() {
        let toks = Lexer::new("\"\\q\"").tokenize();
        assert!(toks.iter().any(|t| t.kind == TokenKind::Err));
        let toks = Lexer::new("'\\q'").tokenize();
        assert!(toks.iter().any(|t| t.kind == TokenKind::Err));
    }

    #[test]
    fn test_invalid_unicode_escape() {
        // \u{} 空内容
        let toks = Lexer::new("'\\u{}'").tokenize();
        assert!(toks.iter().any(|t| t.kind == TokenKind::Err));
        // \u{GG} 非十六进制
        let toks = Lexer::new("'\\u{GG}'").tokenize();
        assert!(toks.iter().any(|t| t.kind == TokenKind::Err));
    }

    #[test]
    fn test_invalid_hex_literal() {
        // 0x 后无数字
        let toks = Lexer::new("0x").tokenize();
        assert!(toks.iter().any(|t| t.kind == TokenKind::Err));
    }

    #[test]
    fn test_invalid_exponent() {
        // 1e 后无数字
        let toks = Lexer::new("1e").tokenize();
        assert!(toks.iter().any(|t| t.kind == TokenKind::Err));
    }

    #[test]
    fn test_positions() {
        let toks = Lexer::new("ab\ncd").tokenize();
        assert_eq!(toks[0].kind, TokenKind::Identifier);
        assert_eq!(toks[0].lexeme, "ab");
        assert_eq!(toks[0].line, 1);
        assert_eq!(toks[0].column, 1);
        assert_eq!(toks[1].kind, TokenKind::Identifier);
        assert_eq!(toks[1].lexeme, "cd");
        assert_eq!(toks[1].line, 2);
        assert_eq!(toks[1].column, 1);
        assert_eq!(toks[2].kind, TokenKind::Eof);
    }

    #[test]
    fn test_empty_source() {
        let toks = Lexer::new("").tokenize();
        assert_eq!(toks.len(), 1);
        assert_eq!(toks[0].kind, TokenKind::Eof);
    }

    #[test]
    fn test_whitespace_only() {
        let toks = Lexer::new("   \n\t  \n").tokenize();
        assert_eq!(toks.len(), 1);
        assert_eq!(toks[0].kind, TokenKind::Eof);
        assert_eq!(toks[0].line, 3);
    }

    #[test]
    fn test_mixed_tokens() {
        let src = "val x = 42; fun f() { return x }";
        let toks = Lexer::new(src).tokenize();
        let expected = vec![
            TokenKind::KwVal,
            TokenKind::Identifier,
            TokenKind::Eq,
            TokenKind::IntLiteral,
            TokenKind::KwFun,
            TokenKind::Identifier,
            TokenKind::LParen,
            TokenKind::RParen,
            TokenKind::LBrace,
            TokenKind::KwReturn,
            TokenKind::Identifier,
            TokenKind::RBrace,
            TokenKind::Eof,
        ];
        let actual: Vec<TokenKind> = toks.iter().map(|t| t.kind).collect();
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_error_recovery_continues() {
        // 错误后继续扫描，后续合法 Token 仍能被识别。
        // `1e` 是非法指数（缺数字），生成 Err 后 `+ 42` 仍被正常识别。
        let toks = Lexer::new("1e + 42").tokenize();
        assert!(toks.iter().any(|t| t.kind == TokenKind::Err));
        assert!(toks.iter().any(|t| t.kind == TokenKind::Plus));
        assert!(toks.iter().any(|t| t.kind == TokenKind::IntLiteral));
        assert_eq!(toks.last().unwrap().kind, TokenKind::Eof);
    }

    #[test]
    fn test_no_infinite_loop_on_recovery() {
        // 确保错误恢复总能前进，不会死循环
        let toks = Lexer::new("@@@@").tokenize();
        assert_eq!(toks.iter().filter(|t| t.kind == TokenKind::Err).count(), 4);
        assert_eq!(toks.last().unwrap().kind, TokenKind::Eof);
    }
}
