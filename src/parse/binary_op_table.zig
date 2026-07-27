//! BinaryOp 优先级表（v3 阶段 15）
//!
//! 单一扁平注册表 + 数值优先级，驱动单一 Pratt 解析器。
//! 替代 13 层 parseXxx 模板函数（parseElvis/Or/And/BitOr/BitXor/BitAnd/Shift/
//! Equality/Comparison/Range/Addition/Multiplication）。
//!
//! 新增二元运算符只需在 BINARY_OPS 追加一条，无需改解析器。

const std = @import("std");
const ast = @import("ast");
const lexer = @import("lexer");

/// 单个运算符映射：token 类型 → BinaryOp + 优先级
pub const OpMapping = struct {
    token: lexer.TokenType,
    op: ast.BinaryOp,
    precedence: u8, // 数值越大越紧密
    check_multiline_deref: bool = false, // 仅 `*`（乘法 vs 解引用歧义）
};

/// 优先级常量（从低到高）
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
/// 新增运算符只需在此追加一条
pub const BINARY_OPS = [_]OpMapping{
    // Elvis ?? (最低)
    .{ .token = .question_question, .op = .elvis, .precedence = ELVIS_PREC },
    // 逻辑或 ||
    .{ .token = .pipe_pipe, .op = .or_op, .precedence = OR_PREC },
    // 逻辑与 &&
    .{ .token = .amp_amp, .op = .and_op, .precedence = AND_PREC },
    // 按位或 |
    .{ .token = .pipe, .op = .bit_or, .precedence = BIT_OR_PREC },
    // 按位异或 ^
    .{ .token = .caret, .op = .bit_xor, .precedence = BIT_XOR_PREC },
    // 按位与 &
    .{ .token = .ampersand, .op = .bit_and, .precedence = BIT_AND_PREC },
    // 移位 << >>
    .{ .token = .lt_lt, .op = .shl, .precedence = SHIFT_PREC },
    .{ .token = .gt_gt, .op = .shr, .precedence = SHIFT_PREC },
    // 相等 == != === !==
    .{ .token = .eq_eq, .op = .eq, .precedence = EQUALITY_PREC },
    .{ .token = .bang_eq, .op = .not_eq, .precedence = EQUALITY_PREC },
    .{ .token = .ref_eq, .op = .ref_eq, .precedence = EQUALITY_PREC },
    .{ .token = .ref_neq, .op = .ref_neq, .precedence = EQUALITY_PREC },
    // 比较 < > <= >=
    .{ .token = .lt, .op = .lt, .precedence = COMPARISON_PREC },
    .{ .token = .gt, .op = .gt, .precedence = COMPARISON_PREC },
    .{ .token = .lt_eq, .op = .lt_eq, .precedence = COMPARISON_PREC },
    .{ .token = .gt_eq, .op = .gt_eq, .precedence = COMPARISON_PREC },
    // 范围 .. ..=
    .{ .token = .dot_dot, .op = .range, .precedence = RANGE_PREC },
    .{ .token = .dot_dot_eq, .op = .range_inclusive, .precedence = RANGE_PREC },
    // 加减 + ++ -
    .{ .token = .plus, .op = .add, .precedence = ADDITION_PREC },
    .{ .token = .plus_plus, .op = .concat_list, .precedence = ADDITION_PREC },
    .{ .token = .minus, .op = .sub, .precedence = ADDITION_PREC },
    // 乘除模 * / %（`*` 需跨行解引用检查）
    .{ .token = .star, .op = .mul, .precedence = MULTIPLICATION_PREC, .check_multiline_deref = true },
    .{ .token = .slash, .op = .div, .precedence = MULTIPLICATION_PREC },
    .{ .token = .percent, .op = .mod, .precedence = MULTIPLICATION_PREC },
};

/// 按 token 类型查找二元运算符映射，未找到返回 null
pub fn lookupBinaryOp(tok_type: lexer.TokenType) ?*const OpMapping {
    for (&BINARY_OPS) |*m| {
        if (m.token == tok_type) return m;
    }
    return null;
}

test "binary_op_table: BINARY_OPS 覆盖所有二元运算符" {
    try std.testing.expect(BINARY_OPS.len >= 23);
    try std.testing.expect(lookupBinaryOp(.question_question).?.op == .elvis);
    try std.testing.expect(lookupBinaryOp(.pipe_pipe).?.op == .or_op);
    try std.testing.expect(lookupBinaryOp(.star).?.precedence == MULTIPLICATION_PREC);
    try std.testing.expect(lookupBinaryOp(.star).?.check_multiline_deref);
    try std.testing.expect(lookupBinaryOp(.plus) != null);
    try std.testing.expect(lookupBinaryOp(.semicolon) == null);
}

test "binary_op_table: 优先级从低到高递增" {
    try std.testing.expect(ELVIS_PREC < OR_PREC);
    try std.testing.expect(OR_PREC < AND_PREC);
    try std.testing.expect(ADDITION_PREC < MULTIPLICATION_PREC);
}
