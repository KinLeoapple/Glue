//! 标量类型标签与辅助类型
//!
//! 定义 18 种标量类型的标签枚举 `ScalarTag`，以及 Rust 缺失的
//! `F16`（IEEE 754 binary16）和 `F128`（IEEE 754 binary128）类型。
//! 对应 Zig 实现中的 `scalar.zig`。

// =========================================================================
// F16 — IEEE 754 半精度浮点（binary16）
// =========================================================================

/// IEEE 754 半精度浮点数：以 `u16` 存储 bit pattern
///
/// Rust 标准库无原生 `f16`，此处用 newtype 包装 bit 表示。
/// 提供与 `f32` 的双向转换（遵循 IEEE 754 round-to-nearest）。
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct F16(pub u16);

impl F16 {
    /// 从 `f32` 转换（round-to-nearest，溢出 → Inf）
    pub fn from_f32(x: f32) -> Self {
        F16(f32_to_f16_bits(x))
    }

    /// 转换为 `f32`
    pub fn to_f32(self) -> f32 {
        f16_bits_to_f32(self.0)
    }

    /// 从 `f64` 转换
    pub fn from_f64(x: f64) -> Self {
        Self::from_f32(x as f32)
    }

    /// 转换为 `f64`
    pub fn to_f64(self) -> f64 {
        self.to_f32() as f64
    }

    /// 是否为 NaN
    pub fn is_nan(self) -> bool {
        let exp = (self.0 >> 10) & 0x1F;
        let mant = self.0 & 0x3FF;
        exp == 0x1F && mant != 0
    }

    /// 是否为无穷
    pub fn is_infinite(self) -> bool {
        let exp = (self.0 >> 10) & 0x1F;
        let mant = self.0 & 0x3FF;
        exp == 0x1F && mant == 0
    }

    /// 获取 bit pattern
    pub fn to_bits(self) -> u16 {
        self.0
    }

    /// 从 bit pattern 构造
    pub fn from_bits(b: u16) -> Self {
        F16(b)
    }
}

impl std::fmt::Debug for F16 {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        if self.is_nan() {
            write!(f, "NaN(f16)")
        } else if self.is_infinite() {
            if self.0 >> 15 != 0 {
                write!(f, "-inf(f16)")
            } else {
                write!(f, "inf(f16)")
            }
        } else {
            write!(f, "{}f16", self.to_f32())
        }
    }
}

impl std::fmt::Display for F16 {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        std::fmt::Debug::fmt(self, f)
    }
}

/// f32 bit pattern → f16 bit pattern（IEEE 754 round-to-nearest）
fn f32_to_f16_bits(x: f32) -> u16 {
    let bits = x.to_bits();
    let sign = ((bits >> 16) & 0x8000) as u16;
    let exp = ((bits >> 23) & 0xFF) as i32;
    let mant = bits & 0x7FFFFF;

    if exp == 0xFF {
        // NaN 或 Inf
        let m = if mant != 0 { 0x200 } else { 0 };
        return sign | 0x7C00 | (m as u16);
    }

    let new_exp = exp - 127 + 15;
    if new_exp >= 0x1F {
        // 溢出 → Inf
        return sign | 0x7C00;
    }

    if new_exp <= 0 {
        if 14 - new_exp >= 24 {
            // 太小，rounds to zero
            return sign;
        }
        // 非规格化数
        let m = mant | 0x800000;
        let shift = 14 - new_exp;
        let rounded_m = m >> shift;
        // round-to-nearest-even
        let rem = m & ((1 << shift) - 1);
        let half = 1 << (shift - 1);
        let mut result = rounded_m;
        if rem > half || (rem == half && (rounded_m & 1) != 0) {
            result += 1;
        }
        return sign | (result as u16);
    }

    // 规格化数
    let m = mant >> 13;
    let rem = mant & 0x1FFF;
    let half = 0x1000;
    let mut result: u32 = ((new_exp as u32) << 10) | (m as u32);
    if rem > half || (rem == half && (m & 1) != 0) {
        result += 1;
    }
    sign | (result as u16)
}

/// f16 bit pattern → f32 bit pattern
fn f16_bits_to_f32(bits: u16) -> f32 {
    let sign = ((bits as u32) & 0x8000) << 16;
    let exp = ((bits as u32) >> 10) & 0x1F;
    let mant = (bits as u32) & 0x3FF;

    if exp == 0 {
        if mant == 0 {
            // ±0
            return f32::from_bits(sign);
        }
        // 非规格化 → 规格化
        let mut e: i32 = -1;
        let mut m = mant;
        while (m & 0x400) == 0 {
            m <<= 1;
            e -= 1;
        }
        m &= 0x3FF;
        let new_exp = (127 + e - 14) as u32;
        return f32::from_bits(sign | (new_exp << 23) | (m << 13));
    }

    if exp == 0x1F {
        // NaN 或 Inf
        let m = if mant != 0 { (mant << 13) | 0x400000 } else { 0 };
        return f32::from_bits(sign | 0x7F800000 | m);
    }

    // 规格化
    let new_exp = exp + (127 - 15);
    f32::from_bits(sign | (new_exp << 23) | (mant << 13))
}

// =========================================================================
// F128 — IEEE 754 四倍精度浮点（binary128）
// =========================================================================

/// IEEE 754 四倍精度浮点数：以 `[u8; 16]` 存储 bit pattern
///
/// Rust 标准库无原生 `f128`，此处用 newtype 包装 bit 表示。
/// 提供与 `f64` 的双向转换（精度损失时 round-to-nearest）。
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct F128(pub [u8; 16]);

impl F128 {
    /// 从 `f64` 转换（精确，因为 f64 是 f128 的子集）
    pub fn from_f64(x: f64) -> Self {
        let bits = x.to_bits();
        let sign = ((bits >> 63) & 1) as u128;
        let exp = ((bits >> 52) & 0x7FF) as i32;
        let mant = (bits & 0xFFFFFFFFFFFFF) as u128;

        let result: u128 = if exp == 0x7FF {
            // NaN 或 Inf
            let new_exp: u128 = 0x7FFF;
            let new_mant: u128 = if mant != 0 { (mant << 60) | 0x8000000000000000 } else { 0 };
            (sign << 127) | (new_exp << 112) | new_mant
        } else if exp == 0 {
            if mant == 0 {
                // ±0
                sign << 127
            } else {
                // f64 非规格化 → f128 规格化（极少见）
                let new_exp: u128 = 0;
                (sign << 127) | (new_exp << 112) | (mant << 60)
            }
        } else {
            let new_exp = (exp - 1023 + 16383) as u128;
            (sign << 127) | (new_exp << 112) | (mant << 60)
        };

        F128(result.to_le_bytes())
    }

    /// 转换为 `f64`（可能损失精度）
    pub fn to_f64(self) -> f64 {
        let bits = u128::from_le_bytes(self.0);
        let sign = ((bits >> 127) & 1) as u64;
        let exp = ((bits >> 112) & 0x7FFF) as i32;
        let mant = (bits & 0xFFFFFFFFFFFFFFFFFFFFFFFFFF) as u128;

        if exp == 0x7FFF {
            let m: u64 = if mant != 0 {
                ((mant >> 60) as u64) | 0x8000000000000
            } else {
                0
            };
            return f64::from_bits((sign << 63) | (0x7FF << 52) | m);
        }

        if exp == 0 {
            if mant == 0 {
                return f64::from_bits(sign << 63);
            }
            // f128 非规格化 → f64 下溢为 0（简化处理）
            return f64::from_bits(sign << 63);
        }

        let new_exp = exp - 16383 + 1023;
        if new_exp >= 0x7FF {
            // 溢出 → Inf
            return f64::from_bits((sign << 63) | (0x7FF << 52));
        }
        if new_exp <= 0 {
            // f64 非规格化或下溢
            return f64::from_bits(sign << 63);
        }

        let m = (mant >> 60) as u64;
        f64::from_bits((sign << 63) | ((new_exp as u64) << 52) | m)
    }

    /// 从 `f32` 转换
    pub fn from_f32(x: f32) -> Self {
        Self::from_f64(x as f64)
    }

    /// 转换为 `f32`
    pub fn to_f32(self) -> f32 {
        self.to_f64() as f32
    }

    /// 是否为 NaN
    pub fn is_nan(self) -> bool {
        let bits = u128::from_le_bytes(self.0);
        let exp = (bits >> 112) & 0x7FFF;
        let mant = bits & 0xFFFFFFFFFFFFFFFFFFFFFFFFFF;
        exp == 0x7FFF && mant != 0
    }

    /// 是否为无穷
    pub fn is_infinite(self) -> bool {
        let bits = u128::from_le_bytes(self.0);
        let exp = (bits >> 112) & 0x7FFF;
        let mant = bits & 0xFFFFFFFFFFFFFFFFFFFFFFFFFF;
        exp == 0x7FFF && mant == 0
    }

    /// 获取 bit pattern
    pub fn to_bits(self) -> [u8; 16] {
        self.0
    }

    /// 从 bit pattern 构造
    pub fn from_bits(b: [u8; 16]) -> Self {
        F128(b)
    }
}

impl std::fmt::Debug for F128 {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        if self.is_nan() {
            write!(f, "NaN(f128)")
        } else if self.is_infinite() {
            let bits = u128::from_le_bytes(self.0);
            if bits >> 127 != 0 {
                write!(f, "-inf(f128)")
            } else {
                write!(f, "inf(f128)")
            }
        } else {
            write!(f, "{}f128", self.to_f64())
        }
    }
}

impl std::fmt::Display for F128 {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        std::fmt::Debug::fmt(self, f)
    }
}

// =========================================================================
// ScalarTag — 18 种标量类型标签
// =========================================================================

/// 标量类型标签：涵盖布尔、字符、整数与浮点共 18 种
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ScalarTag {
    Bool,
    Char,
    I8,
    I16,
    I32,
    I64,
    I128,
    U8,
    U16,
    U32,
    U64,
    U128,
    Isize,
    Usize,
    F16,
    F32,
    F64,
    F128,
}

impl ScalarTag {
    /// 字节宽度
    pub fn byte_width(self) -> usize {
        match self {
            ScalarTag::Bool | ScalarTag::I8 | ScalarTag::U8 => 1,
            ScalarTag::I16 | ScalarTag::U16 | ScalarTag::F16 => 2,
            ScalarTag::Char | ScalarTag::I32 | ScalarTag::U32 | ScalarTag::F32 => 4,
            ScalarTag::I64 | ScalarTag::U64 | ScalarTag::Isize | ScalarTag::Usize | ScalarTag::F64 => 8,
            ScalarTag::I128 | ScalarTag::U128 | ScalarTag::F128 => 16,
        }
    }

    /// 是否为整数类型（不含 bool/char）
    pub fn is_int(self) -> bool {
        matches!(
            self,
            ScalarTag::I8
                | ScalarTag::I16
                | ScalarTag::I32
                | ScalarTag::I64
                | ScalarTag::I128
                | ScalarTag::U8
                | ScalarTag::U16
                | ScalarTag::U32
                | ScalarTag::U64
                | ScalarTag::U128
                | ScalarTag::Isize
                | ScalarTag::Usize
        )
    }

    /// 是否为浮点类型
    pub fn is_float(self) -> bool {
        matches!(self, ScalarTag::F16 | ScalarTag::F32 | ScalarTag::F64 | ScalarTag::F128)
    }

    /// 是否为有符号整数
    pub fn is_signed(self) -> bool {
        matches!(
            self,
            ScalarTag::I8 | ScalarTag::I16 | ScalarTag::I32 | ScalarTag::I64 | ScalarTag::I128 | ScalarTag::Isize
        )
    }

    /// 是否为布尔
    pub fn is_bool(self) -> bool {
        matches!(self, ScalarTag::Bool)
    }

    /// 是否为字符
    pub fn is_char(self) -> bool {
        matches!(self, ScalarTag::Char)
    }

    /// 是否为数值（整数或浮点，不含 bool/char）
    pub fn is_numeric(self) -> bool {
        self.is_int() || self.is_float()
    }

    /// 规范名称
    pub fn name(self) -> &'static str {
        match self {
            ScalarTag::Bool => "bool",
            ScalarTag::Char => "char",
            ScalarTag::I8 => "i8",
            ScalarTag::I16 => "i16",
            ScalarTag::I32 => "i32",
            ScalarTag::I64 => "i64",
            ScalarTag::I128 => "i128",
            ScalarTag::U8 => "u8",
            ScalarTag::U16 => "u16",
            ScalarTag::U32 => "u32",
            ScalarTag::U64 => "u64",
            ScalarTag::U128 => "u128",
            ScalarTag::Isize => "isize",
            ScalarTag::Usize => "usize",
            ScalarTag::F16 => "f16",
            ScalarTag::F32 => "f32",
            ScalarTag::F64 => "f64",
            ScalarTag::F128 => "f128",
        }
    }

    /// 所有标签（按定义顺序）
    pub fn all() -> &'static [ScalarTag] {
        &[
            ScalarTag::Bool,
            ScalarTag::Char,
            ScalarTag::I8,
            ScalarTag::I16,
            ScalarTag::I32,
            ScalarTag::I64,
            ScalarTag::I128,
            ScalarTag::U8,
            ScalarTag::U16,
            ScalarTag::U32,
            ScalarTag::U64,
            ScalarTag::U128,
            ScalarTag::Isize,
            ScalarTag::Usize,
            ScalarTag::F16,
            ScalarTag::F32,
            ScalarTag::F64,
            ScalarTag::F128,
        ]
    }

    /// 从名称反查
    pub fn from_name(name: &str) -> Option<ScalarTag> {
        for tag in Self::all() {
            if tag.name() == name {
                return Some(*tag);
            }
        }
        None
    }
}

// =========================================================================
// 测试
// =========================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_scalar_tag_count() {
        assert_eq!(ScalarTag::all().len(), 18);
    }

    #[test]
    fn test_byte_width() {
        assert_eq!(ScalarTag::Bool.byte_width(), 1);
        assert_eq!(ScalarTag::Char.byte_width(), 4);
        assert_eq!(ScalarTag::I8.byte_width(), 1);
        assert_eq!(ScalarTag::I64.byte_width(), 8);
        assert_eq!(ScalarTag::I128.byte_width(), 16);
        assert_eq!(ScalarTag::F16.byte_width(), 2);
        assert_eq!(ScalarTag::F128.byte_width(), 16);
    }

    #[test]
    fn test_predicates() {
        assert!(ScalarTag::I32.is_int());
        assert!(!ScalarTag::Bool.is_int());
        assert!(ScalarTag::F64.is_float());
        assert!(ScalarTag::I32.is_signed());
        assert!(!ScalarTag::U32.is_signed());
        assert!(ScalarTag::Isize.is_signed());
    }

    #[test]
    fn test_name_roundtrip() {
        for tag in ScalarTag::all() {
            let name = tag.name();
            assert_eq!(ScalarTag::from_name(name), Some(*tag));
        }
        assert_eq!(ScalarTag::from_name("not_a_type"), None);
    }

    #[test]
    fn test_f16_basic() {
        let z = F16::from_f32(0.0);
        assert_eq!(z.to_f32(), 0.0);
        let one = F16::from_f32(1.0);
        assert_eq!(one.to_f32(), 1.0);
        let inf = F16::from_f32(f32::INFINITY);
        assert!(inf.is_infinite());
        let nan = F16::from_f32(f32::NAN);
        assert!(nan.is_nan());
    }

    #[test]
    fn test_f128_basic() {
        let z = F128::from_f64(0.0);
        assert_eq!(z.to_f64(), 0.0);
        let one = F128::from_f64(1.0);
        assert_eq!(one.to_f64(), 1.0);
        let inf = F128::from_f64(f64::INFINITY);
        assert!(inf.is_infinite());
        let nan = F128::from_f64(f64::NAN);
        assert!(nan.is_nan());
    }
}
