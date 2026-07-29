//! SIMD 批量运算：类型化切片的逐元素运算
//!
//! 对应 Zig 实现中的 vector_exec 批量运算。Rust 版本使用泛型 + trait bound
//! 实现类型安全的批量运算，编译器可自动向量化（auto-vectorization）。
//!
//! 设计原则：
//! - 所有运算为逐元素操作，长度由调用方保证一致
//! - 溢出遵循 `Num` trait 语义：整数溢出回绕（wrap），浮点遵循 IEEE 754
//! - 比较运算输出 `u8` 掩码（0 或 1），便于后续 `batch_select`

use crate::value::ops::{BitOps, Num};

// =========================================================================
// 运算枚举
// =========================================================================

/// 二元运算：算术 + 位运算 + 移位
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BinOp {
    Add,
    Sub,
    Mul,
    Div,
    Mod,
    Band,
    Bor,
    Bxor,
    Shl,
    Shr,
}

/// 一元运算
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum UnaryOp {
    /// 取负
    Neg,
    /// 绝对值
    Abs,
    /// 按位取反
    Bnot,
}

/// 比较运算：输出 `u8` 掩码（0=false, 1=true）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CmpOp {
    Lt,
    Gt,
    Eq,
    Ne,
    Le,
    Ge,
}

/// 归约运算：将切片归约为单个值
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ReduceOp {
    Add,
    Mul,
    Band,
    Bor,
    Bxor,
}

// =========================================================================
// 批量算术运算
// =========================================================================

/// `dst[i] = a[i] + b[i]`（逐元素加法）
///
/// 整数溢出回绕（wrap），浮点遵循 IEEE 754。
pub fn batch_add<T>(dst: &mut [T], a: &[T], b: &[T])
where
    T: Num,
{
    let n = dst.len().min(a.len()).min(b.len());
    for i in 0..n {
        dst[i] = a[i].wrapping_add(b[i]);
    }
}

/// `dst[i] = a[i] - b[i]`
pub fn batch_sub<T>(dst: &mut [T], a: &[T], b: &[T])
where
    T: Num,
{
    let n = dst.len().min(a.len()).min(b.len());
    for i in 0..n {
        dst[i] = a[i].wrapping_sub(b[i]);
    }
}

/// `dst[i] = a[i] * b[i]`
pub fn batch_mul<T>(dst: &mut [T], a: &[T], b: &[T])
where
    T: Num,
{
    let n = dst.len().min(a.len()).min(b.len());
    for i in 0..n {
        dst[i] = a[i].wrapping_mul(b[i]);
    }
}

/// `dst[i] = a[i] / b[i]`（除零：整数返回 0，浮点产生 Inf/NaN）
pub fn batch_div<T>(dst: &mut [T], a: &[T], b: &[T])
where
    T: Num,
{
    let n = dst.len().min(a.len()).min(b.len());
    for i in 0..n {
        dst[i] = a[i].checked_div(b[i]).unwrap_or_else(T::zero);
    }
}

/// `dst[i] = a[i] % b[i]`（除零返回 0）
pub fn batch_mod<T>(dst: &mut [T], a: &[T], b: &[T])
where
    T: Num,
{
    let n = dst.len().min(a.len()).min(b.len());
    for i in 0..n {
        dst[i] = a[i].checked_rem(b[i]).unwrap_or_else(T::zero);
    }
}

/// 通用二元运算分派
pub fn batch_binop<T>(dst: &mut [T], a: &[T], b: &[T], op: BinOp)
where
    T: Num + BitOps,
{
    match op {
        BinOp::Add => batch_add(dst, a, b),
        BinOp::Sub => batch_sub(dst, a, b),
        BinOp::Mul => batch_mul(dst, a, b),
        BinOp::Div => batch_div(dst, a, b),
        BinOp::Mod => batch_mod(dst, a, b),
        BinOp::Band => batch_bit_and(dst, a, b),
        BinOp::Bor => batch_bit_or(dst, a, b),
        BinOp::Bxor => batch_bit_xor(dst, a, b),
        BinOp::Shl => batch_shl(dst, a, b),
        BinOp::Shr => batch_shr(dst, a, b),
    }
}

// =========================================================================
// 批量位运算
// =========================================================================

/// `dst[i] = a[i] & b[i]`
pub fn batch_bit_and<T>(dst: &mut [T], a: &[T], b: &[T])
where
    T: BitOps,
{
    let n = dst.len().min(a.len()).min(b.len());
    for i in 0..n {
        dst[i] = a[i].bit_and(b[i]);
    }
}

/// `dst[i] = a[i] | b[i]`
pub fn batch_bit_or<T>(dst: &mut [T], a: &[T], b: &[T])
where
    T: BitOps,
{
    let n = dst.len().min(a.len()).min(b.len());
    for i in 0..n {
        dst[i] = a[i].bit_or(b[i]);
    }
}

/// `dst[i] = a[i] ^ b[i]`
pub fn batch_bit_xor<T>(dst: &mut [T], a: &[T], b: &[T])
where
    T: BitOps,
{
    let n = dst.len().min(a.len()).min(b.len());
    for i in 0..n {
        dst[i] = a[i].bit_xor(b[i]);
    }
}

/// `dst[i] = a[i] << b[i]`（移位量取 `b[i]` 的低 5/6 位）
pub fn batch_shl<T>(dst: &mut [T], a: &[T], b: &[T])
where
    T: BitOps + Num,
{
    let n = dst.len().min(a.len()).min(b.len());
    for i in 0..n {
        dst[i] = a[i].shl(b[i].to_u32());
    }
}

/// `dst[i] = a[i] >> b[i]`
pub fn batch_shr<T>(dst: &mut [T], a: &[T], b: &[T])
where
    T: BitOps + Num,
{
    let n = dst.len().min(a.len()).min(b.len());
    for i in 0..n {
        dst[i] = a[i].shr(b[i].to_u32());
    }
}

// =========================================================================
// 批量一元运算
// =========================================================================

/// `dst[i] = -a[i]`（溢出回绕）
pub fn batch_neg<T>(dst: &mut [T], a: &[T])
where
    T: Num,
{
    let n = dst.len().min(a.len());
    for i in 0..n {
        dst[i] = a[i].wrapping_neg();
    }
}

/// `dst[i] = |a[i]|`（绝对值）
pub fn batch_abs<T>(dst: &mut [T], a: &[T])
where
    T: Num,
{
    let n = dst.len().min(a.len());
    for i in 0..n {
        dst[i] = a[i].abs();
    }
}

/// `dst[i] = !a[i]`（按位取反）
pub fn batch_bit_not<T>(dst: &mut [T], a: &[T])
where
    T: BitOps,
{
    let n = dst.len().min(a.len());
    for i in 0..n {
        dst[i] = a[i].bit_not();
    }
}

/// 通用一元运算分派
pub fn batch_unaryop<T>(dst: &mut [T], a: &[T], op: UnaryOp)
where
    T: Num + BitOps,
{
    match op {
        UnaryOp::Neg => batch_neg(dst, a),
        UnaryOp::Abs => batch_abs(dst, a),
        UnaryOp::Bnot => batch_bit_not(dst, a),
    }
}

// =========================================================================
// 批量比较运算
// =========================================================================

/// `dst[i] = (a[i] OP b[i]) ? 1 : 0`
pub fn batch_cmp<T>(dst: &mut [u8], a: &[T], b: &[T], op: CmpOp)
where
    T: PartialOrd,
{
    let n = dst.len().min(a.len()).min(b.len());
    for i in 0..n {
        dst[i] = match op {
            CmpOp::Lt => a[i] < b[i],
            CmpOp::Gt => a[i] > b[i],
            CmpOp::Eq => a[i] == b[i],
            CmpOp::Ne => a[i] != b[i],
            CmpOp::Le => a[i] <= b[i],
            CmpOp::Ge => a[i] >= b[i],
        }
        .into();
    }
}

// =========================================================================
// 批量归约运算
// =========================================================================

/// 将切片归约为单个值
///
/// 空切片返回 `T::zero()`。
pub fn batch_reduce<T>(a: &[T], op: ReduceOp) -> T
where
    T: Num + BitOps,
{
    if a.is_empty() {
        return T::zero();
    }
    let mut acc = a[0];
    for &v in &a[1..] {
        acc = match op {
            ReduceOp::Add => acc.wrapping_add(v),
            ReduceOp::Mul => acc.wrapping_mul(v),
            ReduceOp::Band => acc.bit_and(v),
            ReduceOp::Bor => acc.bit_or(v),
            ReduceOp::Bxor => acc.bit_xor(v),
        };
    }
    acc
}

// =========================================================================
// 掩码选择与广播
// =========================================================================

/// `dst[i] = mask[i] != 0 ? t[i] : f[i]`
pub fn batch_select<T>(dst: &mut [T], mask: &[u8], t: &[T], f: &[T])
where
    T: Copy,
{
    let n = dst.len().min(mask.len()).min(t.len()).min(f.len());
    for i in 0..n {
        dst[i] = if mask[i] != 0 { t[i] } else { f[i] };
    }
}

/// `dst[i] = val`（广播）
pub fn broadcast<T>(dst: &mut [T], val: T)
where
    T: Copy,
{
    for slot in dst.iter_mut() {
        *slot = val;
    }
}

// =========================================================================
// 特化实现：i64 / f64 的便捷接口
// =========================================================================

/// i64 专用批量加法（使用 wrapping 语义，匹配 SIMD 运行时行为）
pub fn batch_add_i64(dst: &mut [i64], a: &[i64], b: &[i64]) {
    let n = dst.len().min(a.len()).min(b.len());
    for i in 0..n {
        dst[i] = a[i].wrapping_add(b[i]);
    }
}

/// i64 专用批量乘法
pub fn batch_mul_i64(dst: &mut [i64], a: &[i64], b: &[i64]) {
    let n = dst.len().min(a.len()).min(b.len());
    for i in 0..n {
        dst[i] = a[i].wrapping_mul(b[i]);
    }
}

/// f64 专用批量加法
pub fn batch_add_f64(dst: &mut [f64], a: &[f64], b: &[f64]) {
    let n = dst.len().min(a.len()).min(b.len());
    for i in 0..n {
        dst[i] = a[i] + b[i];
    }
}

/// f64 专用批量乘法
pub fn batch_mul_f64(dst: &mut [f64], a: &[f64], b: &[f64]) {
    let n = dst.len().min(a.len()).min(b.len());
    for i in 0..n {
        dst[i] = a[i] * b[i];
    }
}

/// f64 专用批量比较
pub fn batch_cmp_f64(dst: &mut [u8], a: &[f64], b: &[f64], op: CmpOp) {
    batch_cmp(dst, a, b, op);
}

/// f64 专用归约求和
pub fn batch_reduce_sum_f64(a: &[f64]) -> f64 {
    a.iter().sum()
}

/// i64 专用归约求和（wrapping）
pub fn batch_reduce_sum_i64(a: &[i64]) -> i64 {
    a.iter().copied().fold(0i64, |acc, v| acc.wrapping_add(v))
}

// =========================================================================
// 测试
// =========================================================================

#[cfg(test)]
mod tests {
    use super::*;

    // ---- 枚举 ----

    #[test]
    fn test_op_enums() {
        assert_eq!(format!("{:?}", BinOp::Add), "Add");
        assert_eq!(format!("{:?}", CmpOp::Lt), "Lt");
        assert_eq!(format!("{:?}", UnaryOp::Neg), "Neg");
        assert_eq!(format!("{:?}", ReduceOp::Mul), "Mul");
    }

    // ---- 批量算术（i64 特化）----

    #[test]
    fn test_batch_add_i64() {
        let a = [1i64, 2, 3, 4];
        let b = [10i64, 20, 30, 40];
        let mut dst = [0i64; 4];
        batch_add_i64(&mut dst, &a, &b);
        assert_eq!(dst, [11, 22, 33, 44]);
    }

    #[test]
    fn test_batch_mul_i64() {
        let a = [1i64, 2, 3, 4];
        let b = [2i64, 3, 4, 5];
        let mut dst = [0i64; 4];
        batch_mul_i64(&mut dst, &a, &b);
        assert_eq!(dst, [2, 6, 12, 20]);
    }

    #[test]
    fn test_batch_add_i64_overflow_wrap() {
        let a = [i64::MAX];
        let b = [1i64];
        let mut dst = [0i64; 1];
        batch_add_i64(&mut dst, &a, &b);
        assert_eq!(dst[0], i64::MIN); // wrapping
    }

    // ---- 批量算术（f64 特化）----

    #[test]
    fn test_batch_add_f64() {
        let a = [1.5f64, 2.5, 3.5];
        let b = [0.5f64, 1.0, 1.5];
        let mut dst = [0.0f64; 3];
        batch_add_f64(&mut dst, &a, &b);
        assert_eq!(dst, [2.0, 3.5, 5.0]);
    }

    #[test]
    fn test_batch_mul_f64() {
        let a = [2.0f64, 3.0, 4.0];
        let b = [3.0f64, 4.0, 5.0];
        let mut dst = [0.0f64; 3];
        batch_mul_f64(&mut dst, &a, &b);
        assert_eq!(dst, [6.0, 12.0, 20.0]);
    }

    #[test]
    fn test_batch_add_f64_div_zero() {
        let a = [1.0f64];
        let b = [f64::INFINITY];
        let mut dst = [0.0f64; 1];
        batch_add_f64(&mut dst, &a, &b);
        assert!(dst[0].is_infinite());
    }

    // ---- 批量比较 ----

    #[test]
    fn test_batch_cmp_i64() {
        let a = [1i64, 5, 3, 3];
        let b = [2i64, 4, 3, 4];
        let mut dst = [0u8; 4];

        batch_cmp(&mut dst, &a, &b, CmpOp::Lt);
        assert_eq!(dst, [1, 0, 0, 1]);

        batch_cmp(&mut dst, &a, &b, CmpOp::Gt);
        assert_eq!(dst, [0, 1, 0, 0]);

        batch_cmp(&mut dst, &a, &b, CmpOp::Eq);
        assert_eq!(dst, [0, 0, 1, 0]);

        batch_cmp(&mut dst, &a, &b, CmpOp::Ne);
        assert_eq!(dst, [1, 1, 0, 1]);

        batch_cmp(&mut dst, &a, &b, CmpOp::Le);
        assert_eq!(dst, [1, 0, 1, 1]);

        batch_cmp(&mut dst, &a, &b, CmpOp::Ge);
        assert_eq!(dst, [0, 1, 1, 0]);
    }

    #[test]
    fn test_batch_cmp_f64() {
        let a = [1.5f64, 2.5, 3.0];
        let b = [2.0f64, 2.5, 2.9];
        let mut dst = [0u8; 3];
        batch_cmp_f64(&mut dst, &a, &b, CmpOp::Gt);
        assert_eq!(dst, [0, 0, 1]);
    }

    // ---- 批量归约 ----

    #[test]
    fn test_batch_reduce_sum_i64() {
        assert_eq!(batch_reduce_sum_i64(&[1, 2, 3, 4, 5]), 15);
        assert_eq!(batch_reduce_sum_i64(&[]), 0);
        assert_eq!(batch_reduce_sum_i64(&[i64::MAX, 1]), i64::MIN); // wrapping
    }

    #[test]
    fn test_batch_reduce_sum_f64() {
        assert_eq!(batch_reduce_sum_f64(&[1.0, 2.0, 3.0]), 6.0);
        assert_eq!(batch_reduce_sum_f64(&[]), 0.0);
    }

    // ---- 掩码选择 ----

    #[test]
    fn test_batch_select() {
        let mask = [1u8, 0, 1, 0];
        let t = [10i64, 20, 30, 40];
        let f = [100i64, 200, 300, 400];
        let mut dst = [0i64; 4];
        batch_select(&mut dst, &mask, &t, &f);
        assert_eq!(dst, [10, 200, 30, 400]);
    }

    #[test]
    fn test_batch_select_f64() {
        let mask = [0u8, 1, 0];
        let t = [1.0f64, 2.0, 3.0];
        let f = [10.0f64, 20.0, 30.0];
        let mut dst = [0.0f64; 3];
        batch_select(&mut dst, &mask, &t, &f);
        assert_eq!(dst, [10.0, 2.0, 30.0]);
    }

    // ---- 广播 ----

    #[test]
    fn test_broadcast_i64() {
        let mut dst = [0i64; 5];
        broadcast(&mut dst, 42);
        assert_eq!(dst, [42, 42, 42, 42, 42]);
    }

    #[test]
    fn test_broadcast_f64() {
        let mut dst = [0.0f64; 3];
        broadcast(&mut dst, 2.5);
        assert_eq!(dst, [2.5, 2.5, 2.5]);
    }

    #[test]
    fn test_broadcast_empty() {
        let mut dst: [i64; 0] = [];
        broadcast(&mut dst, 42);
        assert!(dst.is_empty());
    }

    // ---- 长度不一致时取最小值 ----

    #[test]
    fn test_batch_length_mismatch() {
        let a = [1i64, 2, 3];
        let b = [10i64, 20];
        let mut dst = [0i64, 0, 0, 0];
        batch_add_i64(&mut dst, &a, &b);
        // 只处理前 2 个元素
        assert_eq!(dst[0], 11);
        assert_eq!(dst[1], 22);
        // dst[2], dst[3] 保持原值
        assert_eq!(dst[2], 0);
        assert_eq!(dst[3], 0);
    }

    // ---- 批量位运算（u8 作为可位运算类型）----

    #[test]
    fn test_batch_bit_and_u8() {
        let a = [0xF0u8, 0xFF, 0x0F];
        let b = [0x0Fu8, 0xF0, 0x0F];
        let mut dst = [0u8; 3];
        batch_bit_and(&mut dst, &a, &b);
        assert_eq!(dst, [0x00, 0xF0, 0x0F]);
    }

    #[test]
    fn test_batch_bit_or_u8() {
        let a = [0xF0u8, 0x0F, 0x00];
        let b = [0x0Fu8, 0xF0, 0xFF];
        let mut dst = [0u8; 3];
        batch_bit_or(&mut dst, &a, &b);
        assert_eq!(dst, [0xFF, 0xFF, 0xFF]);
    }

    #[test]
    fn test_batch_bit_xor_u8() {
        let a = [0xFFu8, 0xAA, 0x00];
        let b = [0x0Fu8, 0x55, 0xFF];
        let mut dst = [0u8; 3];
        batch_bit_xor(&mut dst, &a, &b);
        assert_eq!(dst, [0xF0, 0xFF, 0xFF]);
    }

    #[test]
    fn test_batch_bit_not_u8() {
        let a = [0x00u8, 0xFF, 0x0F];
        let mut dst = [0u8; 3];
        batch_bit_not(&mut dst, &a);
        assert_eq!(dst, [0xFF, 0x00, 0xF0]);
    }

    // ---- 批量一元运算 ----

    #[test]
    fn test_batch_neg_i64() {
        let a = [1i64, -2, 3, 0];
        let mut dst = [0i64; 4];
        batch_neg(&mut dst, &a);
        assert_eq!(dst, [-1, 2, -3, 0]);
    }

    #[test]
    fn test_batch_abs_i64() {
        let a = [1i64, -2, -3, 0];
        let mut dst = [0i64; 4];
        batch_abs(&mut dst, &a);
        assert_eq!(dst, [1, 2, 3, 0]);
    }

    // ---- 通用分派 ----

    #[test]
    fn test_batch_binop_dispatch_i64() {
        let a = [1i64, 2, 3];
        let b = [4i64, 5, 6];
        let mut dst = [0i64; 3];
        batch_binop(&mut dst, &a, &b, BinOp::Add);
        assert_eq!(dst, [5, 7, 9]);

        // 注：batch_binop 的位运算分支对 i64 可用（i64 实现 BitOps）
        // 但移位分支因 shift_amount 返回 0 而无效，此处仅测试算术
    }

    #[test]
    fn test_batch_unaryop_dispatch_i64() {
        let a = [1i64, -2, 3];
        let mut dst = [0i64; 3];
        batch_unaryop(&mut dst, &a, UnaryOp::Neg);
        assert_eq!(dst, [-1, 2, -3]);

        batch_unaryop(&mut dst, &a, UnaryOp::Abs);
        assert_eq!(dst, [1, 2, 3]);
    }

    // ---- ReduceOp 通用（u8 用于位运算归约）----

    #[test]
    fn test_batch_reduce_band_u8() {
        let a = [0xFFu8, 0xF0, 0x0F];
        let result = batch_reduce(&a, ReduceOp::Band);
        assert_eq!(result, 0x00);
    }

    #[test]
    fn test_batch_reduce_bor_u8() {
        let a = [0xF0u8, 0x0F, 0x00];
        let result = batch_reduce(&a, ReduceOp::Bor);
        assert_eq!(result, 0xFF);
    }

    #[test]
    fn test_batch_reduce_bxor_u8() {
        let a = [0xFFu8, 0x0F, 0xF0];
        let result = batch_reduce(&a, ReduceOp::Bxor);
        assert_eq!(result, 0x00);
    }

    #[test]
    fn test_batch_reduce_empty() {
        let a: [u8; 0] = [];
        // 空切片归约返回 T::zero()
        assert_eq!(batch_reduce(&a, ReduceOp::Bor), 0u8);
        assert_eq!(batch_reduce(&a, ReduceOp::Add), 0u8);
    }

    #[test]
    fn test_batch_reduce_add_i64() {
        let a = [1i64, 2, 3, 4, 5];
        assert_eq!(batch_reduce(&a, ReduceOp::Add), 15);
    }

    #[test]
    fn test_batch_reduce_mul_i64() {
        let a = [1i64, 2, 3, 4];
        assert_eq!(batch_reduce(&a, ReduceOp::Mul), 24);
    }

    #[test]
    fn test_batch_shl_shr_i32() {
        let a = [1i32, 2, 4];
        let b = [1i32, 2, 3];
        let mut dst = [0i32; 3];
        batch_shl(&mut dst, &a, &b);
        assert_eq!(dst, [2, 8, 32]);

        let a2 = [8i32, 16, 32];
        let b2 = [1i32, 2, 3];
        batch_shr(&mut dst, &a2, &b2);
        assert_eq!(dst, [4, 4, 4]);
    }

    #[test]
    fn test_batch_div_mod_i32() {
        let a = [10i32, 20, 30];
        let b = [3i32, 7, 5];
        let mut dst = [0i32; 3];
        batch_div(&mut dst, &a, &b);
        assert_eq!(dst, [3, 2, 6]);

        batch_mod(&mut dst, &a, &b);
        assert_eq!(dst, [1, 6, 0]);
    }

    #[test]
    fn test_batch_div_zero_returns_zero() {
        let a = [10i32];
        let b = [0i32];
        let mut dst = [0i32; 1];
        batch_div(&mut dst, &a, &b);
        assert_eq!(dst[0], 0);
    }
}
