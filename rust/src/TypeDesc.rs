//! TypeDesc.rs — Glue 语言共享类型描述符层
//!
//! 被（未来的）`Sema.rs` 与 `Ir.rs` 共同依赖的类型描述符中间层。提供统一的
//! `TypeOps` trait 抽象（read / write / coerce / equal / format / hash_val /
//! clone_val），以及静态类型描述符常量与动态 `TypeDescriptorPool`。
//!
//! 依赖关系：单向依赖 `crate::Value`
//! （`ValueArena` / `ValueHandle` / `ValueTag` / `F16` / `F128` / `Char`），
//! 不依赖 Sema 或 Ir，作为共享层存在。
//!
//! `type_id` 编号约定：
//! - 1..=18：18 种标量（i8=1, i16=2, i32=3, i64=4, i128=5, u8=6, u16=7, u32=8,
//!   u64=9, u128=10, isize=11, usize=12, f16=13, f32=14, f64=15, f128=16,
//!   bool=17, char=18）
//! - 19：str
//! - 20：null
//! - 21：void
//! - 22+：用户类型（经 `TypeDescriptorPool::register` 分配）

use crate::Value::{Char, F128, F16, ValueArena, ValueHandle, ValueTag};
use std::collections::HashMap;

// =========================================================================
// IntKind / FloatKind 枚举
// =========================================================================

/// 整数种类枚举：覆盖所有 Glue 整数类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum IntKind {
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
}

/// 浮点种类枚举：覆盖 f16 / f32 / f64 / f128。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FloatKind {
    F16,
    F32,
    F64,
    F128,
}

// =========================================================================
// TypeOps trait
// =========================================================================

/// 类型操作 trait：描述某种类型在原始字节缓冲区与 `ValueArena` 句柄之间的
/// 转换语义。所有方法均为热路径，实现应保持 `#[inline]`。
///
/// 实现者要求 `Send + Sync + 'static`，以便描述符可被静态构造并跨线程共享。
pub trait TypeOps: Send + Sync + 'static {
    /// 从 `ptr` 读取一个值，分配到 `arena` 并返回句柄。
    fn read(&self, ptr: *const u8, arena: &mut ValueArena) -> ValueHandle;
    /// 将句柄 `v` 对应的值写入 `ptr`。
    fn write(&self, ptr: *mut u8, v: ValueHandle, arena: &ValueArena);
    /// 将任意句柄 `v` 强制转换为本类型句柄。
    fn coerce(&self, v: ValueHandle, arena: &mut ValueArena) -> ValueHandle;
    /// 比较两块内存中的值是否相等。
    fn equal(&self, a: *const u8, b: *const u8) -> bool;
    /// 将 `ptr` 处的值格式化写入 `buf`，返回写入部分的 `&str` 切片。
    fn format<'a>(&self, ptr: *const u8, buf: &'a mut [u8]) -> &'a str;
    /// 计算值的哈希。
    fn hash_val(&self, ptr: *const u8) -> u64;
    /// 克隆值（标量为值语义，等价于 read）。
    fn clone_val(&self, ptr: *const u8, arena: &mut ValueArena) -> ValueHandle;
}

// =========================================================================
// TypeDescriptor 结构体 + 元信息方法
// =========================================================================

/// 类型描述符：聚合字节尺寸、`ops`、`type_id` 与类型名。
pub struct TypeDescriptor {
    pub size: u8,
    pub ops: &'static dyn TypeOps,
    pub type_id: u16,
    pub type_name: &'static str,
}

// 手动实现 `Debug`：`ops` 为 trait object 无法 derive，仅输出元信息。
impl std::fmt::Debug for TypeDescriptor {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TypeDescriptor")
            .field("size", &self.size)
            .field("type_id", &self.type_id)
            .field("type_name", &self.type_name)
            .finish()
    }
}

impl TypeDescriptor {
    /// 元素字节宽度。
    #[inline]
    pub fn elem_width(&self) -> usize {
        self.size as usize
    }

    /// 是否为 null 类型（type_id == 20）。
    #[inline]
    pub fn is_null_type(&self) -> bool {
        self.type_id == 20
    }

    /// 是否为 void 类型（type_id == 21）。
    #[inline]
    pub fn is_void_type(&self) -> bool {
        self.type_id == 21
    }

    /// 是否为引用类型：str(19) 或用户类型(>=22)；nullable 类型不算引用。
    #[inline]
    pub fn is_ref(&self) -> bool {
        !self.is_nullable() && (self.type_id == 19 || self.type_id >= 22)
    }

    /// 是否为 nullable 类型（type_name 以 "nullable" 开头）。
    #[inline]
    pub fn is_nullable(&self) -> bool {
        self.type_name.starts_with("nullable")
    }

    /// 是否为整数类型（type_id 1..=12）。
    #[inline]
    pub fn is_int(&self) -> bool {
        matches!(self.type_id, 1..=12)
    }

    /// 是否为浮点类型（type_id 13..=16）。
    #[inline]
    pub fn is_float(&self) -> bool {
        matches!(self.type_id, 13..=16)
    }

    /// 转换为 `IntKind`，非整数类型返回 `None`。
    #[inline]
    pub fn to_int_kind(&self) -> Option<IntKind> {
        match self.type_id {
            1 => Some(IntKind::I8),
            2 => Some(IntKind::I16),
            3 => Some(IntKind::I32),
            4 => Some(IntKind::I64),
            5 => Some(IntKind::I128),
            6 => Some(IntKind::U8),
            7 => Some(IntKind::U16),
            8 => Some(IntKind::U32),
            9 => Some(IntKind::U64),
            10 => Some(IntKind::U128),
            11 => Some(IntKind::Isize),
            12 => Some(IntKind::Usize),
            _ => None,
        }
    }

    /// 转换为 `FloatKind`，非浮点类型返回 `None`。
    #[inline]
    pub fn to_float_kind(&self) -> Option<FloatKind> {
        match self.type_id {
            13 => Some(FloatKind::F16),
            14 => Some(FloatKind::F32),
            15 => Some(FloatKind::F64),
            16 => Some(FloatKind::F128),
            _ => None,
        }
    }
}

// =========================================================================
// 标量 ops 宏生成（14 种小尺寸标量）
// =========================================================================
//
// 宏参数：desc 名, ops 名, type_id, type_name, Rust 原生类型, 字节宽度,
// alloc 方法名, get 方法名, fmt 表达式, coerce 种类。
//
// 该宏同时生成 ZST ops 结构体、`TypeOps` 实现以及对应的静态 `TypeDescriptor`
// 常量。i128 / u128 / f128 / bool 因特殊语义手动实现。

macro_rules! impl_scalar_ops {
    // 内部分支：生成 read/write/equal/format/hash_val/clone_val 六个方法。
    // 这些方法的职责就是操作裸指针指向的类型化内存，clippy 的
    // `not_unsafe_ptr_arg_deref` 在此为误报，统一 allow。
    (@fns $ty:ty, $alloc:ident, $get:ident, [$v:ident => $fmt:expr]) => {
        #[inline]
        #[allow(clippy::not_unsafe_ptr_arg_deref)]
        fn read(&self, ptr: *const u8, arena: &mut ValueArena) -> ValueHandle {
            // SAFETY: ptr 指向合法的 $ty 值内存，按非对齐方式读取。
            let $v: $ty = unsafe { std::ptr::read_unaligned(ptr as *const $ty) };
            arena.$alloc($v)
        }
        #[inline]
        #[allow(clippy::not_unsafe_ptr_arg_deref)]
        fn write(&self, ptr: *mut u8, h: ValueHandle, arena: &ValueArena) {
            let $v: $ty = arena.$get(h);
            // SAFETY: ptr 指向可写的 $ty 内存，按非对齐方式写入。
            unsafe { std::ptr::write_unaligned(ptr as *mut $ty, $v) }
        }
        #[inline]
        #[allow(clippy::not_unsafe_ptr_arg_deref)]
        fn equal(&self, a: *const u8, b: *const u8) -> bool {
            // SAFETY: 两个指针均指向合法的 $ty 值。
            unsafe {
                std::ptr::read_unaligned(a as *const $ty)
                    == std::ptr::read_unaligned(b as *const $ty)
            }
        }
        #[inline]
        #[allow(clippy::not_unsafe_ptr_arg_deref)]
        fn format<'a>(&self, ptr: *const u8, buf: &'a mut [u8]) -> &'a str {
            // SAFETY: ptr 指向合法的 $ty 值。
            let $v: $ty = unsafe { std::ptr::read_unaligned(ptr as *const $ty) };
            use std::io::Write;
            let mut cursor = std::io::Cursor::new(buf);
            let _ = write!(cursor, "{}", $fmt);
            let written = cursor.position() as usize;
            let buf_ref: &mut [u8] = cursor.into_inner();
            // SAFETY: 原生数值/字符的 Display 输出为 ASCII 或合法 UTF-8。
            unsafe { std::str::from_utf8_unchecked(&buf_ref[..written]) }
        }
        #[inline]
        #[allow(clippy::not_unsafe_ptr_arg_deref)]
        fn hash_val(&self, ptr: *const u8) -> u64 {
            use std::hash::{Hash, Hasher};
            // SAFETY: ptr 指向合法的 $ty 值；按其字节表示哈希（对 f32/f64
            // 等未实现 Hash 的类型，统一按 bit pattern 哈希）。
            let bytes: &[u8] =
                unsafe { std::slice::from_raw_parts(ptr, std::mem::size_of::<$ty>()) };
            let mut h = std::collections::hash_map::DefaultHasher::new();
            bytes.hash(&mut h);
            h.finish()
        }
        #[inline]
        #[allow(clippy::not_unsafe_ptr_arg_deref)]
        fn clone_val(&self, ptr: *const u8, arena: &mut ValueArena) -> ValueHandle {
            // SAFETY: 标量为值语义，clone 等价于 read。
            let $v: $ty = unsafe { std::ptr::read_unaligned(ptr as *const $ty) };
            arena.$alloc($v)
        }
    };

    // 整数目标类型
    (
        $desc:ident, $ops:ident, $type_id:expr, $type_name:expr, $ty:ty, $size:expr,
        alloc=$alloc:ident, get=$get:ident, fmt($v:ident) => $fmt:expr, coerce=int
    ) => {
        pub struct $ops;
        impl TypeOps for $ops {
            impl_scalar_ops!(@fns $ty, $alloc, $get, [$v => $fmt]);
            #[inline]
            fn coerce(&self, v: ValueHandle, arena: &mut ValueArena) -> ValueHandle {
                let val: $ty = match v.tag() {
                    ValueTag::Bool => arena.get_bool(v) as $ty,
                    ValueTag::Char => arena.get_char(v) as $ty,
                    ValueTag::I8 => arena.get_i8(v) as $ty,
                    ValueTag::I16 => arena.get_i16(v) as $ty,
                    ValueTag::I32 => arena.get_i32(v) as $ty,
                    ValueTag::I64 => arena.get_i64(v) as $ty,
                    ValueTag::I128 => arena.get_i128(v) as $ty,
                    ValueTag::U8 => arena.get_u8(v) as $ty,
                    ValueTag::U16 => arena.get_u16(v) as $ty,
                    ValueTag::U32 => arena.get_u32(v) as $ty,
                    ValueTag::U64 => arena.get_u64(v) as $ty,
                    ValueTag::U128 => arena.get_u128(v) as $ty,
                    ValueTag::Isize => arena.get_isize(v) as $ty,
                    ValueTag::Usize => arena.get_usize(v) as $ty,
                    ValueTag::F16 => F16(arena.get_f16(v)).to_f32() as $ty,
                    ValueTag::F32 => arena.get_f32(v) as $ty,
                    ValueTag::F64 => arena.get_f64(v) as $ty,
                    ValueTag::F128 => arena.get_f128(v).to_f64() as $ty,
                    ValueTag::Null | ValueTag::Void | ValueTag::Ref => 0 as $ty,
                };
                arena.$alloc(val)
            }
        }
        pub static $desc: TypeDescriptor = TypeDescriptor {
            size: $size,
            ops: &$ops,
            type_id: $type_id,
            type_name: $type_name,
        };
    };

    // 浮点目标类型（f32 / f64）
    (
        $desc:ident, $ops:ident, $type_id:expr, $type_name:expr, $ty:ty, $size:expr,
        alloc=$alloc:ident, get=$get:ident, fmt($v:ident) => $fmt:expr, coerce=float
    ) => {
        pub struct $ops;
        impl TypeOps for $ops {
            impl_scalar_ops!(@fns $ty, $alloc, $get, [$v => $fmt]);
            #[inline]
            fn coerce(&self, v: ValueHandle, arena: &mut ValueArena) -> ValueHandle {
                let val: $ty = match v.tag() {
                    ValueTag::Bool => arena.get_bool(v) as u8 as $ty,
                    ValueTag::Char => arena.get_char(v) as u32 as $ty,
                    ValueTag::I8 => arena.get_i8(v) as $ty,
                    ValueTag::I16 => arena.get_i16(v) as $ty,
                    ValueTag::I32 => arena.get_i32(v) as $ty,
                    ValueTag::I64 => arena.get_i64(v) as $ty,
                    ValueTag::I128 => arena.get_i128(v) as $ty,
                    ValueTag::U8 => arena.get_u8(v) as $ty,
                    ValueTag::U16 => arena.get_u16(v) as $ty,
                    ValueTag::U32 => arena.get_u32(v) as $ty,
                    ValueTag::U64 => arena.get_u64(v) as $ty,
                    ValueTag::U128 => arena.get_u128(v) as $ty,
                    ValueTag::Isize => arena.get_isize(v) as $ty,
                    ValueTag::Usize => arena.get_usize(v) as $ty,
                    ValueTag::F16 => F16(arena.get_f16(v)).to_f32() as $ty,
                    ValueTag::F32 => arena.get_f32(v) as $ty,
                    ValueTag::F64 => arena.get_f64(v) as $ty,
                    ValueTag::F128 => arena.get_f128(v).to_f64() as $ty,
                    ValueTag::Null | ValueTag::Void | ValueTag::Ref => 0.0 as $ty,
                };
                arena.$alloc(val)
            }
        }
        pub static $desc: TypeDescriptor = TypeDescriptor {
            size: $size,
            ops: &$ops,
            type_id: $type_id,
            type_name: $type_name,
        };
    };

    // f16 目标类型
    (
        $desc:ident, $ops:ident, $type_id:expr, $type_name:expr, $ty:ty, $size:expr,
        alloc=$alloc:ident, get=$get:ident, fmt($v:ident) => $fmt:expr, coerce=f16
    ) => {
        pub struct $ops;
        impl TypeOps for $ops {
            impl_scalar_ops!(@fns $ty, $alloc, $get, [$v => $fmt]);
            #[inline]
            fn coerce(&self, v: ValueHandle, arena: &mut ValueArena) -> ValueHandle {
                let f: f32 = match v.tag() {
                    ValueTag::Bool => arena.get_bool(v) as u8 as f32,
                    ValueTag::Char => arena.get_char(v) as u32 as f32,
                    ValueTag::I8 => arena.get_i8(v) as f32,
                    ValueTag::I16 => arena.get_i16(v) as f32,
                    ValueTag::I32 => arena.get_i32(v) as f32,
                    ValueTag::I64 => arena.get_i64(v) as f32,
                    ValueTag::I128 => arena.get_i128(v) as f32,
                    ValueTag::U8 => arena.get_u8(v) as f32,
                    ValueTag::U16 => arena.get_u16(v) as f32,
                    ValueTag::U32 => arena.get_u32(v) as f32,
                    ValueTag::U64 => arena.get_u64(v) as f32,
                    ValueTag::U128 => arena.get_u128(v) as f32,
                    ValueTag::Isize => arena.get_isize(v) as f32,
                    ValueTag::Usize => arena.get_usize(v) as f32,
                    ValueTag::F16 => F16(arena.get_f16(v)).to_f32(),
                    ValueTag::F32 => arena.get_f32(v),
                    ValueTag::F64 => arena.get_f64(v) as f32,
                    ValueTag::F128 => arena.get_f128(v).to_f64() as f32,
                    ValueTag::Null | ValueTag::Void | ValueTag::Ref => 0.0,
                };
                arena.$alloc(F16::from_f32(f).0)
            }
        }
        pub static $desc: TypeDescriptor = TypeDescriptor {
            size: $size,
            ops: &$ops,
            type_id: $type_id,
            type_name: $type_name,
        };
    };

    // f128 目标类型
    (
        $desc:ident, $ops:ident, $type_id:expr, $type_name:expr, $ty:ty, $size:expr,
        alloc=$alloc:ident, get=$get:ident, fmt($v:ident) => $fmt:expr, coerce=f128
    ) => {
        pub struct $ops;
        impl TypeOps for $ops {
            impl_scalar_ops!(@fns $ty, $alloc, $get, [$v => $fmt]);
            #[inline]
            fn coerce(&self, v: ValueHandle, arena: &mut ValueArena) -> ValueHandle {
                let f: f64 = match v.tag() {
                    ValueTag::Bool => arena.get_bool(v) as u8 as f64,
                    ValueTag::Char => arena.get_char(v) as u32 as f64,
                    ValueTag::I8 => arena.get_i8(v) as f64,
                    ValueTag::I16 => arena.get_i16(v) as f64,
                    ValueTag::I32 => arena.get_i32(v) as f64,
                    ValueTag::I64 => arena.get_i64(v) as f64,
                    ValueTag::I128 => arena.get_i128(v) as f64,
                    ValueTag::U8 => arena.get_u8(v) as f64,
                    ValueTag::U16 => arena.get_u16(v) as f64,
                    ValueTag::U32 => arena.get_u32(v) as f64,
                    ValueTag::U64 => arena.get_u64(v) as f64,
                    ValueTag::U128 => arena.get_u128(v) as f64,
                    ValueTag::Isize => arena.get_isize(v) as f64,
                    ValueTag::Usize => arena.get_usize(v) as f64,
                    ValueTag::F16 => F16(arena.get_f16(v)).to_f32() as f64,
                    ValueTag::F32 => arena.get_f32(v) as f64,
                    ValueTag::F64 => arena.get_f64(v),
                    ValueTag::F128 => arena.get_f128(v).to_f64(),
                    ValueTag::Null | ValueTag::Void | ValueTag::Ref => 0.0,
                };
                arena.$alloc(F128::from_f64(f))
            }
        }
        pub static $desc: TypeDescriptor = TypeDescriptor {
            size: $size,
            ops: &$ops,
            type_id: $type_id,
            type_name: $type_name,
        };
    };

    // bool 目标类型
    (
        $desc:ident, $ops:ident, $type_id:expr, $type_name:expr, $ty:ty, $size:expr,
        alloc=$alloc:ident, get=$get:ident, fmt($v:ident) => $fmt:expr, coerce=bool
    ) => {
        pub struct $ops;
        impl TypeOps for $ops {
            impl_scalar_ops!(@fns $ty, $alloc, $get, [$v => $fmt]);
            #[inline]
            fn coerce(&self, v: ValueHandle, arena: &mut ValueArena) -> ValueHandle {
                let b: bool = match v.tag() {
                    ValueTag::Bool => arena.get_bool(v),
                    ValueTag::Char => arena.get_char(v) != 0,
                    ValueTag::I8 => arena.get_i8(v) != 0,
                    ValueTag::I16 => arena.get_i16(v) != 0,
                    ValueTag::I32 => arena.get_i32(v) != 0,
                    ValueTag::I64 => arena.get_i64(v) != 0,
                    ValueTag::I128 => arena.get_i128(v) != 0,
                    ValueTag::U8 => arena.get_u8(v) != 0,
                    ValueTag::U16 => arena.get_u16(v) != 0,
                    ValueTag::U32 => arena.get_u32(v) != 0,
                    ValueTag::U64 => arena.get_u64(v) != 0,
                    ValueTag::U128 => arena.get_u128(v) != 0,
                    ValueTag::Isize => arena.get_isize(v) != 0,
                    ValueTag::Usize => arena.get_usize(v) != 0,
                    ValueTag::F16 => F16(arena.get_f16(v)).to_f32() != 0.0,
                    ValueTag::F32 => arena.get_f32(v) != 0.0,
                    ValueTag::F64 => arena.get_f64(v) != 0.0,
                    ValueTag::F128 => arena.get_f128(v).to_f64() != 0.0,
                    ValueTag::Null | ValueTag::Void | ValueTag::Ref => false,
                };
                arena.$alloc(b)
            }
        }
        pub static $desc: TypeDescriptor = TypeDescriptor {
            size: $size,
            ops: &$ops,
            type_id: $type_id,
            type_name: $type_name,
        };
    };

    // char 目标类型
    (
        $desc:ident, $ops:ident, $type_id:expr, $type_name:expr, $ty:ty, $size:expr,
        alloc=$alloc:ident, get=$get:ident, fmt($v:ident) => $fmt:expr, coerce=char
    ) => {
        pub struct $ops;
        impl TypeOps for $ops {
            impl_scalar_ops!(@fns $ty, $alloc, $get, [$v => $fmt]);
            #[inline]
            fn coerce(&self, v: ValueHandle, arena: &mut ValueArena) -> ValueHandle {
                let c: u32 = match v.tag() {
                    ValueTag::Bool => arena.get_bool(v) as u32,
                    ValueTag::Char => arena.get_char(v),
                    ValueTag::I8 => arena.get_i8(v) as u32,
                    ValueTag::I16 => arena.get_i16(v) as u32,
                    ValueTag::I32 => arena.get_i32(v) as u32,
                    ValueTag::I64 => arena.get_i64(v) as u32,
                    ValueTag::I128 => arena.get_i128(v) as u32,
                    ValueTag::U8 => arena.get_u8(v) as u32,
                    ValueTag::U16 => arena.get_u16(v) as u32,
                    ValueTag::U32 => arena.get_u32(v),
                    ValueTag::U64 => arena.get_u64(v) as u32,
                    ValueTag::U128 => arena.get_u128(v) as u32,
                    ValueTag::Isize => arena.get_isize(v) as u32,
                    ValueTag::Usize => arena.get_usize(v) as u32,
                    ValueTag::F16 => F16(arena.get_f16(v)).to_f32() as u32,
                    ValueTag::F32 => arena.get_f32(v) as u32,
                    ValueTag::F64 => arena.get_f64(v) as u32,
                    ValueTag::F128 => arena.get_f128(v).to_f64() as u32,
                    ValueTag::Null | ValueTag::Void | ValueTag::Ref => 0,
                };
                arena.$alloc(c)
            }
        }
        pub static $desc: TypeDescriptor = TypeDescriptor {
            size: $size,
            ops: &$ops,
            type_id: $type_id,
            type_name: $type_name,
        };
    };
}

// 14 种小尺寸标量的宏实例化（同时生成 ops 结构体与静态描述符常量）。
impl_scalar_ops!(I8_DESC, I8Ops, 1, "i8", i8, 1, alloc=alloc_i8, get=get_i8, fmt(v) => v, coerce=int);
impl_scalar_ops!(I16_DESC, I16Ops, 2, "i16", i16, 2, alloc=alloc_i16, get=get_i16, fmt(v) => v, coerce=int);
impl_scalar_ops!(I32_DESC, I32Ops, 3, "i32", i32, 4, alloc=alloc_i32, get=get_i32, fmt(v) => v, coerce=int);
impl_scalar_ops!(I64_DESC, I64Ops, 4, "i64", i64, 8, alloc=alloc_i64, get=get_i64, fmt(v) => v, coerce=int);
impl_scalar_ops!(U8_DESC, U8Ops, 6, "u8", u8, 1, alloc=alloc_u8, get=get_u8, fmt(v) => v, coerce=int);
impl_scalar_ops!(U16_DESC, U16Ops, 7, "u16", u16, 2, alloc=alloc_u16, get=get_u16, fmt(v) => v, coerce=int);
impl_scalar_ops!(U32_DESC, U32Ops, 8, "u32", u32, 4, alloc=alloc_u32, get=get_u32, fmt(v) => v, coerce=int);
impl_scalar_ops!(U64_DESC, U64Ops, 9, "u64", u64, 8, alloc=alloc_u64, get=get_u64, fmt(v) => v, coerce=int);
impl_scalar_ops!(ISIZE_DESC, IsizeOps, 11, "isize", isize, 8, alloc=alloc_isize, get=get_isize, fmt(v) => v, coerce=int);
impl_scalar_ops!(USIZE_DESC, UsizeOps, 12, "usize", usize, 8, alloc=alloc_usize, get=get_usize, fmt(v) => v, coerce=int);
impl_scalar_ops!(F16_DESC, F16Ops, 13, "f16", u16, 2, alloc=alloc_f16, get=get_f16, fmt(v) => F16(v).to_f32(), coerce=f16);
impl_scalar_ops!(F32_DESC, F32Ops, 14, "f32", f32, 4, alloc=alloc_f32, get=get_f32, fmt(v) => v, coerce=float);
impl_scalar_ops!(F64_DESC, F64Ops, 15, "f64", f64, 8, alloc=alloc_f64, get=get_f64, fmt(v) => v, coerce=float);
impl_scalar_ops!(CHAR_DESC, CharOps, 18, "char", u32, 4, alloc=alloc_char, get=get_char, fmt(v) => Char::from_codepoint_unchecked(v), coerce=char);

// =========================================================================
// 手动实现：i128 / u128 / f128 / bool
// =========================================================================

/// `TypeOps` 实现：i128（16 字节，`ValueArena` 返回 i128）。
pub struct I128Ops;
impl TypeOps for I128Ops {
    #[inline]
    fn read(&self, ptr: *const u8, arena: &mut ValueArena) -> ValueHandle {
        // SAFETY: ptr 指向 16 字节合法 i128。
        let v: i128 = unsafe { std::ptr::read_unaligned(ptr as *const i128) };
        arena.alloc_i128(v)
    }
    #[inline]
    fn write(&self, ptr: *mut u8, h: ValueHandle, arena: &ValueArena) {
        let v: i128 = arena.get_i128(h);
        // SAFETY: ptr 指向可写 16 字节 i128。
        unsafe { std::ptr::write_unaligned(ptr as *mut i128, v) }
    }
    #[inline]
    fn coerce(&self, v: ValueHandle, arena: &mut ValueArena) -> ValueHandle {
        let val: i128 = match v.tag() {
            ValueTag::Bool => arena.get_bool(v) as i128,
            ValueTag::Char => arena.get_char(v) as i128,
            ValueTag::I8 => arena.get_i8(v) as i128,
            ValueTag::I16 => arena.get_i16(v) as i128,
            ValueTag::I32 => arena.get_i32(v) as i128,
            ValueTag::I64 => arena.get_i64(v) as i128,
            ValueTag::I128 => arena.get_i128(v),
            ValueTag::U8 => arena.get_u8(v) as i128,
            ValueTag::U16 => arena.get_u16(v) as i128,
            ValueTag::U32 => arena.get_u32(v) as i128,
            ValueTag::U64 => arena.get_u64(v) as i128,
            ValueTag::U128 => arena.get_u128(v) as i128,
            ValueTag::Isize => arena.get_isize(v) as i128,
            ValueTag::Usize => arena.get_usize(v) as i128,
            ValueTag::F16 => F16(arena.get_f16(v)).to_f32() as i128,
            ValueTag::F32 => arena.get_f32(v) as i128,
            ValueTag::F64 => arena.get_f64(v) as i128,
            ValueTag::F128 => arena.get_f128(v).to_f64() as i128,
            ValueTag::Null | ValueTag::Void | ValueTag::Ref => 0,
        };
        arena.alloc_i128(val)
    }
    #[inline]
    fn equal(&self, a: *const u8, b: *const u8) -> bool {
        // SAFETY: 两指针均指向合法 i128。
        unsafe {
            std::ptr::read_unaligned(a as *const i128)
                == std::ptr::read_unaligned(b as *const i128)
        }
    }
    #[inline]
    fn format<'a>(&self, ptr: *const u8, buf: &'a mut [u8]) -> &'a str {
        // SAFETY: ptr 指向合法 i128。
        let v: i128 = unsafe { std::ptr::read_unaligned(ptr as *const i128) };
        use std::io::Write;
        let mut cursor = std::io::Cursor::new(buf);
        let _ = write!(cursor, "{}", v);
        let written = cursor.position() as usize;
        let buf_ref: &mut [u8] = cursor.into_inner();
        // SAFETY: i128 Display 输出为 ASCII 十进制。
        unsafe { std::str::from_utf8_unchecked(&buf_ref[..written]) }
    }
    #[inline]
    fn hash_val(&self, ptr: *const u8) -> u64 {
        use std::hash::{Hash, Hasher};
        // SAFETY: ptr 指向合法 i128。
        let v: i128 = unsafe { std::ptr::read_unaligned(ptr as *const i128) };
        let mut h = std::collections::hash_map::DefaultHasher::new();
        v.hash(&mut h);
        h.finish()
    }
    #[inline]
    fn clone_val(&self, ptr: *const u8, arena: &mut ValueArena) -> ValueHandle {
        // SAFETY: 标量值语义，clone 等价于 read。
        let v: i128 = unsafe { std::ptr::read_unaligned(ptr as *const i128) };
        arena.alloc_i128(v)
    }
}

/// `TypeOps` 实现：u128（16 字节，`ValueArena` 返回 u128）。
pub struct U128Ops;
impl TypeOps for U128Ops {
    #[inline]
    fn read(&self, ptr: *const u8, arena: &mut ValueArena) -> ValueHandle {
        // SAFETY: ptr 指向 16 字节合法 u128。
        let v: u128 = unsafe { std::ptr::read_unaligned(ptr as *const u128) };
        arena.alloc_u128(v)
    }
    #[inline]
    fn write(&self, ptr: *mut u8, h: ValueHandle, arena: &ValueArena) {
        let v: u128 = arena.get_u128(h);
        // SAFETY: ptr 指向可写 16 字节 u128。
        unsafe { std::ptr::write_unaligned(ptr as *mut u128, v) }
    }
    #[inline]
    fn coerce(&self, v: ValueHandle, arena: &mut ValueArena) -> ValueHandle {
        let val: u128 = match v.tag() {
            ValueTag::Bool => arena.get_bool(v) as u128,
            ValueTag::Char => arena.get_char(v) as u128,
            ValueTag::I8 => arena.get_i8(v) as u128,
            ValueTag::I16 => arena.get_i16(v) as u128,
            ValueTag::I32 => arena.get_i32(v) as u128,
            ValueTag::I64 => arena.get_i64(v) as u128,
            ValueTag::I128 => arena.get_i128(v) as u128,
            ValueTag::U8 => arena.get_u8(v) as u128,
            ValueTag::U16 => arena.get_u16(v) as u128,
            ValueTag::U32 => arena.get_u32(v) as u128,
            ValueTag::U64 => arena.get_u64(v) as u128,
            ValueTag::U128 => arena.get_u128(v),
            ValueTag::Isize => arena.get_isize(v) as u128,
            ValueTag::Usize => arena.get_usize(v) as u128,
            ValueTag::F16 => F16(arena.get_f16(v)).to_f32() as u128,
            ValueTag::F32 => arena.get_f32(v) as u128,
            ValueTag::F64 => arena.get_f64(v) as u128,
            ValueTag::F128 => arena.get_f128(v).to_f64() as u128,
            ValueTag::Null | ValueTag::Void | ValueTag::Ref => 0,
        };
        arena.alloc_u128(val)
    }
    #[inline]
    fn equal(&self, a: *const u8, b: *const u8) -> bool {
        // SAFETY: 两指针均指向合法 u128。
        unsafe {
            std::ptr::read_unaligned(a as *const u128)
                == std::ptr::read_unaligned(b as *const u128)
        }
    }
    #[inline]
    fn format<'a>(&self, ptr: *const u8, buf: &'a mut [u8]) -> &'a str {
        // SAFETY: ptr 指向合法 u128。
        let v: u128 = unsafe { std::ptr::read_unaligned(ptr as *const u128) };
        use std::io::Write;
        let mut cursor = std::io::Cursor::new(buf);
        let _ = write!(cursor, "{}", v);
        let written = cursor.position() as usize;
        let buf_ref: &mut [u8] = cursor.into_inner();
        // SAFETY: u128 Display 输出为 ASCII 十进制。
        unsafe { std::str::from_utf8_unchecked(&buf_ref[..written]) }
    }
    #[inline]
    fn hash_val(&self, ptr: *const u8) -> u64 {
        use std::hash::{Hash, Hasher};
        // SAFETY: ptr 指向合法 u128。
        let v: u128 = unsafe { std::ptr::read_unaligned(ptr as *const u128) };
        let mut h = std::collections::hash_map::DefaultHasher::new();
        v.hash(&mut h);
        h.finish()
    }
    #[inline]
    fn clone_val(&self, ptr: *const u8, arena: &mut ValueArena) -> ValueHandle {
        // SAFETY: 标量值语义，clone 等价于 read。
        let v: u128 = unsafe { std::ptr::read_unaligned(ptr as *const u128) };
        arena.alloc_u128(v)
    }
}

/// `TypeOps` 实现：f128（16 字节，`ValueArena` 返回 `F128`）。
pub struct F128Ops;
impl TypeOps for F128Ops {
    #[inline]
    fn read(&self, ptr: *const u8, arena: &mut ValueArena) -> ValueHandle {
        // SAFETY: ptr 指向 16 字节合法 F128（Copy）。
        let v: F128 = unsafe { std::ptr::read_unaligned(ptr as *const F128) };
        arena.alloc_f128(v)
    }
    #[inline]
    fn write(&self, ptr: *mut u8, h: ValueHandle, arena: &ValueArena) {
        let v: F128 = arena.get_f128(h);
        // SAFETY: ptr 指向可写 16 字节 F128。
        unsafe { std::ptr::write_unaligned(ptr as *mut F128, v) }
    }
    #[inline]
    fn coerce(&self, v: ValueHandle, arena: &mut ValueArena) -> ValueHandle {
        let f: f64 = match v.tag() {
            ValueTag::Bool => arena.get_bool(v) as u8 as f64,
            ValueTag::Char => arena.get_char(v) as u32 as f64,
            ValueTag::I8 => arena.get_i8(v) as f64,
            ValueTag::I16 => arena.get_i16(v) as f64,
            ValueTag::I32 => arena.get_i32(v) as f64,
            ValueTag::I64 => arena.get_i64(v) as f64,
            ValueTag::I128 => arena.get_i128(v) as f64,
            ValueTag::U8 => arena.get_u8(v) as f64,
            ValueTag::U16 => arena.get_u16(v) as f64,
            ValueTag::U32 => arena.get_u32(v) as f64,
            ValueTag::U64 => arena.get_u64(v) as f64,
            ValueTag::U128 => arena.get_u128(v) as f64,
            ValueTag::Isize => arena.get_isize(v) as f64,
            ValueTag::Usize => arena.get_usize(v) as f64,
            ValueTag::F16 => F16(arena.get_f16(v)).to_f32() as f64,
            ValueTag::F32 => arena.get_f32(v) as f64,
            ValueTag::F64 => arena.get_f64(v),
            ValueTag::F128 => arena.get_f128(v).to_f64(),
            ValueTag::Null | ValueTag::Void | ValueTag::Ref => 0.0,
        };
        arena.alloc_f128(F128::from_f64(f))
    }
    #[inline]
    fn equal(&self, a: *const u8, b: *const u8) -> bool {
        // SAFETY: 两指针均指向合法 F128。
        unsafe {
            std::ptr::read_unaligned(a as *const F128)
                == std::ptr::read_unaligned(b as *const F128)
        }
    }
    #[inline]
    fn format<'a>(&self, ptr: *const u8, buf: &'a mut [u8]) -> &'a str {
        // SAFETY: ptr 指向合法 F128。
        let v: F128 = unsafe { std::ptr::read_unaligned(ptr as *const F128) };
        use std::io::Write;
        let mut cursor = std::io::Cursor::new(buf);
        let _ = write!(cursor, "{}", v);
        let written = cursor.position() as usize;
        let buf_ref: &mut [u8] = cursor.into_inner();
        // SAFETY: F128 Display 输出为 ASCII。
        unsafe { std::str::from_utf8_unchecked(&buf_ref[..written]) }
    }
    #[inline]
    fn hash_val(&self, ptr: *const u8) -> u64 {
        use std::hash::{Hash, Hasher};
        // SAFETY: ptr 指向合法 F128。
        let v: F128 = unsafe { std::ptr::read_unaligned(ptr as *const F128) };
        let mut h = std::collections::hash_map::DefaultHasher::new();
        v.hash(&mut h);
        h.finish()
    }
    #[inline]
    fn clone_val(&self, ptr: *const u8, arena: &mut ValueArena) -> ValueHandle {
        // SAFETY: 标量值语义，clone 等价于 read。
        let v: F128 = unsafe { std::ptr::read_unaligned(ptr as *const F128) };
        arena.alloc_f128(v)
    }
}

/// `TypeOps` 实现：bool（`ValueArena::bool` 与 `get_bool` 均为 `&self` 单例语义）。
pub struct BoolOps;
impl TypeOps for BoolOps {
    #[inline]
    fn read(&self, ptr: *const u8, arena: &mut ValueArena) -> ValueHandle {
        // SAFETY: ptr 指向 1 字节合法 bool。
        let v: bool = unsafe { std::ptr::read_unaligned(ptr as *const bool) };
        arena.bool(v)
    }
    #[inline]
    fn write(&self, ptr: *mut u8, h: ValueHandle, arena: &ValueArena) {
        let v: bool = arena.get_bool(h);
        // SAFETY: ptr 指向可写 1 字节 bool。
        unsafe { std::ptr::write_unaligned(ptr as *mut bool, v) }
    }
    #[inline]
    fn coerce(&self, v: ValueHandle, arena: &mut ValueArena) -> ValueHandle {
        let b: bool = match v.tag() {
            ValueTag::Bool => arena.get_bool(v),
            ValueTag::Char => arena.get_char(v) != 0,
            ValueTag::I8 => arena.get_i8(v) != 0,
            ValueTag::I16 => arena.get_i16(v) != 0,
            ValueTag::I32 => arena.get_i32(v) != 0,
            ValueTag::I64 => arena.get_i64(v) != 0,
            ValueTag::I128 => arena.get_i128(v) != 0,
            ValueTag::U8 => arena.get_u8(v) != 0,
            ValueTag::U16 => arena.get_u16(v) != 0,
            ValueTag::U32 => arena.get_u32(v) != 0,
            ValueTag::U64 => arena.get_u64(v) != 0,
            ValueTag::U128 => arena.get_u128(v) != 0,
            ValueTag::Isize => arena.get_isize(v) != 0,
            ValueTag::Usize => arena.get_usize(v) != 0,
            ValueTag::F16 => F16(arena.get_f16(v)).to_f32() != 0.0,
            ValueTag::F32 => arena.get_f32(v) != 0.0,
            ValueTag::F64 => arena.get_f64(v) != 0.0,
            ValueTag::F128 => arena.get_f128(v).to_f64() != 0.0,
            ValueTag::Null | ValueTag::Void | ValueTag::Ref => false,
        };
        arena.bool(b)
    }
    #[inline]
    fn equal(&self, a: *const u8, b: *const u8) -> bool {
        // SAFETY: 两指针均指向合法 bool。
        unsafe {
            std::ptr::read_unaligned(a as *const bool)
                == std::ptr::read_unaligned(b as *const bool)
        }
    }
    #[inline]
    fn format<'a>(&self, ptr: *const u8, buf: &'a mut [u8]) -> &'a str {
        // SAFETY: ptr 指向合法 bool。
        let v: bool = unsafe { std::ptr::read_unaligned(ptr as *const bool) };
        use std::io::Write;
        let mut cursor = std::io::Cursor::new(buf);
        let _ = write!(cursor, "{}", v);
        let written = cursor.position() as usize;
        let buf_ref: &mut [u8] = cursor.into_inner();
        // SAFETY: bool Display 输出为 ASCII（"true"/"false"）。
        unsafe { std::str::from_utf8_unchecked(&buf_ref[..written]) }
    }
    #[inline]
    fn hash_val(&self, ptr: *const u8) -> u64 {
        use std::hash::{Hash, Hasher};
        // SAFETY: ptr 指向合法 bool。
        let v: bool = unsafe { std::ptr::read_unaligned(ptr as *const bool) };
        let mut h = std::collections::hash_map::DefaultHasher::new();
        v.hash(&mut h);
        h.finish()
    }
    #[inline]
    fn clone_val(&self, ptr: *const u8, arena: &mut ValueArena) -> ValueHandle {
        // SAFETY: 标量值语义，clone 等价于 read。
        let v: bool = unsafe { std::ptr::read_unaligned(ptr as *const bool) };
        arena.bool(v)
    }
}

// =========================================================================
// Null / Void ops（简化实现）
// =========================================================================

/// `TypeOps` 实现：null 类型（无数据，单例语义）。
pub struct NullOps;
impl TypeOps for NullOps {
    #[inline]
    fn read(&self, _ptr: *const u8, arena: &mut ValueArena) -> ValueHandle {
        arena.null()
    }
    #[inline]
    fn write(&self, _ptr: *mut u8, _v: ValueHandle, _arena: &ValueArena) {}
    #[inline]
    fn coerce(&self, v: ValueHandle, _arena: &mut ValueArena) -> ValueHandle {
        v
    }
    #[inline]
    fn equal(&self, _a: *const u8, _b: *const u8) -> bool {
        // null 为单例，所有实例相等（同 type_id）。
        true
    }
    #[inline]
    fn format<'a>(&self, _ptr: *const u8, buf: &'a mut [u8]) -> &'a str {
        // SAFETY: "null" 为合法 ASCII。
        buf[..4].copy_from_slice(b"null");
        unsafe { std::str::from_utf8_unchecked(&buf[..4]) }
    }
    #[inline]
    fn hash_val(&self, _ptr: *const u8) -> u64 {
        0
    }
    #[inline]
    fn clone_val(&self, _ptr: *const u8, arena: &mut ValueArena) -> ValueHandle {
        arena.null()
    }
}

/// `TypeOps` 实现：void 类型（无数据，单例语义）。
pub struct VoidOps;
impl TypeOps for VoidOps {
    #[inline]
    fn read(&self, _ptr: *const u8, arena: &mut ValueArena) -> ValueHandle {
        arena.void()
    }
    #[inline]
    fn write(&self, _ptr: *mut u8, _v: ValueHandle, _arena: &ValueArena) {}
    #[inline]
    fn coerce(&self, v: ValueHandle, _arena: &mut ValueArena) -> ValueHandle {
        v
    }
    #[inline]
    fn equal(&self, _a: *const u8, _b: *const u8) -> bool {
        // void 为单例，所有实例相等（同 type_id）。
        true
    }
    #[inline]
    fn format<'a>(&self, _ptr: *const u8, buf: &'a mut [u8]) -> &'a str {
        // SAFETY: "void" 为合法 ASCII。
        buf[..4].copy_from_slice(b"void");
        unsafe { std::str::from_utf8_unchecked(&buf[..4]) }
    }
    #[inline]
    fn hash_val(&self, _ptr: *const u8) -> u64 {
        0
    }
    #[inline]
    fn clone_val(&self, _ptr: *const u8, arena: &mut ValueArena) -> ValueHandle {
        arena.void()
    }
}

// =========================================================================
// ref_ops / heap_ref_ops（引用类型 ops，简化实现）
// =========================================================================
//
// 完整的 ref 实现（msync 检查、ObjHeader 验证、堆对象物化）属于 engine 层职责。
// 共享层仅提供 8 字节指针槽的读写骨架：0 表示 null，非零地址在 read 时返回 null
// （保持无分配语义），write 将句柄索引写入槽位作为占位。

macro_rules! impl_ref_ops {
    ($ops:ident) => {
        pub struct $ops;
        impl TypeOps for $ops {
            #[inline]
            fn read(&self, ptr: *const u8, arena: &mut ValueArena) -> ValueHandle {
                // SAFETY: ptr 指向 8 字节地址槽（0 表示 null）。
                let addr: usize = unsafe { std::ptr::read_unaligned(ptr as *const usize) };
                if addr == 0 {
                    arena.null()
                } else {
                    // 完整 ref 物化需要 engine 层（ObjHeader / msync 校验），
                    // 共享层保持无分配语义，非零地址返回 null。
                    arena.null()
                }
            }
            #[inline]
            fn write(&self, ptr: *mut u8, h: ValueHandle, _arena: &ValueArena) {
                // SAFETY: ptr 指向可写 8 字节地址槽；存储句柄索引作为占位。
                let raw: usize = h.index();
                unsafe { std::ptr::write_unaligned(ptr as *mut usize, raw) }
            }
            #[inline]
            fn coerce(&self, v: ValueHandle, _arena: &mut ValueArena) -> ValueHandle {
                v
            }
            #[inline]
            fn equal(&self, a: *const u8, b: *const u8) -> bool {
                // SAFETY: 两指针均指向 8 字节地址槽。
                unsafe {
                    std::ptr::read_unaligned(a as *const usize)
                        == std::ptr::read_unaligned(b as *const usize)
                }
            }
            #[inline]
            fn format<'a>(&self, ptr: *const u8, buf: &'a mut [u8]) -> &'a str {
                // SAFETY: ptr 指向 8 字节地址。
                let addr: usize = unsafe { std::ptr::read_unaligned(ptr as *const usize) };
                use std::io::Write;
                let mut cursor = std::io::Cursor::new(buf);
                let _ = write!(cursor, "ref:0x{:x}", addr);
                let written = cursor.position() as usize;
                let buf_ref: &mut [u8] = cursor.into_inner();
                // SAFETY: 格式化文本为 ASCII。
                unsafe { std::str::from_utf8_unchecked(&buf_ref[..written]) }
            }
            #[inline]
            fn hash_val(&self, ptr: *const u8) -> u64 {
                // SAFETY: ptr 指向 8 字节地址，按 u64 重解释。
                unsafe { std::ptr::read_unaligned(ptr as *const u64) }
            }
            #[inline]
            fn clone_val(&self, ptr: *const u8, arena: &mut ValueArena) -> ValueHandle {
                self.read(ptr, arena)
            }
        }
    };
}

impl_ref_ops!(RefOps);
impl_ref_ops!(HeapRefOps);

// =========================================================================
// 静态 TypeDescriptor 常量（i128 / u128 / f128 / bool / str / null / void）
// =========================================================================

pub static I128_DESC: TypeDescriptor = TypeDescriptor {
    size: 16,
    ops: &I128Ops,
    type_id: 5,
    type_name: "i128",
};
pub static U128_DESC: TypeDescriptor = TypeDescriptor {
    size: 16,
    ops: &U128Ops,
    type_id: 10,
    type_name: "u128",
};
pub static F128_DESC: TypeDescriptor = TypeDescriptor {
    size: 16,
    ops: &F128Ops,
    type_id: 16,
    type_name: "f128",
};
pub static BOOL_DESC: TypeDescriptor = TypeDescriptor {
    size: 1,
    ops: &BoolOps,
    type_id: 17,
    type_name: "bool",
};
pub static STR_DESC: TypeDescriptor = TypeDescriptor {
    size: 8,
    ops: &HeapRefOps,
    type_id: 19,
    type_name: "str",
};
pub static NULL_DESC: TypeDescriptor = TypeDescriptor {
    size: 0,
    ops: &NullOps,
    type_id: 20,
    type_name: "null",
};
pub static VOID_DESC: TypeDescriptor = TypeDescriptor {
    size: 0,
    ops: &VoidOps,
    type_id: 21,
    type_name: "void",
};

// =========================================================================
// lookup 函数
// =========================================================================

/// 按 `type_id` 查找静态类型描述符（1..=21），未命中返回 `None`。
#[inline]
pub fn lookup_by_type_id(type_id: u16) -> Option<&'static TypeDescriptor> {
    match type_id {
        1 => Some(&I8_DESC),
        2 => Some(&I16_DESC),
        3 => Some(&I32_DESC),
        4 => Some(&I64_DESC),
        5 => Some(&I128_DESC),
        6 => Some(&U8_DESC),
        7 => Some(&U16_DESC),
        8 => Some(&U32_DESC),
        9 => Some(&U64_DESC),
        10 => Some(&U128_DESC),
        11 => Some(&ISIZE_DESC),
        12 => Some(&USIZE_DESC),
        13 => Some(&F16_DESC),
        14 => Some(&F32_DESC),
        15 => Some(&F64_DESC),
        16 => Some(&F128_DESC),
        17 => Some(&BOOL_DESC),
        18 => Some(&CHAR_DESC),
        19 => Some(&STR_DESC),
        20 => Some(&NULL_DESC),
        21 => Some(&VOID_DESC),
        _ => None,
    }
}

/// 按 `IntKind` 查找对应整数类型描述符。
#[inline]
pub fn lookup_by_int_kind(kind: IntKind) -> &'static TypeDescriptor {
    match kind {
        IntKind::I8 => &I8_DESC,
        IntKind::I16 => &I16_DESC,
        IntKind::I32 => &I32_DESC,
        IntKind::I64 => &I64_DESC,
        IntKind::I128 => &I128_DESC,
        IntKind::U8 => &U8_DESC,
        IntKind::U16 => &U16_DESC,
        IntKind::U32 => &U32_DESC,
        IntKind::U64 => &U64_DESC,
        IntKind::U128 => &U128_DESC,
        IntKind::Isize => &ISIZE_DESC,
        IntKind::Usize => &USIZE_DESC,
    }
}

/// 按 `FloatKind` 查找对应浮点类型描述符。
#[inline]
pub fn lookup_by_float_kind(kind: FloatKind) -> &'static TypeDescriptor {
    match kind {
        FloatKind::F16 => &F16_DESC,
        FloatKind::F32 => &F32_DESC,
        FloatKind::F64 => &F64_DESC,
        FloatKind::F128 => &F128_DESC,
    }
}

// =========================================================================
// TypeDescriptorPool（动态池，type_id 22+）
// =========================================================================

/// 动态类型描述符池：管理用户自定义类型（type_id 从 22 开始）。
///
/// `register` 会将类型名与 `TypeDescriptor` 泄漏为 `&'static` 以获得静态生命周期，
/// 适用于进程级类型注册（与 Sema/Ir 的类型表语义一致）。
pub struct TypeDescriptorPool {
    descriptors: Vec<&'static TypeDescriptor>,
    name_to_id: HashMap<String, u16>,
}

impl TypeDescriptorPool {
    #[inline]
    pub fn new() -> Self {
        TypeDescriptorPool {
            descriptors: Vec::new(),
            name_to_id: HashMap::new(),
        }
    }

    /// 注册一个用户类型，返回分配的 `type_id`（从 22 开始递增）。
    pub fn register(&mut self, name: &str, size: u8, ops: &'static dyn TypeOps) -> u16 {
        let type_id = 22 + self.descriptors.len() as u16;
        let name_static: &'static str = Box::leak(name.to_string().into_boxed_str());
        let desc: &'static TypeDescriptor = Box::leak(Box::new(TypeDescriptor {
            size,
            ops,
            type_id,
            type_name: name_static,
        }));
        self.descriptors.push(desc);
        self.name_to_id.insert(name.to_string(), type_id);
        type_id
    }

    /// 按 `type_id` 查找描述符；1..=21 委托给静态表，22+ 查询动态池。
    #[inline]
    pub fn get(&self, type_id: u16) -> Option<&'static TypeDescriptor> {
        if type_id <= 21 {
            return lookup_by_type_id(type_id);
        }
        let idx = (type_id - 22) as usize;
        self.descriptors.get(idx).copied()
    }

    /// 按类型名查找描述符。
    #[inline]
    pub fn get_by_name(&self, name: &str) -> Option<&'static TypeDescriptor> {
        let id = *self.name_to_id.get(name)?;
        self.get(id)
    }
}

impl Default for TypeDescriptorPool {
    #[inline]
    fn default() -> Self {
        Self::new()
    }
}

// =========================================================================
// 测试模块
// =========================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Value::{F128, F16, ValueArena};

    // 通用 roundtrip 辅助宏：alloc -> write -> read -> 比较值。
    macro_rules! roundtrip {
        ($desc:expr, $alloc:ident, $get:ident, $val:expr) => {{
            let mut arena = ValueArena::new();
            let h = arena.$alloc($val);
            let mut buf = [0u8; 32];
            $desc.ops.write(buf.as_mut_ptr(), h, &arena);
            let h2 = $desc.ops.read(buf.as_ptr(), &mut arena);
            assert_eq!(arena.$get(h), arena.$get(h2), "roundtrip mismatch");
        }};
    }

    // ---- 1. 18 种标量 read/write roundtrip ----

    #[test]
    fn scalar_read_write_roundtrip() {
        roundtrip!(&I8_DESC, alloc_i8, get_i8, -42i8);
        roundtrip!(&I16_DESC, alloc_i16, get_i16, -1234i16);
        roundtrip!(&I32_DESC, alloc_i32, get_i32, 100_000i32);
        roundtrip!(&I64_DESC, alloc_i64, get_i64, -9_000_000_000i64);
        roundtrip!(
            &I128_DESC,
            alloc_i128,
            get_i128,
            0x1234_5678_9abc_def0_1111_2222_3333_4444i128
        );
        roundtrip!(&U8_DESC, alloc_u8, get_u8, 200u8);
        roundtrip!(&U16_DESC, alloc_u16, get_u16, 60_000u16);
        roundtrip!(&U32_DESC, alloc_u32, get_u32, 4_000_000_000u32);
        roundtrip!(&U64_DESC, alloc_u64, get_u64, 18_000_000_000u64);
        roundtrip!(
            &U128_DESC,
            alloc_u128,
            get_u128,
            0xffff_ffff_ffff_ffff_ffff_ffff_ffff_ffffu128
        );
        roundtrip!(&ISIZE_DESC, alloc_isize, get_isize, -99isize);
        roundtrip!(&USIZE_DESC, alloc_usize, get_usize, 99usize);
        roundtrip!(&F16_DESC, alloc_f16, get_f16, F16::from_f32(3.5).0);
        roundtrip!(&F32_DESC, alloc_f32, get_f32, 1.25f32);
        roundtrip!(&F64_DESC, alloc_f64, get_f64, 2.5f64);
        roundtrip!(&F128_DESC, alloc_f128, get_f128, F128::from_f64(1.5));
        roundtrip!(&BOOL_DESC, bool, get_bool, true);
        roundtrip!(&BOOL_DESC, bool, get_bool, false);
        roundtrip!(&CHAR_DESC, alloc_char, get_char, 0x4e2du32); // '中'
    }

    // ---- 2. coerce 测试 ----

    #[test]
    fn coerce_int_to_int() {
        let mut arena = ValueArena::new();
        let h = arena.alloc_i32(100);
        let h2 = I64_DESC.ops.coerce(h, &mut arena);
        assert_eq!(arena.get_i64(h2), 100i64);
        // 截断
        let h = arena.alloc_i32(1000);
        let h2 = I8_DESC.ops.coerce(h, &mut arena);
        assert_eq!(arena.get_i8(h2), 1000i32 as i8);
        // i128 目标
        let h = arena.alloc_u64(0xdead_beef_cafe_babe);
        let h2 = I128_DESC.ops.coerce(h, &mut arena);
        assert_eq!(arena.get_i128(h2), 0xdead_beef_cafe_babe_i128);
    }

    #[test]
    fn coerce_float_to_int() {
        let mut arena = ValueArena::new();
        let h = arena.alloc_f64(3.9);
        let h2 = I32_DESC.ops.coerce(h, &mut arena);
        assert_eq!(arena.get_i32(h2), 3i32);
        let h = arena.alloc_f32(-2.7);
        let h2 = I64_DESC.ops.coerce(h, &mut arena);
        assert_eq!(arena.get_i64(h2), -2i64);
        let h = arena.alloc_f64(1e9);
        let h2 = U128_DESC.ops.coerce(h, &mut arena);
        assert_eq!(arena.get_u128(h2), 1_000_000_000u128);
    }

    #[test]
    fn coerce_int_to_float() {
        let mut arena = ValueArena::new();
        let h = arena.alloc_i32(5);
        let h2 = F64_DESC.ops.coerce(h, &mut arena);
        assert_eq!(arena.get_f64(h2), 5.0f64);
        let h = arena.alloc_u64(7);
        let h2 = F32_DESC.ops.coerce(h, &mut arena);
        assert_eq!(arena.get_f32(h2), 7.0f32);
        let h = arena.alloc_i128(-3);
        let h2 = F128_DESC.ops.coerce(h, &mut arena);
        assert_eq!(arena.get_f128(h2).to_f64(), -3.0f64);
    }

    #[test]
    fn coerce_float_to_float() {
        let mut arena = ValueArena::new();
        let h = arena.alloc_f64(2.5);
        let h2 = F32_DESC.ops.coerce(h, &mut arena);
        assert_eq!(arena.get_f32(h2), 2.5f32);
        let h = arena.alloc_f32(1.25);
        let h2 = F64_DESC.ops.coerce(h, &mut arena);
        assert_eq!(arena.get_f64(h2), 1.25f64);
    }

    #[test]
    fn coerce_to_bool_and_char() {
        let mut arena = ValueArena::new();
        let h = arena.alloc_i32(1);
        let r = BOOL_DESC.ops.coerce(h, &mut arena);
        assert!(arena.get_bool(r));
        let h = arena.alloc_i32(0);
        let r = BOOL_DESC.ops.coerce(h, &mut arena);
        assert!(!arena.get_bool(r));
        let h = arena.alloc_f64(0.0);
        let r = BOOL_DESC.ops.coerce(h, &mut arena);
        assert!(!arena.get_bool(r));
        let h = arena.alloc_i32(65);
        let r = CHAR_DESC.ops.coerce(h, &mut arena);
        assert_eq!(arena.get_char(r), 65u32);
        // null/void coerce 到 bool 返回 false
        let h = arena.null();
        let r = BOOL_DESC.ops.coerce(h, &mut arena);
        assert!(!arena.get_bool(r));
    }

    #[test]
    fn coerce_to_f16_f128() {
        let mut arena = ValueArena::new();
        let h = arena.alloc_f32(1.5);
        let h2 = F16_DESC.ops.coerce(h, &mut arena);
        assert_eq!(arena.get_f16(h2), F16::from_f32(1.5).0);
        let h = arena.alloc_f64(2.5);
        let h2 = F128_DESC.ops.coerce(h, &mut arena);
        assert_eq!(arena.get_f128(h2).to_f64(), 2.5f64);
        // bool -> f16
        let h = arena.bool(true);
        let h2 = F16_DESC.ops.coerce(h, &mut arena);
        assert_eq!(F16(arena.get_f16(h2)).to_f32(), 1.0f32);
    }

    // ---- 3. TypeDescriptor 元信息方法 ----

    #[test]
    fn descriptor_meta_methods() {
        assert!(I8_DESC.is_int());
        assert!(I128_DESC.is_int());
        assert!(U8_DESC.is_int());
        assert!(ISIZE_DESC.is_int());
        assert!(!F32_DESC.is_int());
        assert!(F32_DESC.is_float());
        assert!(F128_DESC.is_float());
        assert!(F16_DESC.is_float());
        assert!(!I8_DESC.is_float());
        assert!(!I8_DESC.is_ref());
        assert!(!NULL_DESC.is_ref());
        assert!(!VOID_DESC.is_ref());
        assert!(STR_DESC.is_ref());
        assert!(!STR_DESC.is_nullable());
        assert!(NULL_DESC.is_null_type());
        assert!(!VOID_DESC.is_null_type());
        assert!(VOID_DESC.is_void_type());
        assert!(!NULL_DESC.is_void_type());
        assert_eq!(I8_DESC.to_int_kind(), Some(IntKind::I8));
        assert_eq!(U128_DESC.to_int_kind(), Some(IntKind::U128));
        assert_eq!(ISIZE_DESC.to_int_kind(), Some(IntKind::Isize));
        assert_eq!(I8_DESC.to_float_kind(), None);
        assert_eq!(F32_DESC.to_float_kind(), Some(FloatKind::F32));
        assert_eq!(F32_DESC.to_int_kind(), None);
        assert_eq!(STR_DESC.to_int_kind(), None);
        assert_eq!(STR_DESC.to_float_kind(), None);
        assert_eq!(I8_DESC.elem_width(), 1);
        assert_eq!(I64_DESC.elem_width(), 8);
        assert_eq!(I128_DESC.elem_width(), 16);
        assert_eq!(NULL_DESC.elem_width(), 0);
    }

    // ---- 4. lookup_by_type_id 覆盖 1-21 ----

    #[test]
    fn lookup_by_type_id_all() {
        let names = [
            (1u16, "i8"),
            (2, "i16"),
            (3, "i32"),
            (4, "i64"),
            (5, "i128"),
            (6, "u8"),
            (7, "u16"),
            (8, "u32"),
            (9, "u64"),
            (10, "u128"),
            (11, "isize"),
            (12, "usize"),
            (13, "f16"),
            (14, "f32"),
            (15, "f64"),
            (16, "f128"),
            (17, "bool"),
            (18, "char"),
            (19, "str"),
            (20, "null"),
            (21, "void"),
        ];
        for (id, name) in names {
            let d = lookup_by_type_id(id).expect("missing type_id");
            assert_eq!(d.type_id, id, "type_id mismatch");
            assert_eq!(d.type_name, name, "type_name mismatch");
        }
        assert!(lookup_by_type_id(0).is_none());
        assert!(lookup_by_type_id(22).is_none());
        assert!(lookup_by_type_id(u16::MAX).is_none());
    }

    #[test]
    fn lookup_by_kind() {
        assert_eq!(lookup_by_int_kind(IntKind::I32).type_id, 3);
        assert_eq!(lookup_by_int_kind(IntKind::Usize).type_id, 12);
        assert_eq!(lookup_by_int_kind(IntKind::I128).type_id, 5);
        assert_eq!(lookup_by_float_kind(FloatKind::F64).type_id, 15);
        assert_eq!(lookup_by_float_kind(FloatKind::F128).type_id, 16);
        assert_eq!(lookup_by_float_kind(FloatKind::F16).type_id, 13);
    }

    // ---- 5. TypeDescriptorPool register + get ----

    #[test]
    fn pool_register_and_get() {
        let mut pool = TypeDescriptorPool::new();
        let id = pool.register("nullable<i32>", 4, I32_DESC.ops);
        assert_eq!(id, 22);
        let d = pool.get(id).expect("registered type missing");
        assert_eq!(d.type_id, 22);
        assert_eq!(d.type_name, "nullable<i32>");
        assert_eq!(d.size, 4);
        assert!(d.is_nullable());
        assert!(!d.is_ref(), "nullable 类型不应算作 ref");

        // 按名称查找
        let d2 = pool.get_by_name("nullable<i32>").expect("by-name missing");
        assert_eq!(d2.type_id, 22);

        // 第二次注册：普通用户类型（非 nullable），应算作 ref
        let id2 = pool.register("MyStruct", 16, I64_DESC.ops);
        assert_eq!(id2, 23);
        let d3 = pool.get(23).unwrap();
        assert!(d3.is_ref(), "用户类型(>=22) 应算作 ref");
        assert!(!d3.is_nullable());

        // 静态类型经由 pool.get 查询
        assert_eq!(pool.get(1).unwrap().type_name, "i8");
        assert_eq!(pool.get(19).unwrap().type_name, "str");
        assert!(pool.get(99).is_none());
        assert!(pool.get_by_name("nope").is_none());
    }

    // ---- 6. type_id / type_name 一致性 ----

    #[test]
    fn static_descriptor_consistency() {
        assert_eq!(I8_DESC.type_id, 1);
        assert_eq!(I8_DESC.type_name, "i8");
        assert_eq!(I128_DESC.type_id, 5);
        assert_eq!(U128_DESC.type_id, 10);
        assert_eq!(F128_DESC.type_id, 16);
        assert_eq!(BOOL_DESC.type_id, 17);
        assert_eq!(CHAR_DESC.type_id, 18);
        assert_eq!(STR_DESC.type_id, 19);
        assert_eq!(NULL_DESC.type_id, 20);
        assert_eq!(VOID_DESC.type_id, 21);
        assert_eq!(I8_DESC.type_name, "i8");
        assert_eq!(STR_DESC.type_name, "str");
        assert_eq!(NULL_DESC.type_name, "null");
        assert_eq!(VOID_DESC.type_name, "void");
    }

    // ---- 额外：null / void / ref ops 行为 ----

    #[test]
    fn null_void_ref_ops_behavior() {
        let mut arena = ValueArena::new();

        // null / void format
        let mut buf = [0u8; 16];
        let s = NULL_DESC.ops.format(std::ptr::null(), &mut buf);
        assert_eq!(s, "null");
        let s = VOID_DESC.ops.format(std::ptr::null(), &mut buf);
        assert_eq!(s, "void");

        // null read / clone
        let h = NULL_DESC.ops.read(std::ptr::null(), &mut arena);
        assert_eq!(h, arena.null());
        let h = VOID_DESC.ops.clone_val(std::ptr::null(), &mut arena);
        assert_eq!(h, arena.void());

        // null coerce identity
        let n = arena.null();
        assert_eq!(NULL_DESC.ops.coerce(n, &mut arena), n);

        // ref ops write / read / equal / format
        let mut buf_a = [0u8; 8];
        let mut buf_b = [0u8; 8];
        let h1 = arena.alloc_i32(7);
        STR_DESC.ops.write(buf_a.as_mut_ptr(), h1, &arena);
        STR_DESC.ops.write(buf_b.as_mut_ptr(), h1, &arena);
        assert!(STR_DESC.ops.equal(buf_a.as_ptr(), buf_b.as_ptr()));
        // read 非零地址返回 null（共享层无分配语义）
        assert_eq!(STR_DESC.ops.read(buf_a.as_ptr(), &mut arena), arena.null());
        let mut fbuf = [0u8; 32];
        let s = STR_DESC.ops.format(buf_a.as_ptr(), &mut fbuf);
        assert!(s.starts_with("ref:0x"), "format = {}", s);
        // hash 为 8 字节 as u64
        let _ = STR_DESC.ops.hash_val(buf_a.as_ptr());
    }

    #[test]
    fn scalar_format_and_hash_smoke() {
        let mut arena = ValueArena::new();
        let mut buf = [0u8; 64];

        // i32 format
        let h = arena.alloc_i32(42);
        let mut mem = [0u8; 4];
        I32_DESC.ops.write(mem.as_mut_ptr(), h, &arena);
        let s = I32_DESC.ops.format(mem.as_ptr(), &mut buf);
        assert_eq!(s, "42");

        // bool format
        let h = arena.bool(true);
        let mut mem = [0u8; 1];
        BOOL_DESC.ops.write(mem.as_mut_ptr(), h, &arena);
        let s = BOOL_DESC.ops.format(mem.as_ptr(), &mut buf);
        assert_eq!(s, "true");

        // char format（'A' = 65）
        let h = arena.alloc_char(65);
        let mut mem = [0u8; 4];
        CHAR_DESC.ops.write(mem.as_mut_ptr(), h, &arena);
        let s = CHAR_DESC.ops.format(mem.as_ptr(), &mut buf);
        assert_eq!(s, "A");

        // equal
        let mut a = [0u8; 4];
        let mut b = [0u8; 4];
        I32_DESC.ops.write(a.as_mut_ptr(), arena.alloc_i32(7), &arena);
        I32_DESC.ops.write(b.as_mut_ptr(), arena.alloc_i32(7), &arena);
        assert!(I32_DESC.ops.equal(a.as_ptr(), b.as_ptr()));
        I32_DESC.ops.write(b.as_mut_ptr(), arena.alloc_i32(8), &arena);
        assert!(!I32_DESC.ops.equal(a.as_ptr(), b.as_ptr()));

        // hash_val 与 clone_val
        let _ = I32_DESC.ops.hash_val(a.as_ptr());
        let h2 = I32_DESC.ops.clone_val(a.as_ptr(), &mut arena);
        assert_eq!(arena.get_i32(h2), 7);
    }
}
