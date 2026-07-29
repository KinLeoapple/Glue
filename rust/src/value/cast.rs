//! 标量转换：cast（wrap 语义）和 try_cast（越界报错）
//!
//! 对应 Zig 实现中的 `cast.zig`。使用 `ScalarTag` 作为分派键。
//! `cast` 遵循 Rust `as` 语义（永不失败，溢出截断/饱和）；
//! `try_cast` 在值域溢出时返回错误。

use crate::value::scalar::{F16, F128, ScalarTag};

// =========================================================================
// 错误类型
// =========================================================================

/// 转换错误：值域溢出或非法 codepoint
#[derive(Debug, Clone, PartialEq)]
pub enum CastError {
    /// 整数窄化溢出或浮点转整数越界
    Overflow,
    /// 整数转字符 codepoint 超出合法范围
    InvalidCodepoint,
}

/// 解析错误：字符串转数值失败
#[derive(Debug, Clone, PartialEq)]
pub enum ParseError {
    /// 解析失败
    ParseFailed(String),
}

// =========================================================================
// cast — wrap 语义（永不失败）
// =========================================================================

/// 标量转换（wrap 语义）：读取 `src_bytes` 按 `src_tag` 宽度，
/// 返回 `dst_tag` 宽度的字节序列。
///
/// 规则遵循 Rust `as`：
/// - i→i 宽化：零/符号扩展；i→i 窄化：截断
/// - f→f：round-to-nearest，溢出 → Inf
/// - i→f：round-to-nearest
/// - f→i：截断小数 + 饱和（NaN→0, +Inf→max, -Inf→min）
/// - bool→int：false=0, true=1; int→bool：0=false, 非0=true
/// - char→int：u32 codepoint; int→char：wrap 到 u32
pub fn cast_value(src_tag: ScalarTag, src_bytes: &[u8], dst_tag: ScalarTag) -> Vec<u8> {
    let dst_width = dst_tag.byte_width();
    let mut result = vec![0u8; dst_width];

    // 特殊处理：相同类型直接复制
    if src_tag == dst_tag {
        let copy_len = src_bytes.len().min(dst_width);
        result[..copy_len].copy_from_slice(&src_bytes[..copy_len]);
        return result;
    }

    match (src_tag, dst_tag) {
        // ---- bool → X ----
        (ScalarTag::Bool, _) => {
            let b = read_bool(src_bytes);
            cast_from_bool(b, dst_tag, &mut result);
        }
        // ---- char → X ----
        (ScalarTag::Char, _) => {
            let cp = read_u32_le(src_bytes);
            cast_from_u32(cp, dst_tag, &mut result);
        }
        // ---- X → bool ----
        (_, ScalarTag::Bool) => {
            let b = cast_to_bool(src_tag, src_bytes);
            write_bool(b, &mut result);
        }
        // ---- X → char ----
        (_, ScalarTag::Char) => {
            let cp = cast_to_u32(src_tag, src_bytes);
            write_u32_le(cp, &mut result);
        }
        // ---- int → int ----
        (s, d) if s.is_int() && d.is_int() => {
            cast_int_to_int(src_tag, src_bytes, dst_tag, &mut result);
        }
        // ---- int → float ----
        (s, d) if s.is_int() && d.is_float() => {
            cast_int_to_float(src_tag, src_bytes, dst_tag, &mut result);
        }
        // ---- float → int ----
        (s, d) if s.is_float() && d.is_int() => {
            cast_float_to_int(src_tag, src_bytes, dst_tag, &mut result);
        }
        // ---- float → float ----
        (s, d) if s.is_float() && d.is_float() => {
            cast_float_to_float(src_tag, src_bytes, dst_tag, &mut result);
        }
        _ => {}
    }

    result
}

// =========================================================================
// try_cast — 越界报错
// =========================================================================

/// 安全标量转换：与 `cast_value` 相同，但在以下情况返回错误：
/// - i→i 窄化溢出
/// - f→i NaN/Inf/超范围
/// - int→char codepoint 非法
pub fn try_cast_value(src_tag: ScalarTag, src_bytes: &[u8], dst_tag: ScalarTag) -> Result<Vec<u8>, CastError> {
    // 相同类型直接复制
    if src_tag == dst_tag {
        return Ok(cast_value(src_tag, src_bytes, dst_tag));
    }

    // int → char 需检查 codepoint 合法性
    if src_tag.is_int() && dst_tag == ScalarTag::Char {
        let cp = cast_to_u32(src_tag, src_bytes);
        if cp > 0x10FFFF || (0xD800..=0xDFFF).contains(&cp) {
            return Err(CastError::InvalidCodepoint);
        }
        let mut result = vec![0u8; 4];
        write_u32_le(cp, &mut result);
        return Ok(result);
    }

    // int → int 窄化需检查溢出
    if src_tag.is_int() && dst_tag.is_int() && src_tag.byte_width() > dst_tag.byte_width() {
        return try_cast_int_narrow(src_tag, src_bytes, dst_tag);
    }

    // float → int 需检查 NaN/Inf/超范围
    if src_tag.is_float() && dst_tag.is_int() {
        return try_cast_float_to_int(src_tag, src_bytes, dst_tag);
    }

    // 其余情况使用 wrap cast
    Ok(cast_value(src_tag, src_bytes, dst_tag))
}

// =========================================================================
// parse_str — 字符串转数值
// =========================================================================

/// 解析字符串为目标标量类型
pub fn parse_str(s: &str, dst_tag: ScalarTag) -> Result<Vec<u8>, ParseError> {
    let trimmed = s.trim();
    let result = vec![0u8; dst_tag.byte_width()];

    // 空字符串
    if trimmed.is_empty() {
        return Err(ParseError::ParseFailed("empty string".to_string()));
    }

    let mut result = result;

    match dst_tag {
        ScalarTag::Bool => {
            let b = match trimmed.to_ascii_lowercase().as_str() {
                "true" => true,
                "false" => false,
                _ => return Err(ParseError::ParseFailed(format!("invalid bool: {}", s))),
            };
            write_bool(b, &mut result);
        }
        ScalarTag::Char => {
            let mut chars = trimmed.chars();
            let c = chars.next().ok_or_else(|| ParseError::ParseFailed("empty char".to_string()))?;
            if chars.next().is_some() {
                return Err(ParseError::ParseFailed("char must be single character".to_string()));
            }
            write_u32_le(c as u32, &mut result);
        }
        ScalarTag::I8 => {
            let v: i8 = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_i8(v, &mut result);
        }
        ScalarTag::I16 => {
            let v: i16 = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_i16_le(v, &mut result);
        }
        ScalarTag::I32 => {
            let v: i32 = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_i32_le(v, &mut result);
        }
        ScalarTag::I64 => {
            let v: i64 = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_i64_le(v, &mut result);
        }
        ScalarTag::I128 => {
            let v: i128 = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_i128_le(v, &mut result);
        }
        ScalarTag::U8 => {
            let v: u8 = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_u8(v, &mut result);
        }
        ScalarTag::U16 => {
            let v: u16 = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_u16_le(v, &mut result);
        }
        ScalarTag::U32 => {
            let v: u32 = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_u32_le(v, &mut result);
        }
        ScalarTag::U64 => {
            let v: u64 = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_u64_le(v, &mut result);
        }
        ScalarTag::U128 => {
            let v: u128 = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_u128_le(v, &mut result);
        }
        ScalarTag::Isize => {
            let v: isize = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_i64_le(v as i64, &mut result);
        }
        ScalarTag::Usize => {
            let v: usize = trimmed.parse().map_err(|e: std::num::ParseIntError| ParseError::ParseFailed(e.to_string()))?;
            write_u64_le(v as u64, &mut result);
        }
        ScalarTag::F32 => {
            let v: f32 = trimmed.parse().map_err(|e: std::num::ParseFloatError| ParseError::ParseFailed(e.to_string()))?;
            write_f32_le(v, &mut result);
        }
        ScalarTag::F64 => {
            let v: f64 = trimmed.parse().map_err(|e: std::num::ParseFloatError| ParseError::ParseFailed(e.to_string()))?;
            write_f64_le(v, &mut result);
        }
        ScalarTag::F16 => {
            let v: f32 = trimmed.parse().map_err(|e: std::num::ParseFloatError| ParseError::ParseFailed(e.to_string()))?;
            let f16 = F16::from_f32(v);
            write_u16_le(f16.0, &mut result);
        }
        ScalarTag::F128 => {
            let v: f64 = trimmed.parse().map_err(|e: std::num::ParseFloatError| ParseError::ParseFailed(e.to_string()))?;
            let f128 = F128::from_f64(v);
            result.copy_from_slice(&f128.0);
        }
    }

    Ok(result)
}

// =========================================================================
// 内部辅助：读取
// =========================================================================

fn read_bool(bytes: &[u8]) -> bool {
    bytes.first().copied().unwrap_or(0) != 0
}

fn read_u32_le(bytes: &[u8]) -> u32 {
    let mut buf = [0u8; 4];
    let len = bytes.len().min(4);
    buf[..len].copy_from_slice(&bytes[..len]);
    u32::from_le_bytes(buf)
}

fn read_i64_le(bytes: &[u8]) -> i64 {
    let mut buf = [0u8; 8];
    let len = bytes.len().min(8);
    buf[..len].copy_from_slice(&bytes[..len]);
    i64::from_le_bytes(buf)
}

fn read_u64_le(bytes: &[u8]) -> u64 {
    let mut buf = [0u8; 8];
    let len = bytes.len().min(8);
    buf[..len].copy_from_slice(&bytes[..len]);
    u64::from_le_bytes(buf)
}

fn read_i128_le(bytes: &[u8]) -> i128 {
    let mut buf = [0u8; 16];
    let len = bytes.len().min(16);
    buf[..len].copy_from_slice(&bytes[..len]);
    i128::from_le_bytes(buf)
}

fn read_u128_le(bytes: &[u8]) -> u128 {
    let mut buf = [0u8; 16];
    let len = bytes.len().min(16);
    buf[..len].copy_from_slice(&bytes[..len]);
    u128::from_le_bytes(buf)
}

fn read_f32_le(bytes: &[u8]) -> f32 {
    let mut buf = [0u8; 4];
    let len = bytes.len().min(4);
    buf[..len].copy_from_slice(&bytes[..len]);
    f32::from_le_bytes(buf)
}

fn read_f64_le(bytes: &[u8]) -> f64 {
    let mut buf = [0u8; 8];
    let len = bytes.len().min(8);
    buf[..len].copy_from_slice(&bytes[..len]);
    f64::from_le_bytes(buf)
}

fn read_f16(bits: &[u8]) -> F16 {
    let mut buf = [0u8; 2];
    let len = bits.len().min(2);
    buf[..len].copy_from_slice(&bits[..len]);
    F16(u16::from_le_bytes(buf))
}

fn read_f128(bytes: &[u8]) -> F128 {
    let mut buf = [0u8; 16];
    let len = bytes.len().min(16);
    buf[..len].copy_from_slice(&bytes[..len]);
    F128(buf)
}

/// 读取整数并统一转为 i128（用于 int→int 和 int→float）
fn read_int_as_i128(tag: ScalarTag, bytes: &[u8]) -> i128 {
    match tag {
        ScalarTag::I8 => bytes.first().copied().unwrap_or(0) as i8 as i128,
        ScalarTag::U8 => bytes.first().copied().unwrap_or(0) as u8 as i128,
        ScalarTag::I16 => i16::from_le_bytes({
            let mut b = [0u8; 2];
            let l = bytes.len().min(2);
            b[..l].copy_from_slice(&bytes[..l]);
            b
        }) as i128,
        ScalarTag::U16 => u16::from_le_bytes({
            let mut b = [0u8; 2];
            let l = bytes.len().min(2);
            b[..l].copy_from_slice(&bytes[..l]);
            b
        }) as i128,
        ScalarTag::I32 => i32::from_le_bytes({
            let mut b = [0u8; 4];
            let l = bytes.len().min(4);
            b[..l].copy_from_slice(&bytes[..l]);
            b
        }) as i128,
        ScalarTag::U32 => u32::from_le_bytes({
            let mut b = [0u8; 4];
            let l = bytes.len().min(4);
            b[..l].copy_from_slice(&bytes[..l]);
            b
        }) as i128,
        ScalarTag::I64 => read_i64_le(bytes) as i128,
        ScalarTag::U64 => read_u64_le(bytes) as i128,
        ScalarTag::I128 => read_i128_le(bytes),
        ScalarTag::U128 => read_u128_le(bytes) as i128,
        ScalarTag::Isize => read_i64_le(bytes) as isize as i128,
        ScalarTag::Usize => read_u64_le(bytes) as usize as i128,
        _ => 0,
    }
}

/// 读取整数并统一转为 u128（用于无符号目标）
fn read_int_as_u128(tag: ScalarTag, bytes: &[u8]) -> u128 {
    match tag {
        ScalarTag::I8 => bytes.first().copied().unwrap_or(0) as i8 as i128 as u128,
        ScalarTag::U8 => bytes.first().copied().unwrap_or(0) as u8 as u128,
        ScalarTag::I16 => i16::from_le_bytes({
            let mut b = [0u8; 2];
            let l = bytes.len().min(2);
            b[..l].copy_from_slice(&bytes[..l]);
            b
        }) as i128 as u128,
        ScalarTag::U16 => u16::from_le_bytes({
            let mut b = [0u8; 2];
            let l = bytes.len().min(2);
            b[..l].copy_from_slice(&bytes[..l]);
            b
        }) as u128,
        ScalarTag::I32 => i32::from_le_bytes({
            let mut b = [0u8; 4];
            let l = bytes.len().min(4);
            b[..l].copy_from_slice(&bytes[..l]);
            b
        }) as i128 as u128,
        ScalarTag::U32 => u32::from_le_bytes({
            let mut b = [0u8; 4];
            let l = bytes.len().min(4);
            b[..l].copy_from_slice(&bytes[..l]);
            b
        }) as u128,
        ScalarTag::I64 => read_i64_le(bytes) as i128 as u128,
        ScalarTag::U64 => read_u64_le(bytes) as u128,
        ScalarTag::I128 => read_i128_le(bytes) as u128,
        ScalarTag::U128 => read_u128_le(bytes),
        ScalarTag::Isize => read_i64_le(bytes) as isize as i128 as u128,
        ScalarTag::Usize => read_u64_le(bytes) as usize as u128,
        _ => 0,
    }
}

// =========================================================================
// 内部辅助：写入
// =========================================================================

fn write_bool(b: bool, dst: &mut [u8]) {
    if dst.is_empty() { return; }
    dst[0] = if b { 1 } else { 0 };
}

fn write_u8(v: u8, dst: &mut [u8]) {
    if !dst.is_empty() { dst[0] = v; }
}

fn write_i8(v: i8, dst: &mut [u8]) {
    write_u8(v as u8, dst);
}

fn write_u16_le(v: u16, dst: &mut [u8]) {
    let bytes = v.to_le_bytes();
    let len = dst.len().min(2);
    dst[..len].copy_from_slice(&bytes[..len]);
}

fn write_i16_le(v: i16, dst: &mut [u8]) {
    write_u16_le(v as u16, dst);
}

fn write_u32_le(v: u32, dst: &mut [u8]) {
    let bytes = v.to_le_bytes();
    let len = dst.len().min(4);
    dst[..len].copy_from_slice(&bytes[..len]);
}

fn write_i32_le(v: i32, dst: &mut [u8]) {
    write_u32_le(v as u32, dst);
}

fn write_u64_le(v: u64, dst: &mut [u8]) {
    let bytes = v.to_le_bytes();
    let len = dst.len().min(8);
    dst[..len].copy_from_slice(&bytes[..len]);
}

fn write_i64_le(v: i64, dst: &mut [u8]) {
    write_u64_le(v as u64, dst);
}

fn write_u128_le(v: u128, dst: &mut [u8]) {
    let bytes = v.to_le_bytes();
    let len = dst.len().min(16);
    dst[..len].copy_from_slice(&bytes[..len]);
}

fn write_i128_le(v: i128, dst: &mut [u8]) {
    write_u128_le(v as u128, dst);
}

fn write_f32_le(v: f32, dst: &mut [u8]) {
    let bytes = v.to_le_bytes();
    let len = dst.len().min(4);
    dst[..len].copy_from_slice(&bytes[..len]);
}

fn write_f64_le(v: f64, dst: &mut [u8]) {
    let bytes = v.to_le_bytes();
    let len = dst.len().min(8);
    dst[..len].copy_from_slice(&bytes[..len]);
}

fn write_f16(f: F16, dst: &mut [u8]) {
    write_u16_le(f.0, dst);
}

fn write_f128(f: F128, dst: &mut [u8]) {
    let len = dst.len().min(16);
    dst[..len].copy_from_slice(&f.0[..len]);
}

// =========================================================================
// 内部辅助：转换逻辑
// =========================================================================

fn cast_from_bool(b: bool, dst_tag: ScalarTag, dst: &mut [u8]) {
    let val: i128 = if b { 1 } else { 0 };
    if dst_tag.is_int() {
        cast_from_i128(val, dst_tag, dst);
    } else if dst_tag.is_float() {
        let f = if b { 1.0 } else { 0.0 };
        cast_from_f64(f, dst_tag, dst);
    } else if dst_tag == ScalarTag::Char {
        write_u32_le(val as u32, dst);
    }
}

fn cast_from_u32(cp: u32, dst_tag: ScalarTag, dst: &mut [u8]) {
    if dst_tag.is_int() {
        cast_from_u128(cp as u128, dst_tag, dst);
    } else if dst_tag.is_float() {
        cast_from_f64(cp as f64, dst_tag, dst);
    } else if dst_tag == ScalarTag::Bool {
        write_bool(cp != 0, dst);
    }
}

fn cast_from_i128(val: i128, dst_tag: ScalarTag, dst: &mut [u8]) {
    match dst_tag {
        ScalarTag::I8 => write_i8(val as i8, dst),
        ScalarTag::U8 => write_u8(val as u8, dst),
        ScalarTag::I16 => write_i16_le(val as i16, dst),
        ScalarTag::U16 => write_u16_le(val as u16, dst),
        ScalarTag::I32 => write_i32_le(val as i32, dst),
        ScalarTag::U32 => write_u32_le(val as u32, dst),
        ScalarTag::I64 => write_i64_le(val as i64, dst),
        ScalarTag::U64 => write_u64_le(val as u64, dst),
        ScalarTag::I128 => write_i128_le(val, dst),
        ScalarTag::U128 => write_u128_le(val as u128, dst),
        ScalarTag::Isize => write_i64_le(val as isize as i64, dst),
        ScalarTag::Usize => write_u64_le(val as usize as u64, dst),
        _ => {}
    }
}

fn cast_from_u128(val: u128, dst_tag: ScalarTag, dst: &mut [u8]) {
    match dst_tag {
        ScalarTag::I8 => write_i8(val as i8, dst),
        ScalarTag::U8 => write_u8(val as u8, dst),
        ScalarTag::I16 => write_i16_le(val as i16, dst),
        ScalarTag::U16 => write_u16_le(val as u16, dst),
        ScalarTag::I32 => write_i32_le(val as i32, dst),
        ScalarTag::U32 => write_u32_le(val as u32, dst),
        ScalarTag::I64 => write_i64_le(val as i64, dst),
        ScalarTag::U64 => write_u64_le(val as u64, dst),
        ScalarTag::I128 => write_i128_le(val as i128, dst),
        ScalarTag::U128 => write_u128_le(val, dst),
        ScalarTag::Isize => write_i64_le(val as isize as i64, dst),
        ScalarTag::Usize => write_u64_le(val as usize as u64, dst),
        _ => {}
    }
}

fn cast_from_f64(val: f64, dst_tag: ScalarTag, dst: &mut [u8]) {
    match dst_tag {
        ScalarTag::F16 => write_f16(F16::from_f32(val as f32), dst),
        ScalarTag::F32 => write_f32_le(val as f32, dst),
        ScalarTag::F64 => write_f64_le(val, dst),
        ScalarTag::F128 => write_f128(F128::from_f64(val), dst),
        _ => {}
    }
}

fn cast_to_bool(src_tag: ScalarTag, src_bytes: &[u8]) -> bool {
    match src_tag {
        ScalarTag::Bool => read_bool(src_bytes),
        ScalarTag::Char => read_u32_le(src_bytes) != 0,
        ScalarTag::I8 => src_bytes.first().copied().unwrap_or(0) as i8 != 0,
        ScalarTag::U8 => src_bytes.first().copied().unwrap_or(0) != 0,
        ScalarTag::I16 | ScalarTag::U16 => {
            let mut b = [0u8; 2];
            let l = src_bytes.len().min(2);
            b[..l].copy_from_slice(&src_bytes[..l]);
            u16::from_le_bytes(b) != 0
        }
        ScalarTag::I32 | ScalarTag::U32 => {
            let v = read_u32_le(src_bytes);
            v != 0
        }
        ScalarTag::I64 | ScalarTag::U64 | ScalarTag::Isize | ScalarTag::Usize => {
            read_u64_le(src_bytes) != 0
        }
        ScalarTag::I128 | ScalarTag::U128 => {
            read_u128_le(src_bytes) != 0
        }
        ScalarTag::F32 => read_f32_le(src_bytes) != 0.0,
        ScalarTag::F64 => read_f64_le(src_bytes) != 0.0,
        ScalarTag::F16 => read_f16(src_bytes).to_f32() != 0.0,
        ScalarTag::F128 => read_f128(src_bytes).to_f64() != 0.0,
    }
}

fn cast_to_u32(src_tag: ScalarTag, src_bytes: &[u8]) -> u32 {
    if src_tag.is_int() {
        read_int_as_u128(src_tag, src_bytes) as u32
    } else if src_tag.is_float() {
        let f = read_float_as_f64(src_tag, src_bytes);
        // float → u32：截断 + 饱和
        if f.is_nan() {
            0
        } else if f >= u32::MAX as f64 {
            u32::MAX
        } else if f <= 0.0 {
            0
        } else {
            f as u32
        }
    } else if src_tag == ScalarTag::Bool {
        if read_bool(src_bytes) { 1 } else { 0 }
    } else {
        0
    }
}

fn read_float_as_f64(tag: ScalarTag, bytes: &[u8]) -> f64 {
    match tag {
        ScalarTag::F16 => read_f16(bytes).to_f64(),
        ScalarTag::F32 => read_f32_le(bytes) as f64,
        ScalarTag::F64 => read_f64_le(bytes),
        ScalarTag::F128 => read_f128(bytes).to_f64(),
        _ => 0.0,
    }
}

fn cast_int_to_int(src_tag: ScalarTag, src_bytes: &[u8], dst_tag: ScalarTag, dst: &mut [u8]) {
    if dst_tag.is_signed() {
        let val = read_int_as_i128(src_tag, src_bytes);
        cast_from_i128(val, dst_tag, dst);
    } else {
        let val = read_int_as_u128(src_tag, src_bytes);
        cast_from_u128(val, dst_tag, dst);
    }
}

fn cast_int_to_float(src_tag: ScalarTag, src_bytes: &[u8], dst_tag: ScalarTag, dst: &mut [u8]) {
    let val = if src_tag.is_signed() {
        read_int_as_i128(src_tag, src_bytes) as f64
    } else {
        read_int_as_u128(src_tag, src_bytes) as f64
    };
    cast_from_f64(val, dst_tag, dst);
}

fn cast_float_to_int(src_tag: ScalarTag, src_bytes: &[u8], dst_tag: ScalarTag, dst: &mut [u8]) {
    let f = read_float_as_f64(src_tag, src_bytes);

    // 使用 Rust 原生 `as` 转换的饱和语义（Rust 1.45+）：
    // - NaN → 0
    // - +Inf → dst_type::MAX
    // - -Inf → dst_type::MIN
    // - 超范围值 → 饱和到 dst_type 边界
    // - 正常值 → 截断小数
    match dst_tag {
        ScalarTag::I8 => write_i8(f as i8, dst),
        ScalarTag::I16 => write_i16_le(f as i16, dst),
        ScalarTag::I32 => write_i32_le(f as i32, dst),
        ScalarTag::I64 => write_i64_le(f as i64, dst),
        ScalarTag::I128 => write_i128_le(f as i128, dst),
        ScalarTag::Isize => write_i64_le(f as isize as i64, dst),
        ScalarTag::U8 => write_u8(f as u8, dst),
        ScalarTag::U16 => write_u16_le(f as u16, dst),
        ScalarTag::U32 => write_u32_le(f as u32, dst),
        ScalarTag::U64 => write_u64_le(f as u64, dst),
        ScalarTag::U128 => write_u128_le(f as u128, dst),
        ScalarTag::Usize => write_u64_le(f as usize as u64, dst),
        _ => {}
    }
}

fn cast_float_to_float(src_tag: ScalarTag, src_bytes: &[u8], dst_tag: ScalarTag, dst: &mut [u8]) {
    let f = read_float_as_f64(src_tag, src_bytes);
    cast_from_f64(f, dst_tag, dst);
}

fn try_cast_int_narrow(src_tag: ScalarTag, src_bytes: &[u8], dst_tag: ScalarTag) -> Result<Vec<u8>, CastError> {
    // 读取源值（有符号和无符号两种表示）
    let sval = read_int_as_i128(src_tag, src_bytes);
    let uval = read_int_as_u128(src_tag, src_bytes);

    // 检查值域
    let in_range = if dst_tag.is_signed() {
        match dst_tag {
            ScalarTag::I8 => (i8::MIN as i128..=i8::MAX as i128).contains(&sval),
            ScalarTag::I16 => (i16::MIN as i128..=i16::MAX as i128).contains(&sval),
            ScalarTag::I32 => (i32::MIN as i128..=i32::MAX as i128).contains(&sval),
            ScalarTag::I64 => (i64::MIN as i128..=i64::MAX as i128).contains(&sval),
            ScalarTag::Isize => (isize::MIN as i128..=isize::MAX as i128).contains(&sval),
            _ => true,
        }
    } else {
        // 无符号目标：源必须非负且在范围内
        if src_tag.is_signed() && sval < 0 {
            false
        } else {
            match dst_tag {
                ScalarTag::U8 => uval <= u8::MAX as u128,
                ScalarTag::U16 => uval <= u16::MAX as u128,
                ScalarTag::U32 => uval <= u32::MAX as u128,
                ScalarTag::U64 => uval <= u64::MAX as u128,
                ScalarTag::Usize => uval <= usize::MAX as u128,
                _ => true,
            }
        }
    };

    if !in_range {
        return Err(CastError::Overflow);
    }

    Ok(cast_value(src_tag, src_bytes, dst_tag))
}

fn try_cast_float_to_int(src_tag: ScalarTag, src_bytes: &[u8], dst_tag: ScalarTag) -> Result<Vec<u8>, CastError> {
    let f = read_float_as_f64(src_tag, src_bytes);

    // NaN 或 Inf → 错误
    if f.is_nan() || f.is_infinite() {
        return Err(CastError::Overflow);
    }

    // 检查值域
    let in_range = if dst_tag.is_signed() {
        match dst_tag {
            ScalarTag::I8 => f >= i8::MIN as f64 && f <= i8::MAX as f64,
            ScalarTag::I16 => f >= i16::MIN as f64 && f <= i16::MAX as f64,
            ScalarTag::I32 => f >= i32::MIN as f64 && f <= i32::MAX as f64,
            ScalarTag::I64 => f >= i64::MIN as f64 && f <= i64::MAX as f64,
            ScalarTag::I128 => f >= i128::MIN as f64 && f <= i128::MAX as f64,
            ScalarTag::Isize => f >= isize::MIN as f64 && f <= isize::MAX as f64,
            _ => true,
        }
    } else {
        match dst_tag {
            ScalarTag::U8 => f >= 0.0 && f <= u8::MAX as f64,
            ScalarTag::U16 => f >= 0.0 && f <= u16::MAX as f64,
            ScalarTag::U32 => f >= 0.0 && f <= u32::MAX as f64,
            ScalarTag::U64 => f >= 0.0 && f <= u64::MAX as f64,
            ScalarTag::U128 => f >= 0.0 && f <= u128::MAX as f64,
            ScalarTag::Usize => f >= 0.0 && f <= usize::MAX as f64,
            _ => true,
        }
    };

    if !in_range {
        return Err(CastError::Overflow);
    }

    Ok(cast_value(src_tag, src_bytes, dst_tag))
}

// =========================================================================
// 测试
// =========================================================================

#[cfg(test)]
mod tests {
    use super::*;

    fn make_bytes(v: i32) -> Vec<u8> {
        v.to_le_bytes().to_vec()
    }

    #[test]
    fn test_cast_i32_to_i64() {
        let src = make_bytes(42);
        let dst = cast_value(ScalarTag::I32, &src, ScalarTag::I64);
        assert_eq!(i64::from_le_bytes({
            let mut b = [0u8; 8];
            b.copy_from_slice(&dst);
            b
        }), 42);
    }

    #[test]
    fn test_cast_i32_to_i8_wrap() {
        let src = make_bytes(300); // 超出 i8 范围
        let dst = cast_value(ScalarTag::I32, &src, ScalarTag::I8);
        assert_eq!(dst[0] as i8, 300i32 as i8); // wrap
    }

    #[test]
    fn test_try_cast_i32_to_i8_overflow() {
        let src = make_bytes(300);
        assert_eq!(
            try_cast_value(ScalarTag::I32, &src, ScalarTag::I8),
            Err(CastError::Overflow)
        );
    }

    #[test]
    fn test_try_cast_i32_to_i8_ok() {
        let src = make_bytes(100);
        let dst = try_cast_value(ScalarTag::I32, &src, ScalarTag::I8).unwrap();
        assert_eq!(dst[0] as i8, 100);
    }

    #[test]
    fn test_cast_f64_to_i32_truncate() {
        let src = 3.7f64.to_le_bytes().to_vec();
        let dst = cast_value(ScalarTag::F64, &src, ScalarTag::I32);
        let v = i32::from_le_bytes({
            let mut b = [0u8; 4];
            b.copy_from_slice(&dst);
            b
        });
        assert_eq!(v, 3);
    }

    #[test]
    fn test_cast_f64_to_i32_nan() {
        let src = f64::NAN.to_le_bytes().to_vec();
        let dst = cast_value(ScalarTag::F64, &src, ScalarTag::I32);
        let v = i32::from_le_bytes({
            let mut b = [0u8; 4];
            b.copy_from_slice(&dst);
            b
        });
        assert_eq!(v, 0);
    }

    #[test]
    fn test_cast_f64_to_i32_inf() {
        let src = f64::INFINITY.to_le_bytes().to_vec();
        let dst = cast_value(ScalarTag::F64, &src, ScalarTag::I32);
        let v = i32::from_le_bytes({
            let mut b = [0u8; 4];
            b.copy_from_slice(&dst);
            b
        });
        assert_eq!(v, i32::MAX);
    }

    #[test]
    fn test_try_cast_f64_to_i32_nan() {
        let src = f64::NAN.to_le_bytes().to_vec();
        assert_eq!(
            try_cast_value(ScalarTag::F64, &src, ScalarTag::I32),
            Err(CastError::Overflow)
        );
    }

    #[test]
    fn test_cast_bool_to_int() {
        let src = vec![1u8];
        let dst = cast_value(ScalarTag::Bool, &src, ScalarTag::I32);
        let v = i32::from_le_bytes({
            let mut b = [0u8; 4];
            b.copy_from_slice(&dst);
            b
        });
        assert_eq!(v, 1);
    }

    #[test]
    fn test_cast_int_to_bool() {
        let src = make_bytes(0);
        let dst = cast_value(ScalarTag::I32, &src, ScalarTag::Bool);
        assert_eq!(dst[0], 0);

        let src = make_bytes(42);
        let dst = cast_value(ScalarTag::I32, &src, ScalarTag::Bool);
        assert_eq!(dst[0], 1);
    }

    #[test]
    fn test_cast_char_to_int() {
        let src = 65u32.to_le_bytes().to_vec(); // 'A'
        let dst = cast_value(ScalarTag::Char, &src, ScalarTag::I64);
        let v = i64::from_le_bytes({
            let mut b = [0u8; 8];
            b.copy_from_slice(&dst);
            b
        });
        assert_eq!(v, 65);
    }

    #[test]
    fn test_try_cast_int_to_char_invalid() {
        let src = 0x110000u32.to_le_bytes().to_vec();
        assert_eq!(
            try_cast_value(ScalarTag::I32, &src, ScalarTag::Char),
            Err(CastError::InvalidCodepoint)
        );
    }

    #[test]
    fn test_try_cast_int_to_char_valid() {
        let src = 65i32.to_le_bytes().to_vec();
        let dst = try_cast_value(ScalarTag::I32, &src, ScalarTag::Char).unwrap();
        let v = u32::from_le_bytes({
            let mut b = [0u8; 4];
            b.copy_from_slice(&dst);
            b
        });
        assert_eq!(v, 65);
    }

    #[test]
    fn test_parse_str_int() {
        let dst = parse_str("42", ScalarTag::I32).unwrap();
        let v = i32::from_le_bytes({
            let mut b = [0u8; 4];
            b.copy_from_slice(&dst);
            b
        });
        assert_eq!(v, 42);
    }

    #[test]
    fn test_parse_str_bool() {
        let dst = parse_str("true", ScalarTag::Bool).unwrap();
        assert_eq!(dst[0], 1);

        let dst = parse_str("false", ScalarTag::Bool).unwrap();
        assert_eq!(dst[0], 0);
    }

    #[test]
    fn test_parse_str_float() {
        let dst = parse_str("2.5", ScalarTag::F64).unwrap();
        let v = f64::from_le_bytes({
            let mut b = [0u8; 8];
            b.copy_from_slice(&dst);
            b
        });
        assert!((v - 2.5).abs() < 1e-10);
    }

    #[test]
    fn test_parse_str_fail() {
        assert!(parse_str("abc", ScalarTag::I32).is_err());
    }
}
