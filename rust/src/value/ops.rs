//! 标量运算：算术、位运算、比较
//!
//! 对应 Zig 实现中的 comptime 运算分派。Rust 使用 trait + 泛型替代。
//! 整数用 `checked_*` 方法实现溢出检测；浮点直接运算（除零产生 Inf）。

// =========================================================================
// Num — 算术运算 trait
// =========================================================================

/// 数值运算 trait：支持溢出检测的算术运算
pub trait Num: Sized + Copy {
    /// 加法（溢出返回 None）
    fn checked_add(self, other: Self) -> Option<Self>;
    /// 减法（溢出返回 None）
    fn checked_sub(self, other: Self) -> Option<Self>;
    /// 乘法（溢出返回 None）
    fn checked_mul(self, other: Self) -> Option<Self>;
    /// 除法（除零返回 None）
    fn checked_div(self, other: Self) -> Option<Self>;
    /// 取余（除零返回 None）
    fn checked_rem(self, other: Self) -> Option<Self>;
    /// 取负（溢出返回 None）
    fn neg(self) -> Option<Self>;
    /// 零值
    fn zero() -> Self;
    /// 回绕加法（溢出回绕，匹配 SIMD 运行时行为）
    fn wrapping_add(self, other: Self) -> Self;
    /// 回绕减法
    fn wrapping_sub(self, other: Self) -> Self;
    /// 回绕乘法
    fn wrapping_mul(self, other: Self) -> Self;
    /// 回绕取负
    fn wrapping_neg(self) -> Self;
    /// 绝对值
    fn abs(self) -> Self;
    /// 转为 `u32`（用于移位量提取）
    fn to_u32(self) -> u32;
}

// ---- 整数实现 ----

macro_rules! impl_num_signed {
    ($($t:ty),*) => {
        $(
            impl Num for $t {
                fn checked_add(self, other: Self) -> Option<Self> { self.checked_add(other) }
                fn checked_sub(self, other: Self) -> Option<Self> { self.checked_sub(other) }
                fn checked_mul(self, other: Self) -> Option<Self> { self.checked_mul(other) }
                fn checked_div(self, other: Self) -> Option<Self> { self.checked_div(other) }
                fn checked_rem(self, other: Self) -> Option<Self> { self.checked_rem(other) }
                fn neg(self) -> Option<Self> { self.checked_neg() }
                fn zero() -> Self { 0 }
                fn wrapping_add(self, other: Self) -> Self { self.wrapping_add(other) }
                fn wrapping_sub(self, other: Self) -> Self { self.wrapping_sub(other) }
                fn wrapping_mul(self, other: Self) -> Self { self.wrapping_mul(other) }
                fn wrapping_neg(self) -> Self { self.wrapping_neg() }
                fn abs(self) -> Self { self.wrapping_abs() }
                fn to_u32(self) -> u32 { self as u32 }
            }
        )*
    };
}

macro_rules! impl_num_unsigned {
    ($($t:ty),*) => {
        $(
            impl Num for $t {
                fn checked_add(self, other: Self) -> Option<Self> { self.checked_add(other) }
                fn checked_sub(self, other: Self) -> Option<Self> { self.checked_sub(other) }
                fn checked_mul(self, other: Self) -> Option<Self> { self.checked_mul(other) }
                fn checked_div(self, other: Self) -> Option<Self> { self.checked_div(other) }
                fn checked_rem(self, other: Self) -> Option<Self> { self.checked_rem(other) }
                fn neg(self) -> Option<Self> { self.checked_neg() }
                fn zero() -> Self { 0 }
                fn wrapping_add(self, other: Self) -> Self { self.wrapping_add(other) }
                fn wrapping_sub(self, other: Self) -> Self { self.wrapping_sub(other) }
                fn wrapping_mul(self, other: Self) -> Self { self.wrapping_mul(other) }
                fn wrapping_neg(self) -> Self { self.wrapping_neg() }
                fn abs(self) -> Self { self } // 无符号数绝对值即自身
                fn to_u32(self) -> u32 { self as u32 }
            }
        )*
    };
}

impl_num_signed!(i8, i16, i32, i64, i128, isize);
impl_num_unsigned!(u8, u16, u32, u64, u128, usize);

// ---- 浮点实现 ----

impl Num for f32 {
    fn checked_add(self, other: Self) -> Option<Self> { Some(self + other) }
    fn checked_sub(self, other: Self) -> Option<Self> { Some(self - other) }
    fn checked_mul(self, other: Self) -> Option<Self> { Some(self * other) }
    fn checked_div(self, other: Self) -> Option<Self> { Some(self / other) }
    fn checked_rem(self, other: Self) -> Option<Self> { Some(self % other) }
    fn neg(self) -> Option<Self> { Some(-self) }
    fn zero() -> Self { 0.0 }
    fn wrapping_add(self, other: Self) -> Self { self + other }
    fn wrapping_sub(self, other: Self) -> Self { self - other }
    fn wrapping_mul(self, other: Self) -> Self { self * other }
    fn wrapping_neg(self) -> Self { -self }
    fn abs(self) -> Self { self.abs() }
    fn to_u32(self) -> u32 { self as u32 }
}

impl Num for f64 {
    fn checked_add(self, other: Self) -> Option<Self> { Some(self + other) }
    fn checked_sub(self, other: Self) -> Option<Self> { Some(self - other) }
    fn checked_mul(self, other: Self) -> Option<Self> { Some(self * other) }
    fn checked_div(self, other: Self) -> Option<Self> { Some(self / other) }
    fn checked_rem(self, other: Self) -> Option<Self> { Some(self % other) }
    fn neg(self) -> Option<Self> { Some(-self) }
    fn zero() -> Self { 0.0 }
    fn wrapping_add(self, other: Self) -> Self { self + other }
    fn wrapping_sub(self, other: Self) -> Self { self - other }
    fn wrapping_mul(self, other: Self) -> Self { self * other }
    fn wrapping_neg(self) -> Self { -self }
    fn abs(self) -> Self { self.abs() }
    fn to_u32(self) -> u32 { self as u32 }
}

// =========================================================================
// BitOps — 位运算 trait
// =========================================================================

/// 位运算 trait：与、或、异或、非、左移、右移
pub trait BitOps: Sized + Copy {
    fn bit_and(self, other: Self) -> Self;
    fn bit_or(self, other: Self) -> Self;
    fn bit_xor(self, other: Self) -> Self;
    fn bit_not(self) -> Self;
    fn shl(self, amount: u32) -> Self;
    fn shr(self, amount: u32) -> Self;
}

macro_rules! impl_bitops {
    ($($t:ty),*) => {
        $(
            impl BitOps for $t {
                fn bit_and(self, other: Self) -> Self { self & other }
                fn bit_or(self, other: Self) -> Self { self | other }
                fn bit_xor(self, other: Self) -> Self { self ^ other }
                fn bit_not(self) -> Self { !self }
                fn shl(self, amount: u32) -> Self { self << amount }
                fn shr(self, amount: u32) -> Self { self >> amount }
            }
        )*
    };
}

impl_bitops!(i8, i16, i32, i64, i128, isize, u8, u16, u32, u64, u128, usize);

// =========================================================================
// 测试
// =========================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_int_add() {
        assert_eq!(i32::checked_add(1, 2), Some(3));
        assert_eq!(i32::checked_add(i32::MAX, 1), None);
        assert_eq!(u8::checked_add(255, 1), None);
    }

    #[test]
    fn test_int_sub() {
        assert_eq!(i32::checked_sub(5, 3), Some(2));
        assert_eq!(u8::checked_sub(0, 1), None);
    }

    #[test]
    fn test_int_mul() {
        assert_eq!(i32::checked_mul(3, 4), Some(12));
        assert_eq!(i32::checked_mul(i32::MAX, 2), None);
    }

    #[test]
    fn test_int_div() {
        assert_eq!(i32::checked_div(10, 3), Some(3));
        assert_eq!(i32::checked_div(10, 0), None);
        assert_eq!(i32::checked_rem(10, 3), Some(1));
        assert_eq!(i32::checked_rem(10, 0), None);
    }

    #[test]
    fn test_int_neg() {
        assert_eq!(i32::neg(5), Some(-5));
        assert_eq!(i32::neg(i32::MIN), None);
        assert_eq!(u32::neg(5), None);
    }

    #[test]
    fn test_float_add() {
        assert_eq!(f32::checked_add(1.5, 2.5), Some(4.0));
        assert_eq!(f64::checked_div(1.0, 0.0), Some(f64::INFINITY));
    }

    #[test]
    fn test_bitops() {
        assert_eq!(u8::bit_and(0xF0, 0x0F), 0x00);
        assert_eq!(u8::bit_or(0xF0, 0x0F), 0xFF);
        assert_eq!(u8::bit_xor(0xFF, 0x0F), 0xF0);
        assert_eq!(u8::bit_not(0x00), 0xFF);
        assert_eq!(u8::shl(0x01, 4), 0x10);
        assert_eq!(u8::shr(0x80, 4), 0x08);
        assert_eq!(i32::shl(1, 31), i32::MIN);
    }
}
