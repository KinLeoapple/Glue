//! Glue 字符类型
//!
//! 对应 Zig 实现中的 `char.zig`。包装 Unicode codepoint，
//! 提供字符分类与转换方法。

// =========================================================================
// CharError — 字符错误
// =========================================================================

/// 字符错误：codepoint 越界
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CharError {
    /// codepoint 超出合法 Unicode 范围（> 0x10FFFF）
    InvalidCodepoint,
}

// =========================================================================
// Char — Unicode 字符
// =========================================================================

/// Unicode 字符：包装 codepoint（u32）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Char {
    /// Unicode codepoint
    pub codepoint: u32,
}

impl Char {
    /// 从 codepoint 构造（校验合法性）
    pub fn from_codepoint(cp: u32) -> Result<Self, CharError> {
        if cp > 0x10FFFF || (0xD800..=0xDFFF).contains(&cp) {
            return Err(CharError::InvalidCodepoint);
        }
        Ok(Char { codepoint: cp })
    }

    /// 从 codepoint 构造（不校验，调用方需保证合法）
    pub fn from_codepoint_unchecked(cp: u32) -> Self {
        Char { codepoint: cp }
    }

    /// 获取 codepoint
    pub fn codepoint(self) -> u32 {
        self.codepoint
    }

    /// 是否为 ASCII（< 128）
    pub fn is_ascii(self) -> bool {
        self.codepoint < 0x80
    }

    /// 是否为数字 '0'..='9'
    pub fn is_digit(self) -> bool {
        (b'0' as u32..=b'9' as u32).contains(&self.codepoint)
    }

    /// 是否为字母 'a'..='z' 或 'A'..='Z'
    pub fn is_alpha(self) -> bool {
        (b'a' as u32..=b'z' as u32).contains(&self.codepoint)
            || (b'A' as u32..=b'Z' as u32).contains(&self.codepoint)
    }

    /// 是否为字母或数字
    pub fn is_alphanumeric(self) -> bool {
        self.is_alpha() || self.is_digit()
    }

    /// 是否为空白字符
    pub fn is_whitespace(self) -> bool {
        matches!(
            self.codepoint,
            0x09 | 0x0A | 0x0B | 0x0C | 0x0D | 0x20 | 0x85 | 0xA0
        )
    }

    /// 转大写（仅处理 ASCII）
    pub fn to_upper(self) -> Self {
        if (b'a' as u32..=b'z' as u32).contains(&self.codepoint) {
            Char { codepoint: self.codepoint - 32 }
        } else {
            self
        }
    }

    /// 转小写（仅处理 ASCII）
    pub fn to_lower(self) -> Self {
        if (b'A' as u32..=b'Z' as u32).contains(&self.codepoint) {
            Char { codepoint: self.codepoint + 32 }
        } else {
            self
        }
    }

    /// 后继字符
    pub fn successor(self) -> Self {
        Char { codepoint: self.codepoint.wrapping_add(1) }
    }

    /// 前驱字符
    pub fn predecessor(self) -> Self {
        Char { codepoint: self.codepoint.wrapping_sub(1) }
    }

    /// 比较
    pub fn compare(self, other: Self) -> std::cmp::Ordering {
        self.codepoint.cmp(&other.codepoint)
    }
}

impl std::fmt::Display for Char {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        if let Some(c) = char::from_u32(self.codepoint) {
            write!(f, "{}", c)
        } else {
            write!(f, "\u{FFFD}")
        }
    }
}

impl From<char> for Char {
    fn from(c: char) -> Self {
        Char { codepoint: c as u32 }
    }
}

// =========================================================================
// 测试
// =========================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_from_codepoint_valid() {
        assert!(Char::from_codepoint(0x41).is_ok());
        assert!(Char::from_codepoint(0x10FFFF).is_ok());
        assert!(Char::from_codepoint(0).is_ok());
    }

    #[test]
    fn test_from_codepoint_invalid() {
        assert_eq!(Char::from_codepoint(0x110000), Err(CharError::InvalidCodepoint));
        assert_eq!(Char::from_codepoint(0xD800), Err(CharError::InvalidCodepoint));
        assert_eq!(Char::from_codepoint(0xDFFF), Err(CharError::InvalidCodepoint));
    }

    #[test]
    fn test_classification() {
        let a = Char::from('a');
        assert!(a.is_alpha());
        assert!(!a.is_digit());
        assert!(a.is_ascii());

        let five = Char::from('5');
        assert!(five.is_digit());
        assert!(!five.is_alpha());

        let space = Char::from(' ');
        assert!(space.is_whitespace());
    }

    #[test]
    fn test_case_conversion() {
        assert_eq!(Char::from('a').to_upper(), Char::from('A'));
        assert_eq!(Char::from('A').to_lower(), Char::from('a'));
        assert_eq!(Char::from('1').to_upper(), Char::from('1'));
    }

    #[test]
    fn test_successor_predecessor() {
        assert_eq!(Char::from('a').successor(), Char::from('b'));
        assert_eq!(Char::from('b').predecessor(), Char::from('a'));
    }

    #[test]
    fn test_to_string() {
        assert_eq!(Char::from('A').to_string(), "A");
        assert_eq!(Char::from('中').to_string(), "中");
    }
}
