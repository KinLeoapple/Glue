//! Type.rs — Glue 类型系统判别与元信息单一真相源
//!
//! 承载所有内置类型（18 标量 + str/null/void = 21 个）的静态属性、
//! 统一语义层枚举 `Ty`、以及类型家族分类 `TypeFamily`。
//!
//! 所有模块的类型名映射、大小/对齐查表、类型族分发应派生自此模块，
//! 避免在别处硬编码类型名字面量或重复维护映射表。
//!
//! 新增内置类型只需在 BUILTIN_TABLE 追加一行；新增类型族只需在
//! TypeFamily 与 Ty::family() 各加一个变体。

#![allow(dead_code)] // Ty/TypeFamily/BUILTIN_TABLE 此阶段尚未被调用方使用

// =========================================================================
// 第一部分：类型判别标签（从 Value.rs 移入）
// =========================================================================

// ---- ValueTag — 21 种类型标签（含 Null/Void/Ref，用于 ValueHandle 编码）----

/// 类型标签：涵盖标量、Null/Void/Ref 共 21 种。
/// `#[repr(u8)]` 保证 ABI 稳定（ValueHandle 高 8 位存储此 tag）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum ValueTag {
    Null = 0,
    Void = 1,
    Bool = 2,
    Char = 3,
    I8 = 4,
    I16 = 5,
    I32 = 6,
    I64 = 7,
    U8 = 8,
    U16 = 9,
    U32 = 10,
    U64 = 11,
    Isize = 12,
    Usize = 13,
    I128 = 14,
    U128 = 15,
    F16 = 16,
    F32 = 17,
    F64 = 18,
    F128 = 19,
    Ref = 20,
}

impl ValueTag {
    pub fn is_scalar(self) -> bool {
        !matches!(self, ValueTag::Null | ValueTag::Void | ValueTag::Ref)
    }
}

impl ValueTag {
    pub fn byte_width(self) -> usize {
        match self {
            ValueTag::Bool | ValueTag::I8 | ValueTag::U8 => 1,
            ValueTag::I16 | ValueTag::U16 | ValueTag::F16 => 2,
            ValueTag::Char | ValueTag::I32 | ValueTag::U32 | ValueTag::F32 => 4,
            ValueTag::I64 | ValueTag::U64 | ValueTag::Isize | ValueTag::Usize | ValueTag::F64 => 8,
            ValueTag::I128 | ValueTag::U128 | ValueTag::F128 => 16,
            _ => 0,
        }
    }

    pub fn is_int(self) -> bool {
        matches!(
            self,
            ValueTag::I8 | ValueTag::I16 | ValueTag::I32 | ValueTag::I64 | ValueTag::I128
                | ValueTag::U8 | ValueTag::U16 | ValueTag::U32 | ValueTag::U64 | ValueTag::U128
                | ValueTag::Isize | ValueTag::Usize
        )
    }

    pub fn is_float(self) -> bool {
        matches!(self, ValueTag::F16 | ValueTag::F32 | ValueTag::F64 | ValueTag::F128)
    }

    pub fn is_signed(self) -> bool {
        matches!(
            self,
            ValueTag::I8 | ValueTag::I16 | ValueTag::I32 | ValueTag::I64 | ValueTag::I128 | ValueTag::Isize
        )
    }

    pub fn is_bool(self) -> bool {
        matches!(self, ValueTag::Bool)
    }

    pub fn is_char(self) -> bool {
        matches!(self, ValueTag::Char)
    }

    pub fn is_numeric(self) -> bool {
        self.is_int() || self.is_float()
    }

    pub fn name(self) -> &'static str {
        match self {
            ValueTag::Bool => "bool",
            ValueTag::Char => "char",
            ValueTag::I8 => "i8",
            ValueTag::I16 => "i16",
            ValueTag::I32 => "i32",
            ValueTag::I64 => "i64",
            ValueTag::I128 => "i128",
            ValueTag::U8 => "u8",
            ValueTag::U16 => "u16",
            ValueTag::U32 => "u32",
            ValueTag::U64 => "u64",
            ValueTag::U128 => "u128",
            ValueTag::Isize => "isize",
            ValueTag::Usize => "usize",
            ValueTag::F16 => "f16",
            ValueTag::F32 => "f32",
            ValueTag::F64 => "f64",
            ValueTag::F128 => "f128",
            _ => "unknown",
        }
    }

    pub fn all() -> &'static [ValueTag] {
        &[
            ValueTag::Bool, ValueTag::Char, ValueTag::I8, ValueTag::I16, ValueTag::I32,
            ValueTag::I64, ValueTag::I128, ValueTag::U8, ValueTag::U16, ValueTag::U32,
            ValueTag::U64, ValueTag::U128, ValueTag::Isize, ValueTag::Usize, ValueTag::F16,
            ValueTag::F32, ValueTag::F64, ValueTag::F128,
        ]
    }

    pub fn from_name(name: &str) -> Option<ValueTag> {
        for tag in Self::all() {
            if tag.name() == name {
                return Some(*tag);
            }
        }
        None
    }
}

// ---- ScalarTag — 18 种标量标签（用于 ScalarValue union 类型守卫）----

/// 标量类型标签（18 种，用于 ScalarValue union 的类型守卫）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum ScalarTag {
    Bool, Char,
    I8, I16, I32, I64, I128,
    U8, U16, U32, U64, U128,
    Isize, Usize,
    F16, F32, F64, F128,
}

impl ScalarTag {
    pub fn type_name(self) -> &'static str {
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

    /// 全部 18 种标量标签（与 `type_name` 单点同步）。
    pub fn all() -> &'static [ScalarTag] {
        &[
            ScalarTag::Bool, ScalarTag::Char,
            ScalarTag::I8, ScalarTag::I16, ScalarTag::I32, ScalarTag::I64, ScalarTag::I128,
            ScalarTag::U8, ScalarTag::U16, ScalarTag::U32, ScalarTag::U64, ScalarTag::U128,
            ScalarTag::Isize, ScalarTag::Usize,
            ScalarTag::F16, ScalarTag::F32, ScalarTag::F64, ScalarTag::F128,
        ]
    }

    /// 类型名 → ScalarTag（反向查找，与 `type_name` 单点同步）。
    pub fn from_name(name: &str) -> Option<ScalarTag> {
        for tag in Self::all() {
            if tag.type_name() == name {
                return Some(*tag);
            }
        }
        None
    }

    /// 字节宽度（与 ValueTag::byte_width 单点同步）。
    #[inline]
    pub fn byte_width(self) -> u8 {
        match self {
            ScalarTag::Bool | ScalarTag::I8 | ScalarTag::U8 => 1,
            ScalarTag::I16 | ScalarTag::U16 | ScalarTag::F16 => 2,
            ScalarTag::Char | ScalarTag::I32 | ScalarTag::U32 | ScalarTag::F32 => 4,
            ScalarTag::I64 | ScalarTag::U64 | ScalarTag::Isize | ScalarTag::Usize | ScalarTag::F64 => 8,
            ScalarTag::I128 | ScalarTag::U128 | ScalarTag::F128 => 16,
        }
    }
}

// =========================================================================
// 第二部分：TypeHandle — 类型 arena 句柄（从 sema/Sema.rs 移入）
// =========================================================================

/// 类型 arena 句柄（u32 索引到 TypeArena）。
/// 放在 Type.rs 以打破 Type↔sema 循环依赖。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TypeHandle(pub u32);

// =========================================================================
// 第三部分：TypeFamily — 所有类型的家族分类（替代字符串 family）
// =========================================================================

/// 所有 Glue 类型的家族分类。
///
/// 替代现有碎片化判断：
/// - Ir.rs 的 family: &'static str（仅标量，"i32"/"i64"/"i128"/"float"/"bool"）
/// - Ir.rs 的 ty_name == "str"（名字特判）
/// - Ir.rs 的 starts_with("Channel")（前缀匹配）
/// - Inference.rs 的 name == "Throw"（名字特判）
///
/// 调用方通过 ty.family() 一次 match 完成所有分派。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TypeFamily {
    // ── 有符号整数（区分位宽，因 opcode 按位宽分派）──
    /// 8/16/32 位有符号整数（i8/i16/i32）
    SignedInt32,
    /// 64 位有符号整数（i64/isize）
    SignedInt64,
    /// 128 位有符号整数（i128）
    SignedInt128,

    // ── 无符号整数（除法/移位/比较需区分符号性）──
    /// 8/16/32 位无符号整数（u8/u16/u32）
    UnsignedInt32,
    /// 64 位无符号整数（u64/usize）
    UnsignedInt64,
    /// 128 位无符号整数（u128）
    UnsignedInt128,

    // ── 浮点（f16/f32/f64/f128 统一 f64 运算）──
    Float,

    // ── 非数值标量 ──
    Bool,
    Char,

    // ── 非标量内置 ──
    Str, Null, Void,

    // ── 内置泛型（替代 starts_with/名字特判）──
    /// Throw<V, E>（is_ok 分派）
    Throw,
    /// Channel<T>（send/recv/close 分派）
    Channel,
    /// Async<T>（await 分派）
    Async,
    /// Lazy<T>
    Lazy,
    /// Atomic<T>（swap/cas/load/store 分派）
    Atomic,
    /// Sender<T>
    Sender,
    /// Receiver<T>
    Receiver,

    // ── 复合 ──
    Array, Ref, Fn, Nullable, Trait,

    // ── 用户类型 ──
    Adt,

    // ── 特殊 ──
    Never, TypeVar, Unknown,
}

// =========================================================================
// 第四部分：Ty — 统一类型枚举
// =========================================================================

/// Glue 语义层统一类型表示。
///
/// 所有内置类型有独立变体（编译器穷尽检查），用户自定义类型通过 Adt
/// 引用 TypeArena。调用方通过 family() 区分类型族，通过 is_scalar()
/// 等便捷方法判断类别。
///
/// 注意：因含 `Box<[TypeHandle]>` / `Box<str>` 字段，未 derive `Copy`。
/// 标量变体（无 Box）可手动 `clone()`；复合变体克隆会分配堆内存。
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Ty {
    // ── 18 个标量 ──
    Bool, Char,
    I8, I16, I32, I64, I128,
    U8, U16, U32, U64, U128,
    Isize, Usize,
    F16, F32, F64, F128,

    // ── 非标量内置（3 个）──
    Str,    // fat pointer
    Null,   // 无值
    Void,   // 无类型

    // ── 内置泛型（7 个，携带 TypeHandle 参数）──
    /// Throw<V, E>
    Throw { value: TypeHandle, error: TypeHandle },
    /// Channel<T>
    Channel { elem: TypeHandle },
    /// Async<T>
    Async { value: TypeHandle },
    /// Lazy<T>
    Lazy { value: TypeHandle },
    /// Atomic<T>
    Atomic { elem: TypeHandle },
    /// Sender<T>
    Sender { elem: TypeHandle },
    /// Receiver<T>
    Receiver { elem: TypeHandle },

    // ── 复合类型 ──
    /// 数组 [T; N]，size == None 为切片
    Array { elem: TypeHandle, size: Option<u64> },
    /// 引用 &T（is_raw=false）/ 裸指针 *T（is_raw=true）
    Ref { inner: TypeHandle, is_raw: bool },
    /// 函数 (P1, P2) -> R
    Fn { params: Box<[TypeHandle]>, return_type: TypeHandle },
    /// 可空 T?
    Nullable { inner: TypeHandle },
    /// trait 类型 Ord<T>
    Trait { name: Box<str>, args: Box<[TypeHandle]> },

    // ── 用户自定义类型 ──
    /// Adt（代数数据类型），name + type_args
    Adt { name: Box<str>, args: Box<[TypeHandle]> },

    // ── 特殊 ──
    /// 发散类型（return/throw 早退路径，与任意类型统一为对方）
    Never,
    /// 类型变量（推断中，载荷为 TypeArena::type_vars 下标）
    TypeVar(u32),
    /// 未知类型
    Unknown,
}

impl Ty {
    /// 所有类型的家族分类（一次调用完成全部分派判断）。
    pub fn family(&self) -> TypeFamily {
        match self {
            // 有符号整数
            Ty::I8 | Ty::I16 | Ty::I32 => TypeFamily::SignedInt32,
            Ty::I64 | Ty::Isize => TypeFamily::SignedInt64,
            Ty::I128 => TypeFamily::SignedInt128,
            // 无符号整数
            Ty::U8 | Ty::U16 | Ty::U32 => TypeFamily::UnsignedInt32,
            Ty::U64 | Ty::Usize => TypeFamily::UnsignedInt64,
            Ty::U128 => TypeFamily::UnsignedInt128,
            // 浮点
            Ty::F16 | Ty::F32 | Ty::F64 | Ty::F128 => TypeFamily::Float,
            // 非数值标量
            Ty::Bool => TypeFamily::Bool,
            Ty::Char => TypeFamily::Char,
            // 非标量内置
            Ty::Str => TypeFamily::Str,
            Ty::Null => TypeFamily::Null,
            Ty::Void => TypeFamily::Void,
            // 内置泛型
            Ty::Throw { .. } => TypeFamily::Throw,
            Ty::Channel { .. } => TypeFamily::Channel,
            Ty::Async { .. } => TypeFamily::Async,
            Ty::Lazy { .. } => TypeFamily::Lazy,
            Ty::Atomic { .. } => TypeFamily::Atomic,
            Ty::Sender { .. } => TypeFamily::Sender,
            Ty::Receiver { .. } => TypeFamily::Receiver,
            // 复合
            Ty::Array { .. } => TypeFamily::Array,
            Ty::Ref { .. } => TypeFamily::Ref,
            Ty::Fn { .. } => TypeFamily::Fn,
            Ty::Nullable { .. } => TypeFamily::Nullable,
            Ty::Trait { .. } => TypeFamily::Trait,
            // 用户类型
            Ty::Adt { .. } => TypeFamily::Adt,
            // 特殊
            Ty::Never => TypeFamily::Never,
            Ty::TypeVar(_) => TypeFamily::TypeVar,
            Ty::Unknown => TypeFamily::Unknown,
        }
    }

    // ── 便捷判断方法（全部派生自 family）──

    pub fn is_signed_int(&self) -> bool {
        matches!(self.family(),
            TypeFamily::SignedInt32 | TypeFamily::SignedInt64 | TypeFamily::SignedInt128)
    }
    pub fn is_unsigned_int(&self) -> bool {
        matches!(self.family(),
            TypeFamily::UnsignedInt32 | TypeFamily::UnsignedInt64 | TypeFamily::UnsignedInt128)
    }
    pub fn is_int(&self) -> bool { self.is_signed_int() || self.is_unsigned_int() }
    pub fn is_float(&self) -> bool { matches!(self.family(), TypeFamily::Float) }
    pub fn is_numeric(&self) -> bool { self.is_int() || self.is_float() }
    pub fn is_scalar(&self) -> bool {
        self.is_numeric() || matches!(self.family(), TypeFamily::Bool | TypeFamily::Char)
    }
    pub fn is_builtin_generic(&self) -> bool {
        matches!(self.family(),
            TypeFamily::Throw | TypeFamily::Channel | TypeFamily::Async
            | TypeFamily::Lazy | TypeFamily::Atomic | TypeFamily::Sender | TypeFamily::Receiver)
    }
    pub fn is_builtin(&self) -> bool {
        self.is_scalar() || matches!(self.family(),
            TypeFamily::Str | TypeFamily::Null | TypeFamily::Void) || self.is_builtin_generic()
    }

    // ── 元信息方法（派生自 BUILTIN_TABLE）──

    /// 类型名（标量返回 "i32"，Adt 返回 name，内置泛型返回 "Channel" 等）
    pub fn name(&self) -> &str {
        match self {
            Ty::I8 => "i8", Ty::I16 => "i16", Ty::I32 => "i32", Ty::I64 => "i64", Ty::I128 => "i128",
            Ty::U8 => "u8", Ty::U16 => "u16", Ty::U32 => "u32", Ty::U64 => "u64", Ty::U128 => "u128",
            Ty::Isize => "isize", Ty::Usize => "usize",
            Ty::F16 => "f16", Ty::F32 => "f32", Ty::F64 => "f64", Ty::F128 => "f128",
            Ty::Bool => "bool", Ty::Char => "char",
            Ty::Str => "str", Ty::Null => "null", Ty::Void => "void",
            Ty::Throw { .. } => "Throw",
            Ty::Channel { .. } => "Channel",
            Ty::Async { .. } => "Async",
            Ty::Lazy { .. } => "Lazy",
            Ty::Atomic { .. } => "Atomic",
            Ty::Sender { .. } => "Sender",
            Ty::Receiver { .. } => "Receiver",
            Ty::Array { .. } => "array",
            Ty::Adt { name, .. } => name,
            Ty::Trait { name, .. } => name,
            Ty::Ref { .. } => "ref",
            Ty::Fn { .. } => "fn",
            Ty::Nullable { .. } => "nullable",
            Ty::Never => "never",
            Ty::TypeVar(_) => "_",
            Ty::Unknown => "unknown",
        }
    }

    /// type_id（仅内置标量 + str/null/void 有，其他返回 None）
    pub fn type_id(&self) -> Option<u16> {
        match self {
            Ty::I8 => Some(1), Ty::I16 => Some(2), Ty::I32 => Some(3), Ty::I64 => Some(4), Ty::I128 => Some(5),
            Ty::U8 => Some(6), Ty::U16 => Some(7), Ty::U32 => Some(8), Ty::U64 => Some(9), Ty::U128 => Some(10),
            Ty::Isize => Some(11), Ty::Usize => Some(12),
            Ty::F16 => Some(13), Ty::F32 => Some(14), Ty::F64 => Some(15), Ty::F128 => Some(16),
            Ty::Bool => Some(17), Ty::Char => Some(18),
            Ty::Str => Some(19), Ty::Null => Some(20), Ty::Void => Some(21),
            _ => None,
        }
    }

    /// 字节大小（标量: 1/2/4/8/16；str: 8；null/void: 0；复合: None）
    pub fn byte_width(&self) -> Option<u8> {
        self.type_id().and_then(|id| builtin_info_by_type_id(id)).map(|i| i.byte_width)
    }

    /// 转为运行时 ValueTag（用于 ValueHandle 编码，内部使用）
    pub fn to_value_tag(&self) -> ValueTag {
        match self {
            Ty::Bool => ValueTag::Bool,
            Ty::Char => ValueTag::Char,
            Ty::I8 => ValueTag::I8, Ty::I16 => ValueTag::I16, Ty::I32 => ValueTag::I32,
            Ty::I64 => ValueTag::I64, Ty::I128 => ValueTag::I128,
            Ty::U8 => ValueTag::U8, Ty::U16 => ValueTag::U16, Ty::U32 => ValueTag::U32,
            Ty::U64 => ValueTag::U64, Ty::U128 => ValueTag::U128,
            Ty::Isize => ValueTag::Isize, Ty::Usize => ValueTag::Usize,
            Ty::F16 => ValueTag::F16, Ty::F32 => ValueTag::F32,
            Ty::F64 => ValueTag::F64, Ty::F128 => ValueTag::F128,
            Ty::Str => ValueTag::Ref,
            Ty::Null => ValueTag::Null,
            Ty::Void => ValueTag::Void,
            _ => ValueTag::Ref, // 复合类型运行时都是 Ref
        }
    }
}

// =========================================================================
// 第五部分：BUILTIN_TABLE — 内置类型元信息单一真相源
// =========================================================================

/// 内置类型元信息（仅标量 + str/null/void）。
#[derive(Debug, Clone, Copy)]
pub struct BuiltinInfo {
    /// 类型名（如 "i32"），所有派生函数的唯一键
    pub name: &'static str,
    /// 对应的 ValueTag（运行时编码）
    pub value_tag: ValueTag,
    /// TypeDesc 层 type_id（1..=21 内置范围）
    pub type_id: u16,
    /// 字节大小（标量: 1/2/4/8/16；str: 8；null/void: 0）
    pub byte_width: u8,
    /// 字节对齐（标量: == byte_width；str: 8；null/void: 1）
    pub align: u8,
}

/// 21 个内置类型的元信息表，按 type_id 升序排列。
///
/// **新增内置类型时，只需在此表追加一行**。全库派生设施自动同步：
/// - Ty::type_id() / Ty::byte_width() / Ty::to_value_tag()
/// - TypeDesc::lookup_by_type_id
/// - Reflect::__reflect_type_name / __reflect_layout_*
/// - Sema::int_kind_from_name / float_kind_from_name
pub const BUILTIN_TABLE: &[BuiltinInfo] = &[
    // ---- 整数（1..=12）----
    BuiltinInfo { name: "i8",    value_tag: ValueTag::I8,    type_id: 1,  byte_width: 1,  align: 1  },
    BuiltinInfo { name: "i16",   value_tag: ValueTag::I16,   type_id: 2,  byte_width: 2,  align: 2  },
    BuiltinInfo { name: "i32",   value_tag: ValueTag::I32,   type_id: 3,  byte_width: 4,  align: 4  },
    BuiltinInfo { name: "i64",   value_tag: ValueTag::I64,   type_id: 4,  byte_width: 8,  align: 8  },
    BuiltinInfo { name: "i128",  value_tag: ValueTag::I128,  type_id: 5,  byte_width: 16, align: 16 },
    BuiltinInfo { name: "u8",    value_tag: ValueTag::U8,    type_id: 6,  byte_width: 1,  align: 1  },
    BuiltinInfo { name: "u16",   value_tag: ValueTag::U16,   type_id: 7,  byte_width: 2,  align: 2  },
    BuiltinInfo { name: "u32",   value_tag: ValueTag::U32,   type_id: 8,  byte_width: 4,  align: 4  },
    BuiltinInfo { name: "u64",   value_tag: ValueTag::U64,   type_id: 9,  byte_width: 8,  align: 8  },
    BuiltinInfo { name: "u128",  value_tag: ValueTag::U128,  type_id: 10, byte_width: 16, align: 16 },
    BuiltinInfo { name: "isize", value_tag: ValueTag::Isize, type_id: 11, byte_width: 8,  align: 8  },
    BuiltinInfo { name: "usize", value_tag: ValueTag::Usize, type_id: 12, byte_width: 8,  align: 8  },
    // ---- 浮点（13..=16）----
    BuiltinInfo { name: "f16",   value_tag: ValueTag::F16,   type_id: 13, byte_width: 2,  align: 2  },
    BuiltinInfo { name: "f32",   value_tag: ValueTag::F32,   type_id: 14, byte_width: 4,  align: 4  },
    BuiltinInfo { name: "f64",   value_tag: ValueTag::F64,   type_id: 15, byte_width: 8,  align: 8  },
    BuiltinInfo { name: "f128",  value_tag: ValueTag::F128,  type_id: 16, byte_width: 16, align: 16 },
    // ---- 非算术标量（17..=18）----
    BuiltinInfo { name: "bool",  value_tag: ValueTag::Bool,  type_id: 17, byte_width: 1,  align: 1  },
    BuiltinInfo { name: "char",  value_tag: ValueTag::Char,  type_id: 18, byte_width: 4,  align: 4  },
    // ---- 非标量内置（19..=21）----
    BuiltinInfo { name: "str",   value_tag: ValueTag::Ref,   type_id: 19, byte_width: 8,  align: 8  },
    BuiltinInfo { name: "null",  value_tag: ValueTag::Null,  type_id: 20, byte_width: 0,  align: 1  },
    BuiltinInfo { name: "void",  value_tag: ValueTag::Void,  type_id: 21, byte_width: 0,  align: 1  },
];

// =========================================================================
// 第六部分：查找函数
// =========================================================================

/// 按 name 查 BuiltinInfo。
#[inline]
pub fn builtin_info_by_name(name: &str) -> Option<&'static BuiltinInfo> {
    BUILTIN_TABLE.iter().find(|s| s.name == name)
}

/// 按 ValueTag 查 BuiltinInfo。
#[inline]
pub fn builtin_info_by_tag(tag: ValueTag) -> Option<&'static BuiltinInfo> {
    BUILTIN_TABLE.iter().find(|s| s.value_tag == tag)
}

/// 按 type_id 查 BuiltinInfo。
#[inline]
pub fn builtin_info_by_type_id(type_id: u16) -> Option<&'static BuiltinInfo> {
    BUILTIN_TABLE.iter().find(|s| s.type_id == type_id)
}

// =========================================================================
// 第七部分：编译期断言（保护表完整性）
// =========================================================================

const _: () = {
    assert!(BUILTIN_TABLE.len() == 21, "BUILTIN_TABLE must have 21 entries");
    // type_id 唯一性检查
    let mut seen = [false; 22];
    let mut i = 0;
    while i < BUILTIN_TABLE.len() {
        let id = BUILTIN_TABLE[i].type_id as usize;
        assert!(!seen[id], "duplicate type_id in BUILTIN_TABLE");
        seen[id] = true;
        i += 1;
    }
};
