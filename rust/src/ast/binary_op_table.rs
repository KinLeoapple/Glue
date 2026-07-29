//! BinaryOp 优先级表
//!
//! 单一扁平注册表 + 数值优先级，驱动单一 Pratt 解析器。
//! 替代 13 层 parseXxx 模板函数（parseElvis/Or/And/BitOr/BitXor/BitAnd/Shift/
//! Equality/Comparison/Range/Addition/Multiplication）。
//!
//! 新增二元运算符只需在 BINARY_OPS 追加一条，无需改解析器。

use crate::ast::lexer::TokenKind;
use crate::ast::op::BinaryOp;

/// 单个运算符映射：token 类型 → BinaryOp + 优先级
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OpMapping {
    pub token: TokenKind,
    pub op: BinaryOp,
    /// 数值越大越紧密
    pub precedence: u8,
    /// 仅 `*`（乘法 vs 解引用歧义）需跨行检查
    pub check_multiline_deref: bool,
    /// 右结合（如 `??` elvis 运算符）
    pub right_assoc: bool,
}

// 优先级常量（从低到高）
pub const ELVIS_PREC: u8 = 1;
pub const OR_PREC: u8 = 2;
pub const AND_PREC: u8 = 3;
pub const BIT_OR_PREC: u8 = 4;
pub const BIT_XOR_PREC: u8 = 5;
pub const BIT_AND_PREC: u8 = 6;
pub const SHIFT_PREC: u8 = 7;
pub const EQUALITY_PREC: u8 = 8;
pub const COMPARISON_PREC: u8 = 9;
pub const RANGE_PREC: u8 = 10;
pub const ADDITION_PREC: u8 = 11;
pub const MULTIPLICATION_PREC: u8 = 12;

/// 最低优先级（Pratt 解析器入口）
pub const MIN_PREC: u8 = ELVIS_PREC;

/// 扁平二元运算符注册表（单一真相来源）
///
/// 新增运算符只需在此追加一条。
pub const BINARY_OPS: &[OpMapping] = &[
    // Elvis ?? (最低，右结合)
    OpMapping {
        token: TokenKind::QuestionQuestion,
        op: BinaryOp::Elvis,
        precedence: ELVIS_PREC,
        check_multiline_deref: false,
        right_assoc: true,
    },
    // 逻辑或 ||
    OpMapping {
        token: TokenKind::PipePipe,
        op: BinaryOp::Or,
        precedence: OR_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    // 逻辑与 &&
    OpMapping {
        token: TokenKind::AmpAmp,
        op: BinaryOp::And,
        precedence: AND_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    // 按位或 |
    OpMapping {
        token: TokenKind::Pipe,
        op: BinaryOp::BitOr,
        precedence: BIT_OR_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    // 按位异或 ^
    OpMapping {
        token: TokenKind::Caret,
        op: BinaryOp::BitXor,
        precedence: BIT_XOR_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    // 按位与 &
    OpMapping {
        token: TokenKind::Ampersand,
        op: BinaryOp::BitAnd,
        precedence: BIT_AND_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    // 移位 << >>
    OpMapping {
        token: TokenKind::LtLt,
        op: BinaryOp::Shl,
        precedence: SHIFT_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    OpMapping {
        token: TokenKind::GtGt,
        op: BinaryOp::Shr,
        precedence: SHIFT_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    // 相等 == != === !==
    OpMapping {
        token: TokenKind::EqEq,
        op: BinaryOp::Eq,
        precedence: EQUALITY_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    OpMapping {
        token: TokenKind::BangEq,
        op: BinaryOp::NotEq,
        precedence: EQUALITY_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    OpMapping {
        token: TokenKind::RefEq,
        op: BinaryOp::RefEq,
        precedence: EQUALITY_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    OpMapping {
        token: TokenKind::RefNeq,
        op: BinaryOp::RefNeq,
        precedence: EQUALITY_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    // 比较 < > <= >=
    OpMapping {
        token: TokenKind::Lt,
        op: BinaryOp::Lt,
        precedence: COMPARISON_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    OpMapping {
        token: TokenKind::Gt,
        op: BinaryOp::Gt,
        precedence: COMPARISON_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    OpMapping {
        token: TokenKind::LtEq,
        op: BinaryOp::LtEq,
        precedence: COMPARISON_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    OpMapping {
        token: TokenKind::GtEq,
        op: BinaryOp::GtEq,
        precedence: COMPARISON_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    // 范围 .. ..=
    OpMapping {
        token: TokenKind::DotDot,
        op: BinaryOp::Range,
        precedence: RANGE_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    OpMapping {
        token: TokenKind::DotDotEq,
        op: BinaryOp::RangeInclusive,
        precedence: RANGE_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    // 加减 + ++ -
    OpMapping {
        token: TokenKind::Plus,
        op: BinaryOp::Add,
        precedence: ADDITION_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    OpMapping {
        token: TokenKind::PlusPlus,
        op: BinaryOp::ConcatList,
        precedence: ADDITION_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    OpMapping {
        token: TokenKind::Minus,
        op: BinaryOp::Sub,
        precedence: ADDITION_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    // 乘除模 * / %（`*` 需跨行解引用检查）
    OpMapping {
        token: TokenKind::Star,
        op: BinaryOp::Mul,
        precedence: MULTIPLICATION_PREC,
        check_multiline_deref: true,
        right_assoc: false,
    },
    OpMapping {
        token: TokenKind::Slash,
        op: BinaryOp::Div,
        precedence: MULTIPLICATION_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    OpMapping {
        token: TokenKind::Percent,
        op: BinaryOp::Mod,
        precedence: MULTIPLICATION_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
];

/// 按 token 类型查找二元运算符映射，未找到返回 None
pub fn lookup_binary_op(tok: TokenKind) -> Option<&'static OpMapping> {
    BINARY_OPS.iter().find(|m| m.token == tok)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_lookup_all_operators() {
        // 全部 22 个二元运算符都可查到
        assert!(lookup_binary_op(TokenKind::QuestionQuestion).is_some());
        assert!(lookup_binary_op(TokenKind::PipePipe).is_some());
        assert!(lookup_binary_op(TokenKind::AmpAmp).is_some());
        assert!(lookup_binary_op(TokenKind::Pipe).is_some());
        assert!(lookup_binary_op(TokenKind::Caret).is_some());
        assert!(lookup_binary_op(TokenKind::Ampersand).is_some());
        assert!(lookup_binary_op(TokenKind::LtLt).is_some());
        assert!(lookup_binary_op(TokenKind::GtGt).is_some());
        assert!(lookup_binary_op(TokenKind::EqEq).is_some());
        assert!(lookup_binary_op(TokenKind::BangEq).is_some());
        assert!(lookup_binary_op(TokenKind::RefEq).is_some());
        assert!(lookup_binary_op(TokenKind::RefNeq).is_some());
        assert!(lookup_binary_op(TokenKind::Lt).is_some());
        assert!(lookup_binary_op(TokenKind::Gt).is_some());
        assert!(lookup_binary_op(TokenKind::LtEq).is_some());
        assert!(lookup_binary_op(TokenKind::GtEq).is_some());
        assert!(lookup_binary_op(TokenKind::DotDot).is_some());
        assert!(lookup_binary_op(TokenKind::DotDotEq).is_some());
        assert!(lookup_binary_op(TokenKind::Plus).is_some());
        assert!(lookup_binary_op(TokenKind::PlusPlus).is_some());
        assert!(lookup_binary_op(TokenKind::Minus).is_some());
        assert!(lookup_binary_op(TokenKind::Star).is_some());
        assert!(lookup_binary_op(TokenKind::Slash).is_some());
        assert!(lookup_binary_op(TokenKind::Percent).is_some());
    }

    #[test]
    fn test_lookup_non_operator_returns_none() {
        assert!(lookup_binary_op(TokenKind::Identifier).is_none());
        assert!(lookup_binary_op(TokenKind::IntLiteral).is_none());
        assert!(lookup_binary_op(TokenKind::LParen).is_none());
        assert!(lookup_binary_op(TokenKind::Eof).is_none());
        assert!(lookup_binary_op(TokenKind::Eq).is_none()); // 赋值不是二元运算符
        assert!(lookup_binary_op(TokenKind::PlusEq).is_none()); // 复合赋值不是二元运算符
    }

    #[test]
    fn test_elvis_is_right_assoc() {
        let m = lookup_binary_op(TokenKind::QuestionQuestion).unwrap();
        assert!(m.right_assoc);
        assert_eq!(m.precedence, ELVIS_PREC);
        assert_eq!(m.op, BinaryOp::Elvis);
    }

    #[test]
    fn test_star_needs_multiline_deref_check() {
        let m = lookup_binary_op(TokenKind::Star).unwrap();
        assert!(m.check_multiline_deref);
        assert_eq!(m.precedence, MULTIPLICATION_PREC);
        assert_eq!(m.op, BinaryOp::Mul);
    }

    #[test]
    fn test_other_ops_not_multiline() {
        // 除 `*` 外其他运算符都不需要跨行检查
        for m in BINARY_OPS {
            if m.token == TokenKind::Star {
                continue;
            }
            assert!(!m.check_multiline_deref, "token {:?} should not check multiline", m.token);
        }
    }

    #[test]
    fn test_only_elvis_is_right_assoc() {
        // 除 `??` 外其他运算符都是左结合
        for m in BINARY_OPS {
            if m.token == TokenKind::QuestionQuestion {
                assert!(m.right_assoc);
            } else {
                assert!(!m.right_assoc, "token {:?} should be left-assoc", m.token);
            }
        }
    }

    #[test]
    fn test_precedence_ordering() {
        // 验证优先级顺序：elvis < or < and < bit_or < bit_xor < bit_and
        // < shift < equality < comparison < range < addition < multiplication
        assert!(ELVIS_PREC < OR_PREC);
        assert!(OR_PREC < AND_PREC);
        assert!(AND_PREC < BIT_OR_PREC);
        assert!(BIT_OR_PREC < BIT_XOR_PREC);
        assert!(BIT_XOR_PREC < BIT_AND_PREC);
        assert!(BIT_AND_PREC < SHIFT_PREC);
        assert!(SHIFT_PREC < EQUALITY_PREC);
        assert!(EQUALITY_PREC < COMPARISON_PREC);
        assert!(COMPARISON_PREC < RANGE_PREC);
        assert!(RANGE_PREC < ADDITION_PREC);
        assert!(ADDITION_PREC < MULTIPLICATION_PREC);
    }

    #[test]
    fn test_binary_ops_count() {
        // 共 24 条映射（22 种运算符，其中 Range/RangeInclusive 各 1，Add/ConcatList/Sub 各 1，Mul/Div/Mod 各 1）
        // 实际：1(elvis) + 1(or) + 1(and) + 1(bor) + 1(bxor) + 1(band)
        //     + 2(shift) + 4(equality) + 4(comparison) + 2(range) + 3(addition) + 3(mul) = 24
        assert_eq!(BINARY_OPS.len(), 24);
    }
}
