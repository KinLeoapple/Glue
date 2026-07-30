//! Sema.rs — 语义分析核心数据结构
//!
//! 对 `src/sema/concrete_type.zig` + `src/sema/sema_output.zig` 的 Rust 移植。
//! 移植原则：不照抄、不直译，按 Rust 习惯重写。
//!
//! 关键设计抉择（与 Zig 原版的差异）：
//! - **arena + 索引**替代裸指针：`ConcreteType` 中的递归子类型用 `TypeHandle(u32)`
//!   索引指向 `TypeArena` 内的 `Vec`，而非 `*ConcreteType` 指针。这与项目既定的
//!   DOD（`ValueHandle`）一致，且天然规避了自引用生命周期问题。`unify`/`occurs`/
//!   `resolve` 因此成为 `TypeArena` 的方法（需要 `&self` / `&mut self` 访问子节点）。
//! - **`TypeVar` 身份 = 其在 `type_vars` 中的下标**：枚举载荷 `TypeVar(u32)` 直接
//!   存放下标，既是身份也是访问句柄，省去 Zig 中的全局 `next_id` 计数器。
//! - **`Box<str>` / `Box<[...]>`** 替代 arena 分配的 `[]const u8` / 切片：复合类型
//!   持有自身数据，`SemaResult` 无需额外 `owned_arena` 字段，所有权清晰。
//! - **`Result<(), UnifyError>`** 替代 Zig error union；`ConcreteEnv` 改为
//!   `EnvArena` + `EnvId` 索引（DOD，可共享父环境，无 `Rc`/`RefCell`）。
//!
//! 依赖关系：单向依赖 `crate::TypeDesc`（`TypeDescriptor` / `TypeDescriptorPool`）
//! 与 `crate::Ast`（`TypeRef`，仅 `CtorDefInfo` 的 GADT 回溯字段引用）。

use crate::Ast::{
    AstArena, BinaryOp, Decl, Expr, ExprId, InterpolationPart, LambdaBody, MethodDecl, Module,
    Param, Pattern, PatternId, PatternLiteral, PatternRef, SelectArm, Spanned, Stmt, StmtId,
    TypeNode, TypeParam, TypeRef as AstTypeRef,
};
use crate::TypeDesc::{
    lookup_by_type_id, FloatKind, IntKind, RefOps, STR_DESC, TypeDescriptor, TypeDescriptorPool,
    BOOL_DESC, CHAR_DESC, F64_DESC, I32_DESC, NULL_DESC, VOID_DESC,
};
use std::collections::HashMap;
use std::fmt;

// =========================================================================
// TypeHandle — ConcreteType 在 TypeArena 中的索引句柄
// =========================================================================

/// `ConcreteType` 在 `TypeArena::types` 中的索引。newtype 保证类型安全，
/// 避免与普通 `u32` 或 `Ast::TypeId` 混淆。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TypeHandle(pub u32);

// =========================================================================
// TypeVar — 局部推断用的类型变量（非 HM 量化）
// =========================================================================

/// 类型变量：用于局部推断（null 字面量、未标注 lambda 参数等）。
///
/// `bound` 为统一后的绑定目标（指向 `TypeArena` 中的某个 `TypeHandle`）；
/// `is_rigid` 为 true 表示泛型参数声明的刚性变量，不可与不同类型统一。
/// 变量身份由其在 `TypeArena::type_vars` 中的下标决定（即 `ConcreteType::TypeVar(u32)`
/// 载荷），因此本结构不再持有 `id` 字段。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TypeVar {
    pub bound: Option<TypeHandle>,
    pub is_rigid: bool,
}

impl TypeVar {
    #[inline]
    pub fn new(is_rigid: bool) -> Self {
        TypeVar {
            bound: None,
            is_rigid,
        }
    }
}

// =========================================================================
// FieldType — record 字段
// =========================================================================

/// record 字段：`name == None` 表示位置字段。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FieldType {
    pub name: Option<Box<str>>,
    pub ty: TypeHandle,
}

// =========================================================================
// ConcreteType — 统一类型表示
// =========================================================================

/// 统一类型表示：替代旧 HM Type 系统。保留 `type_var`/`unify`/`occurs`/`resolve`
/// 用于局部推断，废弃 generalize/instantiate/TypeScheme（泛型显式声明，无自动泛化）。
///
/// 21 种内置标量为无载荷单元变体；复合类型的子类型均以 `TypeHandle` 索引引用，
/// 避免自引用生命周期。`never`/`unknown` 为发散/占位类型，`unify` 时会就地覆写
/// 对应槽位（故二者**不**被 intern，每次 `make` 都分配新槽）。
#[derive(Debug, Clone, PartialEq)]
pub enum ConcreteType {
    // ── 21 种内置标量 ──
    I8, I16, I32, I64, I128, U8, U16, U32, U64, U128, Isize, Usize,
    F16, F32, F64, F128, Bool, Str, Char, Null, Void,
    /// 发散类型：return/throw 等早退路径（与任意类型统一为对方）
    Never,
    /// 局部推断类型变量，载荷为 `TypeArena::type_vars` 下标
    TypeVar(u32),

    // ── 复合类型 ──
    /// 函数类型 `(P1, P2) -> R`
    Fn {
        params: Box<[TypeHandle]>,
        return_type: TypeHandle,
    },
    /// 记录类型 `{ x: i32, y: i32 }`
    Record {
        fields: Box<[FieldType]>,
        name: Option<Box<str>>,
    },
    /// ADT（代数数据类型）`Option<T>` 等
    Adt {
        name: Box<str>,
        type_args: Box<[TypeHandle]>,
    },
    /// 可空类型 `T?`
    Nullable(TypeHandle),
    /// 泛型应用 `List<i32>`
    Generic {
        name: Box<str>,
        args: Box<[TypeHandle]>,
    },
    /// 数组类型 `[T; N]`，`size == None` 为切片
    Array {
        element_type: TypeHandle,
        size: Option<u64>,
    },
    /// throw 类型 `Throw<V, E>`
    Throw {
        value_type: TypeHandle,
        error_type: TypeHandle,
    },
    /// trait 类型 `Ord<T>`
    Trait {
        name: Box<str>,
        type_args: Box<[TypeHandle]>,
    },
    /// 引用类型 `&T`（is_raw=false）/ 裸指针 `*T`（is_raw=true）
    Ref {
        inner: TypeHandle,
        is_raw: bool,
    },
    /// 未知类型（与任意类型统一为对方，类似 never）
    Unknown,
}

/// 内置标量的统一元数据。所有标量谓词（is_int / is_float / is_numeric /
/// is_signed_int / int_bit_width / float_bit_width / builtin_name / builtin_type_id）
/// 以及自由函数 int_type_rank / float_type_rank / is_signed_int_ct 全部由
/// `ConcreteType::classify_scalar` 派生，消除 11 处标量变体列举重复。
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct ScalarInfo {
    pub kind: ScalarKind,
    pub signed: bool,
    pub bit_width: u16,
    /// 宽化比较的秩（同宽同符号共享秩）；非数值标量为 0。
    pub rank: u8,
    pub name: &'static str,
    /// 1..=21，与 builtin_type_id 一致。
    pub type_id: u16,
}

/// 标量大类。
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ScalarKind {
    SignedInt,
    UnsignedInt,
    Float,
    Bool,
    Str,
    Char,
    Null,
    Void,
}

impl ConcreteType {
    /// 返回内置标量的元数据；非标量（Never / TypeVar / 复合类型）返回 `None`。
    #[inline]
    pub fn classify_scalar(&self) -> Option<ScalarInfo> {
        // 单一权威来源：每行对应一个标量变体，集中维护。
        // 新增标量只需在此 match 添加一行，所有谓词自动派生。
        // bit_width/rank/name/type_id 与 int_type_rank/float_type_rank 等共享。
        let (kind, signed, bit_width, rank, name, type_id) = match self {
            ConcreteType::I8 => (ScalarKind::SignedInt, true, 8, 1, "i8", 1),
            ConcreteType::I16 => (ScalarKind::SignedInt, true, 16, 2, "i16", 2),
            ConcreteType::I32 => (ScalarKind::SignedInt, true, 32, 3, "i32", 3),
            ConcreteType::I64 => (ScalarKind::SignedInt, true, 64, 4, "i64", 4),
            ConcreteType::I128 => (ScalarKind::SignedInt, true, 128, 5, "i128", 5),
            ConcreteType::U8 => (ScalarKind::UnsignedInt, false, 8, 1, "u8", 6),
            ConcreteType::U16 => (ScalarKind::UnsignedInt, false, 16, 2, "u16", 7),
            ConcreteType::U32 => (ScalarKind::UnsignedInt, false, 32, 3, "u32", 8),
            ConcreteType::U64 => (ScalarKind::UnsignedInt, false, 64, 4, "u64", 9),
            ConcreteType::U128 => (ScalarKind::UnsignedInt, false, 128, 5, "u128", 10),
            ConcreteType::Isize => (ScalarKind::SignedInt, true, isize::BITS as u16, 4, "isize", 11),
            ConcreteType::Usize => (ScalarKind::UnsignedInt, false, isize::BITS as u16, 4, "usize", 12),
            ConcreteType::F16 => (ScalarKind::Float, false, 16, 1, "f16", 13),
            ConcreteType::F32 => (ScalarKind::Float, false, 32, 2, "f32", 14),
            ConcreteType::F64 => (ScalarKind::Float, false, 64, 3, "f64", 15),
            ConcreteType::F128 => (ScalarKind::Float, false, 128, 4, "f128", 16),
            ConcreteType::Bool => (ScalarKind::Bool, false, 1, 0, "bool", 17),
            ConcreteType::Char => (ScalarKind::Char, false, 32, 0, "char", 18),
            ConcreteType::Str => (ScalarKind::Str, false, 0, 0, "str", 19),
            ConcreteType::Null => (ScalarKind::Null, false, 0, 0, "Null", 20),
            ConcreteType::Void => (ScalarKind::Void, false, 0, 0, "void", 21),
            // Never / TypeVar / Unknown / 复合类型均非内置标量
            _ => return None,
        };
        Some(ScalarInfo { kind, signed, bit_width, rank, name, type_id })
    }

    /// 是否为整数类型（i8..i128, u8..u128, isize, usize）。
    #[inline]
    pub fn is_int(&self) -> bool {
        matches!(
            self.classify_scalar().map(|i| i.kind),
            Some(ScalarKind::SignedInt) | Some(ScalarKind::UnsignedInt)
        )
    }

    /// 是否为浮点类型（f16, f32, f64, f128）。
    #[inline]
    pub fn is_float(&self) -> bool {
        matches!(
            self.classify_scalar().map(|i| i.kind),
            Some(ScalarKind::Float)
        )
    }

    /// 是否为数值类型（整数或浮点）。
    #[inline]
    pub fn is_numeric(&self) -> bool {
        self.is_int() || self.is_float()
    }

    /// 整数位宽，非整数返回 `None`。
    #[inline]
    pub fn int_bit_width(&self) -> Option<u16> {
        match self.classify_scalar()? {
            ScalarInfo { kind: ScalarKind::SignedInt | ScalarKind::UnsignedInt, bit_width, .. } => Some(bit_width),
            _ => None,
        }
    }

    /// 浮点位宽，非浮点返回 `None`。
    #[inline]
    pub fn float_bit_width(&self) -> Option<u16> {
        match self.classify_scalar()? {
            ScalarInfo { kind: ScalarKind::Float, bit_width, .. } => Some(bit_width),
            _ => None,
        }
    }

    /// 整数是否为有符号类型。
    #[inline]
    pub fn is_signed_int(&self) -> bool {
        matches!(
            self.classify_scalar().map(|i| i.kind),
            Some(ScalarKind::SignedInt)
        )
    }

    /// 仅返回 21 种内置标量的静态类型名，复合类型返回 `None`。
    /// 用于区分"内置类型直接输出名"与"复合类型走结构化格式化"。
    #[inline]
    pub fn builtin_name(&self) -> Option<&'static str> {
        self.classify_scalar().map(|i| i.name)
    }

    /// 21 种内置标量的 type_id（1..=21），复合类型/TypeVar/Never/Unknown 返回 `None`。
    /// 用于 `from_concrete_type` 等场景通过 `lookup_by_type_id` 获取 `TypeDescriptor`。
    #[inline]
    pub fn builtin_type_id(&self) -> Option<u16> {
        self.classify_scalar().map(|i| i.type_id)
    }

    /// int→float 精确 widening 路径判定（spec §4.2）。
    /// 平台相关整数按 `isize::BITS` 归约到 i32/u32 或 i64/u64 后判定。
    pub fn int_to_float_widening(int_ty: &ConcreteType, float_ty: &ConcreteType) -> bool {
        let platform_bits = isize::BITS as u16;
        // 平台相关整数先归约到等价定长整数。
        let int_ty = match int_ty {
            ConcreteType::Isize => {
                if platform_bits <= 32 {
                    return Self::int_to_float_widening(&ConcreteType::I32, float_ty);
                } else {
                    return Self::int_to_float_widening(&ConcreteType::I64, float_ty);
                }
            }
            ConcreteType::Usize => {
                if platform_bits <= 32 {
                    return Self::int_to_float_widening(&ConcreteType::U32, float_ty);
                } else {
                    return Self::int_to_float_widening(&ConcreteType::U64, float_ty);
                }
            }
            other => other,
        };
        match int_ty {
            ConcreteType::I8 | ConcreteType::U8 | ConcreteType::I16 | ConcreteType::U16 => {
                matches!(float_ty, ConcreteType::F32 | ConcreteType::F64 | ConcreteType::F128)
            }
            ConcreteType::I32 | ConcreteType::U32 => {
                matches!(float_ty, ConcreteType::F64 | ConcreteType::F128)
            }
            ConcreteType::I64 | ConcreteType::U64 => matches!(float_ty, ConcreteType::F128),
            ConcreteType::I128 | ConcreteType::U128 => false,
            _ => false,
        }
    }
}

// =========================================================================
// UnifyError — 统一错误
// =========================================================================

/// 类型统一错误。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnifyError {
    /// 两个类型结构不兼容
    TypeMismatch,
    /// occurs check 失败：类型变量出现在目标类型中（无限类型）
    OccursCheckFailed,
}

impl fmt::Display for UnifyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::TypeMismatch => write!(f, "type mismatch"),
            Self::OccursCheckFailed => write!(f, "occurs check failed (recursive type)"),
        }
    }
}

impl std::error::Error for UnifyError {}

// =========================================================================
// TypeArena — ConcreteType 分配器 + unify/occurs/resolve
// =========================================================================

/// `ConcreteType` 分配器：arena-based，管理类型槽与类型变量。
///
/// 所有 `ConcreteType` 通过 `make` 分配并返回 `TypeHandle` 索引；类型变量通过
/// `fresh_type_var` / `fresh_rigid_var` 分配。`resolve`/`occurs`/`unify` 作为方法，
/// 因为复合类型的子节点遍历需要访问 `&self` / `&mut self`。
pub struct TypeArena {
    types: Vec<ConcreteType>,
    type_vars: Vec<TypeVar>,
}

impl Default for TypeArena {
    fn default() -> Self {
        Self::new()
    }
}

impl TypeArena {
    /// 创建空 arena。
    pub fn new() -> Self {
        TypeArena {
            types: Vec::new(),
            type_vars: Vec::new(),
        }
    }

    /// 已分配类型数量。
    #[inline]
    pub fn len(&self) -> usize {
        self.types.len()
    }

    /// 是否为空。
    #[inline]
    pub fn is_empty(&self) -> bool {
        self.types.is_empty()
    }

    /// 按句柄获取类型引用。
    #[inline]
    pub fn get(&self, h: TypeHandle) -> &ConcreteType {
        &self.types[h.0 as usize]
    }

    /// 分配一个 `ConcreteType`，返回新句柄。
    pub fn make(&mut self, ct: ConcreteType) -> TypeHandle {
        let h = TypeHandle(self.types.len() as u32);
        self.types.push(ct);
        h
    }

    /// 创建新的（非 rigid）类型变量，用于局部推断。
    pub fn fresh_type_var(&mut self) -> TypeHandle {
        let idx = self.type_vars.len() as u32;
        self.type_vars.push(TypeVar::new(false));
        self.make(ConcreteType::TypeVar(idx))
    }

    /// 创建 rigid 类型变量（泛型参数声明，不可与不同类型统一）。
    pub fn fresh_rigid_var(&mut self) -> TypeHandle {
        let idx = self.type_vars.len() as u32;
        self.type_vars.push(TypeVar::new(true));
        self.make(ConcreteType::TypeVar(idx))
    }

    /// 获取类型变量引用。
    #[inline]
    pub fn type_var(&self, idx: u32) -> &TypeVar {
        &self.type_vars[idx as usize]
    }

    /// 解析 `type_var` 的最终绑定（跟随 `bound` 链至非变量类型或未绑定变量）。
    pub fn resolve(&self, mut ty: TypeHandle) -> TypeHandle {
        while let ConcreteType::TypeVar(idx) = self.types[ty.0 as usize] {
            match self.type_vars[idx as usize].bound {
                Some(bound) => ty = bound,
                None => break,
            }
        }
        ty
    }

    /// occurs check：类型变量 `var_idx` 是否出现在 `ty` 中（防止无限类型）。
    pub fn occurs(&self, var_idx: u32, ty: TypeHandle) -> bool {
        match &self.types[ty.0 as usize] {
            ConcreteType::TypeVar(idx) => *idx == var_idx,
            ConcreteType::Fn { params, return_type } => {
                params.iter().any(|&p| self.occurs(var_idx, p))
                    || self.occurs(var_idx, *return_type)
            }
            ConcreteType::Record { fields, .. } => {
                fields.iter().any(|f| self.occurs(var_idx, f.ty))
            }
            ConcreteType::Nullable(inner) => self.occurs(var_idx, *inner),
            ConcreteType::Ref { inner, .. } => self.occurs(var_idx, *inner),
            ConcreteType::Adt { type_args, .. } => {
                type_args.iter().any(|&a| self.occurs(var_idx, a))
            }
            ConcreteType::Throw { value_type, error_type } => {
                self.occurs(var_idx, *value_type) || self.occurs(var_idx, *error_type)
            }
            ConcreteType::Generic { args, .. } => {
                args.iter().any(|&a| self.occurs(var_idx, a))
            }
            ConcreteType::Trait { type_args, .. } => {
                type_args.iter().any(|&a| self.occurs(var_idx, a))
            }
            ConcreteType::Array { element_type, .. } => self.occurs(var_idx, *element_type),
            _ => false,
        }
    }

    /// 统一两个类型（就地修改 `type_var.bound` 或覆写 `never`/`unknown` 槽位）。
    pub fn unify(&mut self, t1: TypeHandle, t2: TypeHandle) -> Result<(), UnifyError> {
        let a = self.resolve(t1);
        let b = self.resolve(t2);
        if a == b {
            return Ok(());
        }

        // ── type_var 绑定（a 侧）──
        if let ConcreteType::TypeVar(idx) = self.types[a.0 as usize] {
            let is_rigid = self.type_vars[idx as usize].is_rigid;
            if is_rigid {
                // rigid var 只能与相同 id 的 var 统一
                if let ConcreteType::TypeVar(bidx) = self.types[b.0 as usize] {
                    if bidx == idx {
                        return Ok(());
                    }
                }
                return Err(UnifyError::TypeMismatch);
            }
            if self.occurs(idx, b) {
                return Err(UnifyError::OccursCheckFailed);
            }
            self.type_vars[idx as usize].bound = Some(b);
            return Ok(());
        }

        // ── type_var 绑定（b 侧）──
        if let ConcreteType::TypeVar(idx) = self.types[b.0 as usize] {
            let is_rigid = self.type_vars[idx as usize].is_rigid;
            if is_rigid {
                return Err(UnifyError::TypeMismatch);
            }
            if self.occurs(idx, a) {
                return Err(UnifyError::OccursCheckFailed);
            }
            self.type_vars[idx as usize].bound = Some(a);
            return Ok(());
        }

        // ── never / unknown 与任意类型统一为对方（就地覆写原槽位）──
        match self.types[a.0 as usize] {
            ConcreteType::Never | ConcreteType::Unknown => {
                self.types[t1.0 as usize] = self.types[b.0 as usize].clone();
                return Ok(());
            }
            _ => {}
        }
        match self.types[b.0 as usize] {
            ConcreteType::Never | ConcreteType::Unknown => {
                self.types[t2.0 as usize] = self.types[a.0 as usize].clone();
                return Ok(());
            }
            _ => {}
        }

        // ── 结构化统一 ──
        // 克隆双方变体以避免在递归 &mut self 时持有借用以满足借用检查器。
        // unify 仅在编译期执行，克隆开销可接受。
        let a_ct = self.types[a.0 as usize].clone();
        let b_ct = self.types[b.0 as usize].clone();
        match (&a_ct, &b_ct) {
            (ConcreteType::I8, ConcreteType::I8)
            | (ConcreteType::I16, ConcreteType::I16)
            | (ConcreteType::I32, ConcreteType::I32)
            | (ConcreteType::I64, ConcreteType::I64)
            | (ConcreteType::I128, ConcreteType::I128)
            | (ConcreteType::U8, ConcreteType::U8)
            | (ConcreteType::U16, ConcreteType::U16)
            | (ConcreteType::U32, ConcreteType::U32)
            | (ConcreteType::U64, ConcreteType::U64)
            | (ConcreteType::U128, ConcreteType::U128)
            | (ConcreteType::Isize, ConcreteType::Isize)
            | (ConcreteType::Usize, ConcreteType::Usize)
            | (ConcreteType::F16, ConcreteType::F16)
            | (ConcreteType::F32, ConcreteType::F32)
            | (ConcreteType::F64, ConcreteType::F64)
            | (ConcreteType::F128, ConcreteType::F128)
            | (ConcreteType::Bool, ConcreteType::Bool)
            | (ConcreteType::Str, ConcreteType::Str)
            | (ConcreteType::Char, ConcreteType::Char)
            | (ConcreteType::Null, ConcreteType::Null)
            | (ConcreteType::Void, ConcreteType::Void) => Ok(()),

            (
                ConcreteType::Fn { params: pa, return_type: ra },
                ConcreteType::Fn { params: pb, return_type: rb },
            ) => {
                if pa.len() != pb.len() {
                    return Err(UnifyError::TypeMismatch);
                }
                for (&x, &y) in pa.iter().zip(pb.iter()) {
                    self.unify(x, y)?;
                }
                self.unify(*ra, *rb)
            }

            (
                ConcreteType::Record { fields: fa, .. },
                ConcreteType::Record { fields: fb, .. },
            ) => {
                if fa.len() != fb.len() {
                    return Err(UnifyError::TypeMismatch);
                }
                for (x, y) in fa.iter().zip(fb.iter()) {
                    self.unify(x.ty, y.ty)?;
                }
                Ok(())
            }

            (ConcreteType::Nullable(ia), ConcreteType::Nullable(ib)) => self.unify(*ia, *ib),

            (
                ConcreteType::Ref { inner: ia, is_raw: ra },
                ConcreteType::Ref { inner: ib, is_raw: rb },
            ) => {
                if ra != rb {
                    return Err(UnifyError::TypeMismatch);
                }
                self.unify(*ia, *ib)
            }

            (
                ConcreteType::Adt { name: na, type_args: ta },
                ConcreteType::Adt { name: nb, type_args: tb },
            ) => self.unify_named_args(na, ta, nb, tb),

            (
                ConcreteType::Generic { name: na, args: ta },
                ConcreteType::Generic { name: nb, args: tb },
            ) => self.unify_named_args(na, ta, nb, tb),

            (
                ConcreteType::Trait { name: na, type_args: ta },
                ConcreteType::Trait { name: nb, type_args: tb },
            ) => self.unify_named_args(na, ta, nb, tb),

            (
                ConcreteType::Array { element_type: ea, .. },
                ConcreteType::Array { element_type: eb, .. },
            ) => self.unify(*ea, *eb),

            (
                ConcreteType::Throw { value_type: va, error_type: ea },
                ConcreteType::Throw { value_type: vb, error_type: eb },
            ) => {
                self.unify(*va, *vb)?;
                self.unify(*ea, *eb)
            }

            _ => Err(UnifyError::TypeMismatch),
        }
    }

    /// 统一命名类型实参列表：名称匹配 + 逐元素 unify。
    /// 供 Adt/Generic/Trait 三种命名复合类型共用。
    #[inline]
    fn unify_named_args(
        &mut self,
        na: &str,
        ta: &[TypeHandle],
        nb: &str,
        tb: &[TypeHandle],
    ) -> Result<(), UnifyError> {
        if na != nb || ta.len() != tb.len() {
            return Err(UnifyError::TypeMismatch);
        }
        for (&x, &y) in ta.iter().zip(tb.iter()) {
            self.unify(x, y)?;
        }
        Ok(())
    }

    /// 从标量类型名反向构造 `ConcreteType`（用于内置类型）；未知名返回 `Unknown`。
    pub fn from_scalar_name(&mut self, name: &str) -> TypeHandle {
        let ct = match name {
            "i8" => ConcreteType::I8,
            "i16" => ConcreteType::I16,
            "i32" => ConcreteType::I32,
            "i64" => ConcreteType::I64,
            "i128" => ConcreteType::I128,
            "u8" => ConcreteType::U8,
            "u16" => ConcreteType::U16,
            "u32" => ConcreteType::U32,
            "u64" => ConcreteType::U64,
            "u128" => ConcreteType::U128,
            "isize" => ConcreteType::Isize,
            "usize" => ConcreteType::Usize,
            "f16" => ConcreteType::F16,
            "f32" => ConcreteType::F32,
            "f64" => ConcreteType::F64,
            "f128" => ConcreteType::F128,
            "bool" => ConcreteType::Bool,
            "char" => ConcreteType::Char,
            "Null" => ConcreteType::Null,
            "void" => ConcreteType::Void,
            _ => return self.make(ConcreteType::Unknown),
        };
        self.make(ct)
    }

    /// 提取类型名（用于 `ExprInfo.type_name`）。
    /// 标量返回静态名；adt/generic/trait 返回其名；ref/nullable 递归取 inner 名；
    /// 其余返回 `None`。递归场景需 arena 访问子节点。
    pub fn type_name<'a>(&'a self, ty: TypeHandle) -> Option<&'a str> {
        match &self.types[ty.0 as usize] {
            ConcreteType::Adt { name, .. }
            | ConcreteType::Generic { name, .. }
            | ConcreteType::Trait { name, .. } => Some(name),
            ConcreteType::Ref { inner, .. } | ConcreteType::Nullable(inner) => {
                self.type_name(*inner)
            }
            ct => ct.builtin_name(),
        }
    }

    /// 构造一个 `TypeDisplay` 包装器，可用于 `format!("{}", arena.display(h))`。
    #[inline]
    pub fn display(&self, ty: TypeHandle) -> TypeDisplay<'_> {
        TypeDisplay { arena: self, ty }
    }
}

// =========================================================================
// TypeDisplay — ConcreteType 的 Display 包装器（需 arena 解引用 type_var 绑定）
// =========================================================================

/// `ConcreteType` 的格式化包装器：`type_var` 跟随 `bound` 链显示最终类型，
/// 未绑定变量显示为 `'_<idx>`。
pub struct TypeDisplay<'a> {
    pub arena: &'a TypeArena,
    pub ty: TypeHandle,
}

impl fmt::Display for TypeDisplay<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let resolved = self.arena.resolve(self.ty);
        match self.arena.get(resolved) {
            ConcreteType::TypeVar(idx) => {
                // resolve 后仍为 TypeVar → 未绑定
                write!(f, "'_{}", idx)
            }
            ConcreteType::Void => f.write_str("void"),
            ct => {
                if let Some(name) = ct.builtin_name() {
                    return f.write_str(name);
                }
                match ct {
                    ConcreteType::Fn { params, return_type } => {
                        f.write_str("(")?;
                        for (i, &p) in params.iter().enumerate() {
                            if i > 0 {
                                f.write_str(", ")?;
                            }
                            write!(f, "{}", self.arena.display(p))?;
                        }
                        f.write_str(") -> ")?;
                        write!(f, "{}", self.arena.display(*return_type))
                    }
                    ConcreteType::Record { fields, .. } => {
                        f.write_str("(")?;
                        for (i, field) in fields.iter().enumerate() {
                            if i > 0 {
                                f.write_str(", ")?;
                            }
                            if let Some(name) = &field.name {
                                write!(f, "{}: ", name)?;
                            }
                            write!(f, "{}", self.arena.display(field.ty))?;
                        }
                        f.write_str(")")
                    }
                    ConcreteType::Adt { name, type_args } => {
                        f.write_str(name)?;
                        fmt_type_args(f, self.arena, type_args)
                    }
                    ConcreteType::Nullable(inner) => {
                        write!(f, "{}?", self.arena.display(*inner))
                    }
                    ConcreteType::Ref { inner, is_raw } => {
                        f.write_str(if *is_raw { "*" } else { "&" })?;
                        write!(f, "{}", self.arena.display(*inner))
                    }
                    ConcreteType::Generic { name, args } => {
                        f.write_str(name)?;
                        fmt_type_args(f, self.arena, args)
                    }
                    ConcreteType::Array { element_type, size } => {
                        write!(f, "{}[", self.arena.display(*element_type))?;
                        if let Some(s) = size {
                            write!(f, "{}", s)?;
                        }
                        f.write_str("]")
                    }
                    ConcreteType::Throw { value_type, error_type } => {
                        f.write_str("Throw<")?;
                        write!(f, "{}", self.arena.display(*value_type))?;
                        f.write_str(", ")?;
                        write!(f, "{}", self.arena.display(*error_type))?;
                        f.write_str(">")
                    }
                    ConcreteType::Trait { name, type_args } => {
                        f.write_str(name)?;
                        fmt_type_args(f, self.arena, type_args)
                    }
                    ConcreteType::Unknown => f.write_str("?"),
                    ConcreteType::Never => f.write_str("!"),
                    // 标量已在 builtin_name 分支处理
                    _ => Ok(()),
                }
            }
        }
    }
}

/// 格式化类型参数列表 `<T1, T2>`，空列表返回空。
fn fmt_type_args(
    f: &mut fmt::Formatter<'_>,
    arena: &TypeArena,
    args: &[TypeHandle],
) -> fmt::Result {
    if args.is_empty() {
        return Ok(());
    }
    f.write_str("<")?;
    for (i, &a) in args.iter().enumerate() {
        if i > 0 {
            f.write_str(", ")?;
        }
        write!(f, "{}", arena.display(a))?;
    }
    f.write_str(">")
}

// =========================================================================
// ConcreteEnv / EnvArena — 类型环境（替代旧 TypeEnv，无 TypeScheme）
// =========================================================================

/// 环境句柄：`EnvArena` 中的索引。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct EnvId(pub u32);

/// 类型环境节点：自身绑定 + 可选父环境（通过索引共享）。
struct EnvNode {
    bindings: HashMap<String, TypeHandle>,
    parent: Option<EnvId>,
}

/// 类型环境 arena：以索引管理环境节点，支持父环境共享，无 `Rc`/`RefCell`。
pub struct EnvArena {
    envs: Vec<EnvNode>,
}

impl Default for EnvArena {
    fn default() -> Self {
        Self::new()
    }
}

impl EnvArena {
    pub fn new() -> Self {
        EnvArena { envs: Vec::new() }
    }

    /// 创建顶层环境（无父环境）。
    pub fn root(&mut self) -> EnvId {
        let id = EnvId(self.envs.len() as u32);
        self.envs.push(EnvNode {
            bindings: HashMap::new(),
            parent: None,
        });
        id
    }

    /// 创建子环境，父环境为 `parent`。
    pub fn child(&mut self, parent: EnvId) -> EnvId {
        let id = EnvId(self.envs.len() as u32);
        self.envs.push(EnvNode {
            bindings: HashMap::new(),
            parent: Some(parent),
        });
        id
    }

    /// 在 `env` 中定义绑定；已存在同名绑定返回 `false`。
    pub fn define(&mut self, env: EnvId, name: &str, ty: TypeHandle) -> bool {
        let node = &mut self.envs[env.0 as usize];
        if node.bindings.contains_key(name) {
            return false;
        }
        node.bindings.insert(name.to_string(), ty);
        true
    }

    /// 自 `env` 向上查找名字（含父环境链）；未找到返回 `None`。
    pub fn lookup(&self, mut env: EnvId, name: &str) -> Option<TypeHandle> {
        loop {
            let node = &self.envs[env.0 as usize];
            if let Some(&ty) = node.bindings.get(name) {
                return Some(ty);
            }
            match node.parent {
                Some(p) => env = p,
                None => return None,
            }
        }
    }
}

// =========================================================================
// ConstVal — 编译期常量值
// =========================================================================

/// 编译期常量值（对应 ir/meta.zig 的 `ConstVal`）。
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ConstVal {
    /// 整数字面量
    Int(i128),
    /// 浮点字面量的位模式（按目标 float 类型解释）
    Float(u128),
    /// 布尔字面量
    Bool(bool),
    /// 字符字面量（Unicode scalar value）
    Char(u32),
}

// =========================================================================
// SemaResult 辅助结构
// =========================================================================

/// 单个表达式的语义信息。
#[derive(Debug, Clone)]
pub struct ExprInfo {
    /// 表达式的类型描述符（决定通道宽度与读写 vtable）
    pub type_desc: &'static TypeDescriptor,
    /// Nullable 内部类型描述符（`type_desc.is_nullable()` 时有效）
    pub inner_type_desc: Option<&'static TypeDescriptor>,
    /// 编译期常量值（若表达式是常量）
    pub const_val: Option<ConstVal>,
    /// 表达式的 AST 句柄地址（用作 key）
    pub expr_id: u64,
    /// 表达式的类型名（adt/generic 等场景，消除 IR 侧 AST 回溯）
    pub type_name: Option<Box<str>>,
    /// 是否为 `&T` / `*T` 引用类型（运行时保持引用语义不深拷贝）
    pub is_ref_type: bool,
    /// 区分 `&T`(false) 与 `*T`(true)；仅 `is_ref_type=true` 时有效
    pub is_raw_ref: bool,
    /// 泛型实参类型名列表（仅 generic 方法调用/构造器调用有效）
    pub type_args: Option<Box<[Box<str>]>>,
    /// 函数签名（仅对 callee 表达式有效，用于调用点推断返回类型）
    pub fn_sig: Option<FnSigRef>,
}

impl ExprInfo {
    /// 以给定 `type_desc` 构造最小 `ExprInfo`（其余字段为默认值）。
    pub fn new(type_desc: &'static TypeDescriptor, expr_id: u64) -> Self {
        ExprInfo {
            type_desc,
            inner_type_desc: None,
            const_val: None,
            expr_id,
            type_name: None,
            is_ref_type: false,
            is_raw_ref: false,
            type_args: None,
            fn_sig: None,
        }
    }
}

/// 类型定义种类。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TypeDefKind {
    /// 代数数据类型
    Adt,
    /// 记录类型
    Record,
    /// 类型别名
    Alias,
    /// newtype 包装
    Newtype,
    /// error newtype
    ErrorNewtype,
}

/// 构造器定义信息（压平后的 sema AdtInfo 构造器）。
#[derive(Debug, Clone)]
pub struct CtorDefInfo {
    pub name: Box<str>,
    pub type_name: Box<str>,
    pub field_names: Box<[Option<Box<str>>]>,
    pub field_type_descs: Box<[&'static TypeDescriptor]>,
    pub field_type_names: Box<[Option<Box<str>>]>,
    pub is_newtype: bool,
    /// GADT 构造器返回类型名（仅 GADT 有效）
    pub return_type_name: Option<Box<str>>,
    /// GADT 构造器返回类型 TypeNode（消除 IR 侧 AST 回退）
    pub return_type_node: Option<AstTypeRef>,
    /// 构造器字段的 TypeNode（消除 IR 侧 AST 回退）
    /// 长度与 `field_names` 一致，无类型信息的字段为 `None`
    pub field_type_nodes: Box<[Option<AstTypeRef>]>,
}

/// 类型定义信息（替代 IRBuilder 的 type_table + ctor_table）。
#[derive(Debug, Clone)]
pub struct TypeDefInfo {
    pub name: Box<str>,
    pub kind: TypeDefKind,
    /// adt/newtype/error_newtype：构造器列表
    /// record：`constructors[0]` 存字段（name == type_name）
    /// alias：空切片
    pub constructors: Box<[CtorDefInfo]>,
    pub type_params: Box<[Box<str>]>,
    /// 仅 alias/newtype：目标类型名
    pub target_type_name: Option<Box<str>>,
    /// 仅 alias/newtype：目标类型描述符
    pub target_type_desc: Option<&'static TypeDescriptor>,
}

/// Trait 方法签名（压平后的 sema TraitInfo 方法）。
#[derive(Debug, Clone)]
pub struct TraitMethodSig {
    pub name: Box<str>,
    pub param_count: u8,
    pub return_type_desc: &'static TypeDescriptor,
    pub is_async: bool,
    /// 是否有 default 实现体（IRBuilder 据此决定是否从 AST 取 body）
    pub has_body: bool,
}

/// Trait 定义信息（替代 IRBuilder 的 trait_table 签名部分）。
#[derive(Debug, Clone)]
pub struct TraitDefInfo {
    pub name: Box<str>,
    pub methods: Box<[TraitMethodSig]>,
}

/// 函数签名引用（嵌入 `ExprInfo`，仅对 callee 表达式有效）。
#[derive(Debug, Clone)]
pub struct FnSigRef {
    pub param_type_descs: Box<[&'static TypeDescriptor]>,
    pub return_type_desc: &'static TypeDescriptor,
    pub is_async: bool,
    pub is_throwing: bool,
}

/// 函数签名信息（替代 IRBuilder 的 func_generic_info）。
#[derive(Debug, Clone)]
pub struct FuncSigInfo {
    /// 函数名或 mangled 名（TypeName.method）
    pub name: Box<str>,
    pub type_params: Box<[Box<str>]>,
    pub param_type_descs: Box<[&'static TypeDescriptor]>,
    pub return_type_desc: &'static TypeDescriptor,
    /// 每个参数是否为 `&T` 引用语义
    pub param_is_ref: Box<[bool]>,
    pub return_is_ref: bool,
    pub is_async: bool,
    pub is_throwing: bool,
    /// 参数类型名（消除 IR 侧 findFuncParamsAst AST 回退）
    pub param_type_names: Box<[Option<Box<str>>]>,
}

/// Import 别名目标（区分模块引用和符号引用）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AliasTarget {
    /// 模块短名 → 完整模块路径
    /// `import std.time.Calendar` → "Calendar" → `AliasTarget::Module("std.time.Calendar")`
    Module(Box<str>),
    /// 函数/常量短名 → mangled 名
    /// `import std.time.Calendar { is_leap_year }` → "is_leap_year" → `AliasTarget::Symbol("std.time.Calendar.is_leap_year")`
    Symbol(Box<str>),
}

/// 通道布局（单态化实例的通道分配方案）。
#[derive(Debug, Clone)]
pub struct ChanLayout {
    pub local_chan_count: u16,
    pub return_channel: u16,
    pub local_offsets: Box<[u32]>,
    pub chan_type_descs: Box<[&'static TypeDescriptor]>,
    pub chan_total_bytes: u32,
}

impl ChanLayout {
    /// 空 layout（未计算通道分配时的占位）。
    pub fn empty() -> Self {
        ChanLayout {
            local_chan_count: 0,
            return_channel: 0,
            local_offsets: Box::new([]),
            chan_type_descs: Box::new([]),
            chan_total_bytes: 0,
        }
    }
}

/// 字段访问元信息（运行时分派 field_id 查找）。
#[derive(Debug, Clone)]
pub struct FieldAccessInfo {
    pub obj_type_desc: &'static TypeDescriptor,
    pub field_idx: u16,
    pub field_type_desc: &'static TypeDescriptor,
}

/// 方法分派元信息（trait 方法 → 具体 impl 函数）。
#[derive(Debug, Clone, Copy)]
pub struct DispatchInfo {
    pub trait_id: u16,
    pub method_idx: u16,
    pub impl_fn_idx: u16,
    /// 泛型方法调用的单态化实例 ID（非泛型为 0）
    pub instance_id: u32,
}

/// typeof 已解析元信息。
#[derive(Debug, Clone, Copy)]
pub struct TypeofMeta {
    pub type_desc: &'static TypeDescriptor,
}

/// reflect 已解析元信息。
#[derive(Debug, Clone, Copy)]
pub struct ReflectMeta {
    pub type_desc: &'static TypeDescriptor,
}

/// 单态化实例（一个泛型函数 + 一组 type_args → 一个实例）。
#[derive(Debug)]
pub struct MonomorphInstance {
    pub instance_id: u32,
    pub func_name: Box<str>,
    pub type_args: Box<[&'static TypeDescriptor]>,
    pub chan_layout: ChanLayout,
    pub return_type: &'static TypeDescriptor,
    pub is_async: bool,
    /// 实例本地表达式类型表（key = AST Expr 句柄地址）
    pub expr_types: HashMap<u64, ExprInfo>,
    /// 字段访问元信息（key = AST field_access Expr 句柄地址）
    pub field_accesses: HashMap<u64, FieldAccessInfo>,
}

/// 协程元数据（async 函数状态机变换产物）。
///
/// 完整段/帧/defer/catch/loop 表在 ir/meta 移植后补充；当前仅保留
/// sema 输出所需的最小字段，使 `SemaResult` 接口完整。
#[derive(Debug, Clone)]
pub struct CoroutineMeta {
    /// async 函数索引（functions 表中的索引）
    pub func_idx: u16,
    /// 状态段数
    pub segment_count: u16,
}

// =========================================================================
// SemaError — 语义错误
// =========================================================================

/// 语义错误。
#[derive(Debug, Clone)]
pub struct SemaError {
    pub message: Box<str>,
    pub line: u32,
    pub column: u32,
}

impl SemaError {
    pub fn new(message: &str, line: u32, column: u32) -> Self {
        SemaError {
            message: message.into(),
            line,
            column,
        }
    }
}

// =========================================================================
// SemaResult — sema 产出的图构建元信息
// =========================================================================

/// sema 产出的图构建元信息。
///
/// 从"检查器"升级为"图构建驱动器"，输出图构建所需的全部元信息。
/// 所有字段均为自有数据（`Box<str>` / `Vec` / `HashMap`），无需额外 arena 所有权。
pub struct SemaResult {
    /// 表达式 → 类型信息（决定通道宽度），key = AST 表达式句柄地址
    pub expr_types: HashMap<u64, ExprInfo>,
    /// 编译期错误
    pub errors: Vec<SemaError>,
    /// 是否有错误
    pub has_error: bool,
    /// 类型定义表（替代 IRBuilder 的 type_table + ctor_table）
    pub type_defs: Vec<TypeDefInfo>,
    /// 类型名 → type_defs 索引
    pub type_def_index: HashMap<String, u16>,
    /// Trait 定义表
    pub trait_defs: Vec<TraitDefInfo>,
    /// Trait 名 → trait_defs 索引
    pub trait_def_index: HashMap<String, u16>,
    /// 函数签名表
    pub func_sigs: Vec<FuncSigInfo>,
    /// 函数名 → func_sigs 索引
    pub func_sig_index: HashMap<String, u16>,
    /// 协程元数据表
    pub coroutine_metas: Vec<CoroutineMeta>,
    /// 构造器名 → (type_def_index << 16 | ctor_index)
    pub ctor_def_index: HashMap<String, u32>,
    /// import 别名表：短名 → 别名目标
    pub import_aliases: HashMap<String, AliasTarget>,
    /// 单态化实例表
    pub monomorph_instances: Vec<MonomorphInstance>,
    /// 单态化实例名 → monomorph_instances 索引
    pub monomorph_index: HashMap<String, u32>,
    /// 全局 TypeDescriptor 表
    pub type_descriptors: Vec<&'static TypeDescriptor>,
    /// 动态类型描述符池（用户类型 / nullable 描述符）
    pub type_desc_pool: TypeDescriptorPool,
    /// 调用点 → 实例映射
    pub call_instantiations: HashMap<u64, u32>,
    /// 字段访问元信息（全局，key = AST field_access Expr 句柄地址）
    pub field_accesses: HashMap<u64, FieldAccessInfo>,
    /// 方法分派元信息（key = AST call Expr 句柄地址）
    pub method_dispatches: HashMap<u64, DispatchInfo>,
    /// typeof 已解析元信息
    pub typeof_metas: HashMap<u64, TypeofMeta>,
    /// reflect 已解析元信息
    pub reflect_metas: HashMap<u64, ReflectMeta>,
    /// 已解析类型描述符（key = AST Expr 句柄地址）
    pub resolved_type_descs: HashMap<u64, &'static TypeDescriptor>,
    /// 字段 ID 映射（key = "type_name\x00field_name" → field_id）
    /// ADT/newtype/error_newtype: `__tag=0`，字段从 1 开始
    /// Record: 字段按声明顺序 0..N-1
    pub field_id_map: HashMap<String, u16>,
}

impl Default for SemaResult {
    fn default() -> Self {
        Self::new()
    }
}

impl SemaResult {
    pub fn new() -> Self {
        SemaResult {
            expr_types: HashMap::new(),
            errors: Vec::new(),
            has_error: false,
            type_defs: Vec::new(),
            type_def_index: HashMap::new(),
            trait_defs: Vec::new(),
            trait_def_index: HashMap::new(),
            func_sigs: Vec::new(),
            func_sig_index: HashMap::new(),
            coroutine_metas: Vec::new(),
            ctor_def_index: HashMap::new(),
            import_aliases: HashMap::new(),
            monomorph_instances: Vec::new(),
            monomorph_index: HashMap::new(),
            type_descriptors: Vec::new(),
            type_desc_pool: TypeDescriptorPool::new(),
            call_instantiations: HashMap::new(),
            field_accesses: HashMap::new(),
            method_dispatches: HashMap::new(),
            typeof_metas: HashMap::new(),
            reflect_metas: HashMap::new(),
            resolved_type_descs: HashMap::new(),
            field_id_map: HashMap::new(),
        }
    }

    // ── 表达式 ──

    /// 记录表达式类型。
    pub fn put_expr(&mut self, expr_id: u64, info: ExprInfo) {
        self.expr_types.insert(expr_id, info);
    }

    /// 查询表达式类型。
    pub fn get_expr(&self, expr_id: u64) -> Option<&ExprInfo> {
        self.expr_types.get(&expr_id)
    }

    // ── 类型描述符 ──

    /// 获取或创建具名引用类型描述符。
    /// `str` 使用静态描述符；其他用户类型经 `TypeDescriptorPool` 动态分配。
    pub fn get_or_create_ref_desc(&mut self, name: &str) -> &'static TypeDescriptor {
        if name == "str" {
            return &STR_DESC;
        }
        if let Some(d) = self.type_desc_pool.get_by_name(name) {
            return d;
        }
        self.type_desc_pool.register(name, 8, &RefOps);
        // register 后再次按名查询返回泄漏后的 &'static 描述符
        self.type_desc_pool
            .get_by_name(name)
            .expect(" freshly registered descriptor must exist")
    }

    /// 获取或创建 `nullable<T>` 描述符。
    ///
    /// 当前共享层无独立 nullable vtable（属 engine 层职责），故复用 inner 的 ops
    /// 作为数据部分读写，size = inner.size + 1（含 null 标志位）。完整 nullable
    /// vtable 在 engine 层移植后替换。
    pub fn get_or_create_nullable_desc(
        &mut self,
        inner: &'static TypeDescriptor,
    ) -> &'static TypeDescriptor {
        let name = format!("nullable<{}>", inner.type_name);
        if let Some(d) = self.type_desc_pool.get_by_name(&name) {
            return d;
        }
        let size = inner.size.saturating_add(1);
        self.type_desc_pool.register(&name, size, inner.ops);
        self.type_desc_pool
            .get_by_name(&name)
            .expect("freshly registered nullable descriptor must exist")
    }

    /// 将 `type_desc_pool` 所有权转移给调用方（IRBuilder.build 成功后调用）。
    /// 转移后 `SemaResult` 持有一个新的空 pool，`Drop` 不会释放已转移的描述符。
    pub fn take_type_desc_pool(&mut self) -> TypeDescriptorPool {
        std::mem::take(&mut self.type_desc_pool)
    }

    // ── import 别名 ──

    /// 注册 import 别名；重复短名返回 `false`。
    pub fn put_import_alias(&mut self, short_name: &str, target: AliasTarget) -> bool {
        if self.import_aliases.contains_key(short_name) {
            return false;
        }
        self.import_aliases.insert(short_name.to_string(), target);
        true
    }

    /// 查询 import 别名。
    pub fn get_import_alias(&self, short_name: &str) -> Option<&AliasTarget> {
        self.import_aliases.get(short_name)
    }

    // ── 错误 ──

    /// 记录错误。
    pub fn add_error(&mut self, err: SemaError) {
        self.has_error = true;
        self.errors.push(err);
    }

    // ── 类型定义 ──

    /// 添加类型定义并注册 `type_def_index` / `ctor_def_index`，同时自动填充
    /// `field_id_map`。重复类型名或构造器名返回 `false` 且不写入（拒绝部分写入）。
    pub fn put_type_def(&mut self, def: TypeDefInfo) -> bool {
        let idx: u16 = self.type_defs.len() as u16;
        // 前置校验：类型名与所有构造器名均不得重复，避免部分写入。
        if self.type_def_index.contains_key(def.name.as_ref()) {
            return false;
        }
        for ctor in def.constructors.iter() {
            if self.ctor_def_index.contains_key(ctor.name.as_ref()) {
                return false;
            }
        }
        // 校验通过，执行写入（此后 def 不可再用，故按引用操作后 push）。
        self.populate_field_ids(&def);
        for (ci, ctor) in def.constructors.iter().enumerate() {
            let packed_idx: u32 = ((idx as u32) << 16) | (ci as u32);
            self.ctor_def_index
                .insert(ctor.name.to_string(), packed_idx);
        }
        self.type_def_index.insert(def.name.to_string(), idx);
        self.type_defs.push(def);
        true
    }

    /// 按 type_def 的 kind 规则填充 `field_id_map`。
    /// - adt/newtype/error_newtype: `__tag=0`，字段从 1 开始
    /// - record: 字段按声明顺序 0..N-1
    /// - alias: 无字段
    fn populate_field_ids(&mut self, def: &TypeDefInfo) {
        match def.kind {
            TypeDefKind::Adt => {
                for ctor in def.constructors.iter() {
                    for (fi, fname) in ctor.field_names.iter().enumerate() {
                        if let Some(name) = fname {
                            let field_id = (fi + 1) as u16;
                            self.put_field_id(&def.name, name, field_id);
                        }
                    }
                }
                self.put_field_id(&def.name, "__tag", 0);
            }
            TypeDefKind::Newtype | TypeDefKind::ErrorNewtype => {
                for (fi, fname) in def.constructors.iter().flat_map(|c| c.field_names.iter()).enumerate() {
                    let field_id = (fi + 1) as u16;
                    match fname {
                        Some(name) => self.put_field_id(&def.name, name, field_id),
                        None => {
                            let positional = format!("_{}", fi);
                            self.put_field_id(&def.name, &positional, field_id);
                        }
                    }
                }
                self.put_field_id(&def.name, "__tag", 0);
            }
            TypeDefKind::Record => {
                if let Some(ctor) = def.constructors.first() {
                    for (fi, fname) in ctor.field_names.iter().enumerate() {
                        if let Some(name) = fname {
                            let field_id = fi as u16;
                            self.put_field_id(&def.name, name, field_id);
                        }
                    }
                }
            }
            TypeDefKind::Alias => {}
        }
    }

    /// 构造 `field_id_map` 的 key 并插入（已存在则覆盖）。
    fn put_field_id(&mut self, type_name: &str, field_name: &str, field_id: u16) {
        let mut key = String::with_capacity(type_name.len() + 1 + field_name.len());
        key.push_str(type_name);
        key.push('\0');
        key.push_str(field_name);
        self.field_id_map.insert(key, field_id);
    }

    /// 查询 field_id（找不到返回 `None`）。
    /// key = "type_name\x00field_name"
    pub fn lookup_field_id(&self, type_name: &str, field_name: &str) -> Option<u16> {
        let total_len = type_name.len() + 1 + field_name.len();
        let mut key_buf = [0u8; 256];
        if total_len <= key_buf.len() {
            key_buf[..type_name.len()].copy_from_slice(type_name.as_bytes());
            key_buf[type_name.len()] = 0;
            key_buf[type_name.len() + 1..total_len].copy_from_slice(field_name.as_bytes());
            // SAFETY: key 由合法 str 字节拼接，含 NUL 分隔符，构造合法 HashMap key。
            let key = unsafe { std::str::from_utf8_unchecked(&key_buf[..total_len]) };
            return self.field_id_map.get(key).copied();
        }
        let mut key = String::with_capacity(total_len);
        key.push_str(type_name);
        key.push('\0');
        key.push_str(field_name);
        self.field_id_map.get(&key).copied()
    }

    /// 按名查询类型定义。
    pub fn get_type_def(&self, name: &str) -> Option<&TypeDefInfo> {
        let idx = *self.type_def_index.get(name)?;
        self.type_defs.get(idx as usize)
    }

    /// 按构造器名查询构造器定义。
    pub fn get_ctor_def(&self, name: &str) -> Option<&CtorDefInfo> {
        let packed_idx = *self.ctor_def_index.get(name)?;
        let type_idx = (packed_idx >> 16) as u16;
        let ctor_idx = (packed_idx & 0xFFFF) as u16;
        let def = self.type_defs.get(type_idx as usize)?;
        def.constructors.get(ctor_idx as usize)
    }

    /// 解析记录/ADT 字段类型描述符。
    /// 按 `TypeDefKind` 区分 Record（field_id 从 0）与 ADT（field_id 从 1）。
    /// 返回 `(field_id, field_type_desc)`，找不到返回 `None`。
    pub fn resolve_field_td(
        &self,
        type_name: &str,
        field: &str,
    ) -> Option<(u16, &'static TypeDescriptor)> {
        let field_id = self.lookup_field_id(type_name, field)?;
        let ctor = self.get_ctor_def(type_name)?;
        let idx = match self.get_type_def(type_name) {
            Some(def) if def.kind == TypeDefKind::Record => field_id as usize,
            _ => (field_id as usize).saturating_sub(1),
        };
        let &field_td = ctor.field_type_descs.get(idx)?;
        Some((field_id, field_td))
    }

    // ── Trait 定义 ──

    /// 添加 trait 定义并注册索引；重复名返回 `false`。
    pub fn put_trait_def(&mut self, def: TraitDefInfo) -> bool {
        if self.trait_def_index.contains_key(def.name.as_ref()) {
            return false;
        }
        let idx: u16 = self.trait_defs.len() as u16;
        self.trait_def_index.insert(def.name.to_string(), idx);
        self.trait_defs.push(def);
        true
    }

    /// 按名查询 trait 定义。
    pub fn get_trait_def(&self, name: &str) -> Option<&TraitDefInfo> {
        let idx = *self.trait_def_index.get(name)?;
        self.trait_defs.get(idx as usize)
    }

    // ── 函数签名 ──

    /// 添加函数签名并注册索引；重复名返回 `false`。
    pub fn put_func_sig(&mut self, sig: FuncSigInfo) -> bool {
        if self.func_sig_index.contains_key(sig.name.as_ref()) {
            return false;
        }
        let idx: u16 = self.func_sigs.len() as u16;
        self.func_sig_index.insert(sig.name.to_string(), idx);
        self.func_sigs.push(sig);
        true
    }

    /// 按名查询函数签名。
    pub fn get_func_sig(&self, name: &str) -> Option<&FuncSigInfo> {
        let idx = *self.func_sig_index.get(name)?;
        self.func_sigs.get(idx as usize)
    }

    // ── 协程元数据 ──

    /// 添加协程元数据。
    pub fn put_coroutine_meta(&mut self, meta: CoroutineMeta) {
        self.coroutine_metas.push(meta);
    }

    /// 按 func_idx 查询协程元数据。
    pub fn get_coroutine_meta_by_func_idx(&self, func_idx: u16) -> Option<&CoroutineMeta> {
        self.coroutine_metas.iter().find(|m| m.func_idx == func_idx)
    }
}

// =========================================================================
// builtin_types — 内置类型注册表
//
// 对 `src/sema/builtin_types.zig` 的 Rust 移植。
// 统一标量名 → IntKind/FloatKind/TypeDescriptor 映射，以及内置泛型类型 arity 表。
// 数据源：TypeDesc.rs 的静态描述符表（type_id 1..=21），单一真相。
// =========================================================================

/// 内置泛型类型条目（高阶类型，固定 arity）。
#[derive(Debug, Clone, Copy)]
pub struct BuiltinGenericEntry {
    pub name: &'static str,
    pub arity: u8,
}

/// 内置泛型类型构造器表。
/// 新增内置泛型类型只需在此追加一条，type_check / kind_check 自动适配。
pub const BUILTIN_GENERIC_TYPES: &[BuiltinGenericEntry] = &[
    BuiltinGenericEntry { name: "Throw", arity: 2 },
    BuiltinGenericEntry { name: "Atomic", arity: 1 },
    BuiltinGenericEntry { name: "Async", arity: 1 },
    BuiltinGenericEntry { name: "Channel", arity: 1 },
    BuiltinGenericEntry { name: "Sender", arity: 1 },
    BuiltinGenericEntry { name: "Receiver", arity: 1 },
    BuiltinGenericEntry { name: "Lazy", arity: 1 },
    BuiltinGenericEntry { name: "TypeInfo", arity: 1 },
    BuiltinGenericEntry { name: "Reflect", arity: 1 },
];

/// 内置泛型类型名 → arity（未匹配返回 `None`）。
pub fn generic_type_arity(name: &str) -> Option<u8> {
    BUILTIN_GENERIC_TYPES
        .iter()
        .find(|e| e.name == name)
        .map(|e| e.arity)
}

/// 判断 name 是否为内置泛型类型构造器。
#[inline]
pub fn is_builtin_generic_type(name: &str) -> bool {
    generic_type_arity(name).is_some()
}

/// 标量名 → IntKind（非整数标量返回 `None`）。
pub fn int_kind_from_name(name: &str) -> Option<IntKind> {
    Some(match name {
        "i8" => IntKind::I8,
        "i16" => IntKind::I16,
        "i32" => IntKind::I32,
        "i64" => IntKind::I64,
        "i128" => IntKind::I128,
        "u8" => IntKind::U8,
        "u16" => IntKind::U16,
        "u32" => IntKind::U32,
        "u64" => IntKind::U64,
        "u128" => IntKind::U128,
        "isize" => IntKind::Isize,
        "usize" => IntKind::Usize,
        _ => return None,
    })
}

/// 标量名 → FloatKind（非浮点标量返回 `None`）。
pub fn float_kind_from_name(name: &str) -> Option<FloatKind> {
    Some(match name {
        "f16" => FloatKind::F16,
        "f32" => FloatKind::F32,
        "f64" => FloatKind::F64,
        "f128" => FloatKind::F128,
        _ => return None,
    })
}

/// 内置类型名（含标量 + str + null + void）→ TypeDescriptor，未匹配返回 `None`。
///
/// 数据源：TypeDesc.rs 的 `lookup_by_type_id`（type_id 1..=21），单一真相。
/// 新增标量只需在 TypeDesc.rs 追加描述符并在此追加 name → type_id 映射。
pub fn type_descriptor_from_builtin_name(name: &str) -> Option<&'static TypeDescriptor> {
    let type_id: u16 = match name {
        "i8" => 1,
        "i16" => 2,
        "i32" => 3,
        "i64" => 4,
        "i128" => 5,
        "u8" => 6,
        "u16" => 7,
        "u32" => 8,
        "u64" => 9,
        "u128" => 10,
        "isize" => 11,
        "usize" => 12,
        "f16" => 13,
        "f32" => 14,
        "f64" => 15,
        "f128" => 16,
        "bool" => 17,
        "char" => 18,
        "str" => 19,
        "null" => 20,
        "void" => 21,
        _ => return None,
    };
    lookup_by_type_id(type_id)
}

// =========================================================================
// TypeBindingContext — 类型绑定上下文（phase 3 提供 concrete impl）
//
// 对 `src/sema/inference.zig` 的 `TypeBindingContext` 的 trait 抽象。
// 用于泛型类型参数名 → 具体类型描述符的绑定查询。
// `chan_type_from_type_node_bound` 优先查此上下文，未命中再走常规解析路径。
// =========================================================================

/// 类型绑定查询结果。
#[derive(Debug, Clone, Copy)]
pub struct BindingTarget {
    pub type_desc: &'static TypeDescriptor,
}

/// 类型绑定上下文 trait：泛型参数名 → `BindingTarget`。
/// phase 3 的 `TypeBindingStack` 等结构将实现此 trait。
pub trait TypeBindingContext {
    fn lookup(&self, name: &str) -> Option<BindingTarget>;
}

// =========================================================================
// type_resolver — 类型解析器
//
// 对 `src/sema/type_resolver.zig` 的 Rust 移植。
// 职责：将 AST 类型节点 + type_args 绑定上下文解析为 TypeDescriptor。
//
// 与 Zig 原版的差异：
// - 所有函数为自由函数（非方法），因解析需要 `&AstArena` + `&mut SemaResult` 双输入，
//   无单一 self 持有状态。
// - `type_args` 使用 `&[&'static TypeDescriptor]`（切片 of 静态引用）替代 Zig 的
//   `[]const TypeDescriptor`（值切片），因 Rust 的 `TypeDescriptor` 含 trait object
//   不便 Copy。描述符均为 'static（静态表或 pool 泄漏），引用方式无额外开销。
// - `resolve_type_node_resolved` 的 alias 递归不再构造临时 TypeNode，而是提取
//   `resolve_named_type_resolved` 辅助函数按名递归，避免 AST arena 之外的临时节点。
// =========================================================================

/// 从 TypeNode 提取类型名（用于变量绑定的类型推断）。
///
/// 对 `&T` / `*T` 递归到 inner，对泛型返回基类名，对命名类型返回其名。
/// 其他类型节点返回 `None`。
pub fn type_name_from_node<'a>(
    type_ref: Option<AstTypeRef>,
    ast: &AstArena<'a>,
) -> Option<&'a str> {
    let type_ref = type_ref?;
    let tn = &ast.ty(type_ref).node;
    let effective = match tn {
        TypeNode::RefType { inner } | TypeNode::RawPtr { inner } => &ast.ty(*inner).node,
        _ => tn,
    };
    match effective {
        TypeNode::Named { name } => Some(name),
        TypeNode::Generic { name, .. } => Some(name),
        _ => None,
    }
}

/// 解析 TypeNode 为 TypeDescriptor（concrete 版本，不展开 alias/newtype 链）。
///
/// 优先级：type_args 绑定 → 内置标量/str/void → 用户自定义类型（getOrCreateRefDesc）。
/// `type_node` 为 `None` 时返回 `None`（无类型标注）。
pub fn resolve_type_node_concrete<'a>(
    type_ref: Option<AstTypeRef>,
    type_args: &[&'static TypeDescriptor],
    ast: &AstArena<'a>,
    sema_result: &mut SemaResult,
) -> Option<&'static TypeDescriptor> {
    let type_ref = type_ref?;
    let tn = &ast.ty(type_ref).node;
    Some(match tn {
        TypeNode::Named { name } => {
            // 1. 优先查 type_args 绑定（泛型类型参数，按 type_name 匹配）
            for &ta in type_args {
                if ta.type_name == *name {
                    return Some(ta);
                }
            }
            // 2. 内置标量/str/null/void
            if let Some(td) = type_descriptor_from_builtin_name(name) {
                return Some(td);
            }
            // 3. 用户自定义类型 → 创建具名描述符
            sema_result.get_or_create_ref_desc(name)
        }
        TypeNode::Generic { name, .. } => sema_result.get_or_create_ref_desc(name),
        TypeNode::Nullable { inner } => {
            return resolve_type_node_concrete(Some(*inner), type_args, ast, sema_result);
        }
        TypeNode::RefType { inner } => {
            let inner_name = type_name_from_node(Some(*inner), ast).unwrap_or("ref");
            sema_result.get_or_create_ref_desc(inner_name)
        }
        TypeNode::RawPtr { inner } => {
            let inner_name = type_name_from_node(Some(*inner), ast).unwrap_or("ptr");
            sema_result.get_or_create_ref_desc(inner_name)
        }
        TypeNode::Record { .. } => sema_result.get_or_create_ref_desc("record"),
        TypeNode::Function { .. } => sema_result.get_or_create_ref_desc("fn"),
        TypeNode::Array { .. } => sema_result.get_or_create_ref_desc("array"),
        TypeNode::SelfType => {
            // 查 type_args 中的 "Self" 绑定
            for &ta in type_args {
                if ta.type_name == "Self" {
                    return Some(ta);
                }
            }
            sema_result.get_or_create_ref_desc("Self")
        }
        TypeNode::KindAnnotated { inner, .. } => {
            return resolve_type_node_concrete(Some(*inner), type_args, ast, sema_result);
        }
    })
}

/// 按名解析类型（resolved 版本，含 alias/newtype 链展开）。
///
/// 优先级：type_args 绑定 → 内置标量/str/void → type_defs alias/newtype 递归 →
/// 用户自定义类型（getOrCreateRefDesc）。
/// 提取为独立函数以便 `resolve_type_node_resolved` 的 alias 递归调用，无需构造临时 TypeNode。
fn resolve_named_type_resolved(
    name: &str,
    type_args: &[&'static TypeDescriptor],
    sema_result: &mut SemaResult,
) -> &'static TypeDescriptor {
    // 1. 优先查 type_args 绑定（泛型类型参数）
    for &ta in type_args {
        if ta.type_name == name {
            return ta;
        }
    }
    // 2. 内置标量/str/null/void
    if let Some(td) = type_descriptor_from_builtin_name(name) {
        return td;
    }
    // 3. 查 type_defs 解析 alias/newtype 链
    //    提取所需信息（owned String）以释放不可变借用，允许后续 &mut sema_result 调用。
    let (target_desc, target_name): (Option<&'static TypeDescriptor>, Option<String>) =
        match sema_result.get_type_def(name) {
            Some(td) => (
                td.target_type_desc,
                td.target_type_name.as_deref().map(String::from),
            ),
            None => (None, None),
        };
    if let Some(inner_td) = target_desc {
        // alias/newtype 有目标 TypeDescriptor：直接返回
        return inner_td;
    }
    if let Some(ttn) = target_name {
        // target_type_name 已知：递归解析到最终具体类型
        // resolve_named_type_resolved 总是返回描述符（永不失败），无需 fallback
        return resolve_named_type_resolved(&ttn, type_args, sema_result);
    }
    // 4. 其他用户自定义类型 → 创建具名描述符
    sema_result.get_or_create_ref_desc(name)
}

/// 解析 TypeNode 为 TypeDescriptor（resolved 版本，含 alias/newtype 链展开）。
///
/// 与 `resolve_type_node_concrete` 的差异：Named 分支查询 `sema_result.type_defs`，
/// 若为 alias/newtype 且 target_type 已知，递归解析到具体标量类型。
/// 用于需要穿透 alias 链获取最终标量通道类型的场景（如 field_value 标量单态化）。
pub fn resolve_type_node_resolved<'a>(
    type_ref: Option<AstTypeRef>,
    type_args: &[&'static TypeDescriptor],
    ast: &AstArena<'a>,
    sema_result: &mut SemaResult,
) -> Option<&'static TypeDescriptor> {
    let type_ref = type_ref?;
    let tn = &ast.ty(type_ref).node;
    Some(match tn {
        TypeNode::Named { name } => resolve_named_type_resolved(name, type_args, sema_result),
        TypeNode::Generic { name, args } => {
            // Lazy<T>：递归解析内部类型
            if *name == "Lazy" && !args.is_empty() {
                if let Some(inner_td) =
                    resolve_type_node_resolved(Some(args[0]), type_args, ast, sema_result)
                {
                    return Some(inner_td);
                }
            }
            sema_result.get_or_create_ref_desc(name)
        }
        TypeNode::Nullable { inner } => {
            return resolve_type_node_resolved(Some(*inner), type_args, ast, sema_result);
        }
        TypeNode::RefType { inner } => {
            let inner_name = type_name_from_node(Some(*inner), ast).unwrap_or("ref");
            sema_result.get_or_create_ref_desc(inner_name)
        }
        TypeNode::RawPtr { inner } => {
            let inner_name = type_name_from_node(Some(*inner), ast).unwrap_or("ptr");
            sema_result.get_or_create_ref_desc(inner_name)
        }
        TypeNode::Record { .. } => sema_result.get_or_create_ref_desc("record"),
        TypeNode::Function { .. } => sema_result.get_or_create_ref_desc("fn"),
        TypeNode::Array { .. } => sema_result.get_or_create_ref_desc("array"),
        TypeNode::SelfType => {
            for &ta in type_args {
                if ta.type_name == "Self" {
                    return Some(ta);
                }
            }
            sema_result.get_or_create_ref_desc("Self")
        }
        TypeNode::KindAnnotated { inner, .. } => {
            return resolve_type_node_resolved(Some(*inner), type_args, ast, sema_result);
        }
    })
}

/// 类型名 → TypeDescriptor（无 type_args 上下文的简单查询）。
///
/// 标量/str/void 返回静态描述符；`T?` 尾缀递归去 `?`；其他用户类型创建具名描述符。
pub fn chan_type_from_type_name(name: &str, sema_result: &mut SemaResult) -> &'static TypeDescriptor {
    if let Some(td) = type_descriptor_from_builtin_name(name) {
        return td;
    }
    // nullable 类型 "T?" → 返回内部类型的 TypeDescriptor
    if name.len() > 1 && name.ends_with('?') {
        return chan_type_from_type_name(&name[..name.len() - 1], sema_result);
    }
    // 用户自定义类型（ADT/record/newtype）→ 创建具名描述符
    sema_result.get_or_create_ref_desc(name)
}

/// type_id → TypeDescriptor。
///
/// type_id=0 → "unknown" 具名描述符；1..=21 → 静态表；22+ → type_descriptors 全局表或 pool。
/// 未找到 → 创建 "unknown" 具名描述符（无回退到 ref_descriptor）。
pub fn chan_type_from_type_id(
    sema_result: &mut SemaResult,
    type_id: u16,
) -> &'static TypeDescriptor {
    if type_id == 0 {
        return sema_result.get_or_create_ref_desc("unknown");
    }
    // 标量描述符 (type_id 1-21)：静态表 + str/null/void
    if type_id <= 21 {
        if let Some(td) = lookup_by_type_id(type_id) {
            return td;
        }
    }
    // 动态描述符 (type_id 22+)：查 type_descriptors 全局表
    for &td in &sema_result.type_descriptors {
        if td.type_id == type_id {
            return td;
        }
    }
    // 查 type_desc_pool
    if let Some(td) = sema_result.type_desc_pool.get(type_id) {
        return td;
    }
    // 未找到 → 创建具名 "unknown" 描述符
    sema_result.get_or_create_ref_desc("unknown")
}

/// 带类型绑定的 TypeNode → TypeDescriptor 解析。
///
/// 优先级：TypeBindingContext（type_param 名）→ type_args 绑定 → 内置标量/str/void →
/// 用户自定义类型（getOrCreateRefDesc）。
pub fn chan_type_from_type_node_bound<'a>(
    type_ref: Option<AstTypeRef>,
    type_args: &[&'static TypeDescriptor],
    type_binding_ctx: Option<&dyn TypeBindingContext>,
    ast: &AstArena<'a>,
    sema_result: &mut SemaResult,
) -> Option<&'static TypeDescriptor> {
    let type_ref = type_ref?;
    let tn = &ast.ty(type_ref).node;
    Some(match tn {
        TypeNode::Named { name } => {
            // 1. 先查类型绑定栈（type_param 名）
            if let Some(ctx) = type_binding_ctx {
                if let Some(bt) = ctx.lookup(name) {
                    return Some(bt.type_desc);
                }
            }
            // 2. 查 type_args 绑定（泛型类型参数，按 type_name 匹配）
            for &ta in type_args {
                if ta.type_name == *name {
                    return Some(ta);
                }
            }
            // 3. 内置标量/str/null/void
            if let Some(td) = type_descriptor_from_builtin_name(name) {
                return Some(td);
            }
            // 4. 用户自定义类型 → 创建具名描述符
            sema_result.get_or_create_ref_desc(name)
        }
        TypeNode::Nullable { inner } => {
            return chan_type_from_type_node_bound(
                Some(*inner),
                type_args,
                type_binding_ctx,
                ast,
                sema_result,
            );
        }
        TypeNode::Generic { name, .. } => sema_result.get_or_create_ref_desc(name),
        TypeNode::RefType { inner } => {
            let inner_name = type_name_from_node(Some(*inner), ast).unwrap_or("ref");
            sema_result.get_or_create_ref_desc(inner_name)
        }
        TypeNode::RawPtr { inner } => {
            let inner_name = type_name_from_node(Some(*inner), ast).unwrap_or("ptr");
            sema_result.get_or_create_ref_desc(inner_name)
        }
        TypeNode::Record { .. } => sema_result.get_or_create_ref_desc("record"),
        TypeNode::Function { .. } => sema_result.get_or_create_ref_desc("fn"),
        TypeNode::Array { .. } => sema_result.get_or_create_ref_desc("array"),
        TypeNode::SelfType => {
            for &ta in type_args {
                if ta.type_name == "Self" {
                    return Some(ta);
                }
            }
            sema_result.get_or_create_ref_desc("Self")
        }
        TypeNode::KindAnnotated { inner, .. } => {
            return chan_type_from_type_node_bound(
                Some(*inner),
                type_args,
                type_binding_ctx,
                ast,
                sema_result,
            );
        }
    })
}

/// ConcreteType → TypeDescriptor。
///
/// 21 种内置标量 → 静态描述符；命名用户类型（adt/generic/trait）→ getOrCreateRefDesc；
/// 匿名复合类型（record/array/fn）→ 具名描述符；包装类型（nullable/ref/throw）→ 递归取内部；
/// type_var/unknown/never → `None`（无法静态确定）。
///
/// 取 `TypeHandle` 而非 `&ConcreteType` 作为输入，因复合类型的子类型以索引引用，
/// 需 `&TypeArena` 解引用子节点进行递归。这也与 DOD 模式一致，避免借用纠缠。
pub fn from_concrete_type(
    ty: TypeHandle,
    arena: &TypeArena,
    sema_result: &mut SemaResult,
) -> Option<&'static TypeDescriptor> {
    let ct = arena.get(arena.resolve(ty));
    // 内置标量：通过 builtin_type_id + lookup_by_type_id 获取静态描述符
    if let Some(tid) = ct.builtin_type_id() {
        return lookup_by_type_id(tid);
    }
    Some(match ct {
        ConcreteType::Adt { name, .. } | ConcreteType::Generic { name, .. } => {
            sema_result.get_or_create_ref_desc(name)
        }
        ConcreteType::Trait { name, .. } => sema_result.get_or_create_ref_desc(name),
        // 匿名复合类型 → 具名描述符
        ConcreteType::Record { .. } => sema_result.get_or_create_ref_desc("record"),
        ConcreteType::Array { .. } => sema_result.get_or_create_ref_desc("array"),
        ConcreteType::Fn { .. } => sema_result.get_or_create_ref_desc("fn"),
        // 包装类型：递归取内部，失败则用 "unknown" 具名描述符
        ConcreteType::Nullable(inner) => {
            return from_concrete_type(*inner, arena, sema_result)
                .or_else(|| Some(sema_result.get_or_create_ref_desc("unknown")));
        }
        ConcreteType::Ref { .. } => sema_result.get_or_create_ref_desc("ref"),
        ConcreteType::Throw { value_type, .. } => {
            return from_concrete_type(*value_type, arena, sema_result)
                .or_else(|| Some(sema_result.get_or_create_ref_desc("unknown")));
        }
        // 类型变量/未知/never：无法静态确定
        ConcreteType::TypeVar(_) | ConcreteType::Unknown | ConcreteType::Never => return None,
        // 21 种内置标量已由 builtin_type_id() 提前返回，此处不可达
        _ => unreachable!("builtin scalar types already handled by builtin_type_id()"),
    })
}

/// 注册 TypeDescriptor 到 `SemaResult.type_descriptors` 全局表（去重）。
pub fn register_type_descriptor(sema_result: &mut SemaResult, td: &'static TypeDescriptor) {
    for &existing in &sema_result.type_descriptors {
        if existing.type_id == td.type_id {
            return;
        }
    }
    sema_result.type_descriptors.push(td);
}

/// 注册所有内置标量 TypeDescriptor 到全局表。
/// 在 `collect_monomorph_instances` 开头调用一次。
pub fn register_builtin_type_descriptors(sema_result: &mut SemaResult) {
    // 内置标量 (type_id 1..=21)
    for type_id in 1..=21u16 {
        if let Some(td) = lookup_by_type_id(type_id) {
            register_type_descriptor(sema_result, td);
        }
    }
}

// =========================================================================
// inference — 类型推导核心
//
// 对 `src/sema/inference.zig` 的 Rust 移植。
// 职责：泛型实参反推、self 参数绑定、字面量提升、GADT 推断。
//
// 与 Zig 原版的差异（有意改进，用户确认）：
// - **self 参数强制 scope 绑定**：不再允许顶层 extension fun 的 `self: TypeName`。
//   self 只能在 type/trait 块内使用，且不允许类型注解。
//   Zig 原版的 3 层 fallback（scope→标注→fresh var）简化为 scope→error。
// - **字面量提升**：保留 Zig 语义，字面量与变量运算时提升到变量类型。
// - **泛型延迟求解**：保留 Zig 语义，未求解的 TypeVar 留待后续 unify。
//
// 绑定栈架构：
// - TypeBindingStack：泛型参数名 → TypeHandle（rigid var）
// - SelfBindingStack：Self → TypeHandle（scope 类型）
// 两栈同步 push/pop：进入 impl Type<T> 块时，T 入 TypeBindingStack，
// Type<T> 入 SelfBindingStack；离开时同步弹出。
// =========================================================================

/// 类型绑定栈帧：泛型参数名 → TypeHandle（通常为 rigid TypeVar）
#[derive(Debug, Default)]
pub struct TypeBindingFrame {
    bindings: HashMap<Box<str>, TypeHandle>,
}

impl TypeBindingFrame {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn insert(&mut self, name: &str, ty: TypeHandle) {
        self.bindings.insert(name.into(), ty);
    }

    pub fn get(&self, name: &str) -> Option<TypeHandle> {
        self.bindings.get(name).copied()
    }
}

/// 类型绑定栈：管理泛型实例化期间的类型参数绑定。
///
/// 进入 `impl Type<T>` 或 `fn method<U>` 时 push 一帧，离开时 pop。
/// `lookup` 从栈顶向下查找，内层绑定优先（shadowing 语义）。
///
/// 注意：此栈持有 `TypeHandle`（ConcreteType 索引），与 `TypeBindingContext` trait
/// 要求的 `TypeDescriptor` 不匹配。实际的类型解析通过 `InferContext::lookup_type_binding`
/// 完成，不实现 `TypeBindingContext` trait 以避免类型混淆。
#[derive(Debug, Default)]
pub struct TypeBindingStack {
    frames: Vec<TypeBindingFrame>,
}

impl TypeBindingStack {
    pub fn new() -> Self {
        Self::default()
    }

    /// 压入空帧，后续通过 `insert` 添加绑定。
    pub fn push(&mut self) {
        self.frames.push(TypeBindingFrame::new());
    }

    /// 压入预构造帧。
    pub fn push_frame(&mut self, frame: TypeBindingFrame) {
        self.frames.push(frame);
    }

    /// 弹出栈顶帧。
    pub fn pop(&mut self) -> Option<TypeBindingFrame> {
        self.frames.pop()
    }

    /// 当前栈深度。
    pub fn depth(&self) -> usize {
        self.frames.len()
    }

    /// 从栈顶向下查找类型参数绑定（内层优先）。
    pub fn lookup(&self, name: &str) -> Option<TypeHandle> {
        for frame in self.frames.iter().rev() {
            if let Some(ty) = frame.get(name) {
                return Some(ty);
            }
        }
        None
    }

    /// 在栈顶帧添加绑定（仅当栈非空）。
    pub fn insert_top(&mut self, name: &str, ty: TypeHandle) {
        if let Some(frame) = self.frames.last_mut() {
            frame.insert(name, ty);
        }
    }
}

/// Self 绑定栈：管理 type/trait 块的 Self 类型绑定。
///
/// 进入 `type T { ... }` 块时 push `T` 的 TypeHandle；
/// 进入 `trait Foo<T> { default methods }` 时 push fresh_type_var；
/// 离开时 pop。`lookup` 返回栈顶（内层优先）。
#[derive(Debug, Default)]
pub struct SelfBindingStack {
    stack: Vec<TypeHandle>,
}

impl SelfBindingStack {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn push(&mut self, self_ty: TypeHandle) {
        self.stack.push(self_ty);
    }

    pub fn pop(&mut self) -> Option<TypeHandle> {
        self.stack.pop()
    }

    pub fn current(&self) -> Option<TypeHandle> {
        self.stack.last().copied()
    }

    pub fn depth(&self) -> usize {
        self.stack.len()
    }
}

/// 推导上下文：封装类型推导所需的所有状态。
///
/// 生命周期：整个模块的 sema 阶段共享一个 TypeArena，InferContext 持有 &mut 引用。
/// type_binding_stack 和 self_binding_stack 随 impl/trait/fn 块进出而 push/pop。
/// env 为局部变量环境（EnvArena），expected_return 用于反向推导 return 类型。
pub struct InferContext<'a> {
    pub arena: &'a mut TypeArena,
    pub sema_result: &'a mut SemaResult,
    pub type_binding_stack: TypeBindingStack,
    pub self_binding_stack: SelfBindingStack,
    pub env: EnvArena,
    /// 当前函数的期望返回类型（用于反向推导 throw 表达式等）
    pub expected_return: Option<TypeHandle>,
    /// sema v2: 约束求解器（延迟求解 + snapshot/rollback）
    pub solver: ConstraintSolver,
    /// sema v2: flow-sensitive narrowing 上下文（path-sensitive 类型精化）
    pub flow_ctx: FlowContext,
    /// sema v2: witness table（trait 实现的静态分派表）
    pub witness_table: WitnessTable,
}

impl<'a> InferContext<'a> {
    pub fn new(arena: &'a mut TypeArena, sema_result: &'a mut SemaResult) -> Self {
        InferContext {
            arena,
            sema_result,
            type_binding_stack: TypeBindingStack::new(),
            self_binding_stack: SelfBindingStack::new(),
            env: EnvArena::new(),
            expected_return: None,
            solver: ConstraintSolver::new(),
            flow_ctx: FlowContext::new(),
            witness_table: WitnessTable::new(),
        }
    }

    // ── 类型绑定栈操作 ──

    /// 进入泛型作用域：为每个类型参数分配 rigid var 并压栈。
    pub fn push_type_bindings(&mut self, type_params: &[(&str,)]) {
        self.type_binding_stack.push();
        for &(name,) in type_params {
            let var = self.arena.fresh_rigid_var();
            self.type_binding_stack.insert_top(name, var);
        }
    }

    /// 离开泛型作用域：弹出栈顶帧。
    pub fn pop_type_bindings(&mut self) {
        self.type_binding_stack.pop();
    }

    /// 查询类型参数绑定。
    pub fn lookup_type_binding(&self, name: &str) -> Option<TypeHandle> {
        self.type_binding_stack.lookup(name)
    }

    // ── Self 绑定栈操作 ──

    /// 进入 type 块：Self 绑定到具体类型。
    /// `self_ty` 应为 `Adt { name, type_args }` 形式，type_args 引用 TypeBindingStack 中的 var。
    pub fn push_self_type(&mut self, self_ty: TypeHandle) {
        self.self_binding_stack.push(self_ty);
    }

    /// 进入 trait 默认方法：Self 绑定到 fresh_type_var（待 impl 时 unify 求解）。
    pub fn push_self_type_var(&mut self) -> TypeHandle {
        let var = self.arena.fresh_type_var();
        self.self_binding_stack.push(var);
        var
    }

    /// 离开 type/trait 块：弹出 Self 绑定。
    pub fn pop_self_type(&mut self) {
        self.self_binding_stack.pop();
    }

    /// 当前 Self 类型（栈顶）。
    pub fn current_self_type(&self) -> Option<TypeHandle> {
        self.self_binding_stack.current()
    }

    // ── 错误记录 ──

    pub fn add_error(&mut self, message: &str) {
        // line=0/column=0 表示无位置信息（sema 推导阶段尚未关联 AST 位置）
        self.sema_result.add_error(SemaError::new(message, 0, 0));
    }

    // ── self 参数解析（phase3b）──

    /// 解析 self 参数的类型。
    ///
    /// **语义规则（Rust 移植版，有意改进）**：
    /// - `self` 只能在 type/trait 块内的方法中使用（SelfBindingStack 非空）
    /// - `self` 参数不允许类型注解（解析器自动填 SelfType 或 RefType<SelfType>）
    /// - 顶层 fun 写 self 参数 → 报错
    /// - self 参数有显式 `: Type` 注解 → 报错
    ///
    /// **返回值**：
    /// - `self`（无注解，type 块内）→ scope 类型
    /// - `&self`（无注解，type 块内）→ `Ref<scope类型>`
    /// - 非法用法 → 报错并返回 fresh_type_var（错误恢复）
    pub fn infer_self_param(
        &mut self,
        type_annotation: Option<AstTypeRef>,
        ast: &AstArena<'_>,
    ) -> TypeHandle {
        let self_ty = match self.current_self_type() {
            Some(ty) => ty,
            None => {
                self.add_error("self parameter requires enclosing type or trait block");
                return self.arena.fresh_type_var();
            }
        };

        // 检查类型注解：self 参数不允许显式注解
        // 解析器对 `self`（无 `:`）自动填 SelfType，对 `&self` 填 RefType<SelfType>
        // 用户写 `self: Foo` 走 parse_param 的 `:` 分支，type_annotation 为用户类型
        match type_annotation {
            None => {
                // 无注解（理论上不会出现，解析器总为 self 填充）
                self_ty
            }
            Some(ta) => {
                let tn = &ast.ty(ta).node;
                match tn {
                    // `self`（解析器自动填 SelfType）→ 返回 scope 类型
                    TypeNode::SelfType => self_ty,
                    // `&self`（解析器自动填 RefType<SelfType>）→ 返回 Ref<scope类型>
                    TypeNode::RefType { inner } => {
                        if matches!(ast.ty(*inner).node, TypeNode::SelfType) {
                            let ref_ty = self.arena.make(ConcreteType::Ref {
                                inner: self_ty,
                                is_raw: false,
                            });
                            ref_ty
                        } else {
                            // `&self: &Foo` 用户显式写引用注解 → 报错
                            self.add_error(
                                "self parameter does not allow explicit type annotation",
                            );
                            self.arena.fresh_type_var()
                        }
                    }
                    // `self: Foo` 用户显式写注解 → 报错
                    _ => {
                        self.add_error("self parameter does not allow explicit type annotation");
                        self.arena.fresh_type_var()
                    }
                }
            }
        }
    }

    /// 检查顶层 fun 的参数是否非法使用 self。
    ///
    /// **语义规则**：顶层 fun（不在 type/trait 块内）不允许 self 参数。
    /// 调用方在处理 FunDecl 的 params 时，对每个名为 "self" 的参数调用此方法。
    pub fn check_top_level_self_param(&mut self, param_name: &str) {
        if param_name == "self" {
            self.add_error("self parameter is not allowed in top-level function");
        }
    }

    // ── 泛型调用推导（phase3c）──

    /// 推导泛型函数调用的类型参数绑定。
    ///
    /// **算法**（保留 Zig 延迟求解语义）：
    /// 1. 为每个泛型参数（按 `generic_params` 顺序）分配 fresh 非刚性 TypeVar
    /// 2. 构建 rigid var idx → fresh var 的替换映射
    /// 3. substitute 形参类型后与实参 unify，求解 fresh var
    /// 4. 未求解的 fresh var 保留（延迟到后续 unify 或最终报错）
    ///
    /// **参数**：
    /// - `generic_params`：形参声明中的泛型参数 TypeHandle 列表（rigid var），按函数声明顺序
    /// - `param_types`：形参类型列表（其中引用了 generic_params 中的 rigid var）
    /// - `arg_types`：实参类型列表
    ///
    /// **返回值**：`Some(Vec<TypeHandle>)` 表示推导的类型实参列表（与 generic_params 等长）；
    /// `None` 表示非泛型函数。
    pub fn infer_call_type_args(
        &mut self,
        generic_params: &[TypeHandle],
        param_types: &[TypeHandle],
        arg_types: &[TypeHandle],
    ) -> Option<Vec<TypeHandle>> {
        if generic_params.is_empty() {
            return None;
        }

        // 1. 为每个泛型参数分配 fresh 非刚性 TypeVar，建立 rigid idx → fresh var 映射
        let mut subst: HashMap<u32, TypeHandle> = HashMap::new();
        let type_args: Vec<TypeHandle> = generic_params
            .iter()
            .map(|&rigid_ty| {
                let fresh = self.arena.fresh_type_var();
                let resolved = self.arena.resolve(rigid_ty);
                if let ConcreteType::TypeVar(idx) = self.arena.get(resolved) {
                    subst.insert(*idx, fresh);
                }
                fresh
            })
            .collect();

        // 2. unify 实参与形参（形参已通过 subst 替换为非刚性 var）
        let n = param_types.len().min(arg_types.len());
        for i in 0..n {
            let param_ty = self.substitute_type(param_types[i], &subst);
            let arg_ty = arg_types[i];
            // unify 忽略错误（延迟求解，后续可能通过其他路径求解）
            let _ = self.arena.unify(param_ty, arg_ty);
        }

        // 3. resolve 所有 TypeVar（未绑定的保持 TypeVar）
        let mut result: Vec<TypeHandle> = Vec::with_capacity(type_args.len());
        for &ta in type_args.iter() {
            result.push(self.arena.resolve(ta));
        }

        Some(result)
    }

    /// 递归收集类型中的所有 TypeVar idx，填入 subst（值为占位 TypeHandle(0)，仅用 key）。
    #[allow(dead_code)]
    fn collect_type_vars(&self, ty: TypeHandle, subst: &mut HashMap<u32, TypeHandle>) {
        let resolved = self.arena.resolve(ty);
        match self.arena.get(resolved) {
            ConcreteType::TypeVar(idx) => {
                subst.entry(*idx).or_insert(TypeHandle(0));
            }
            ConcreteType::Fn { params, return_type } => {
                for &p in params.iter() {
                    self.collect_type_vars(p, subst);
                }
                self.collect_type_vars(*return_type, subst);
            }
            ConcreteType::Record { fields, .. } => {
                for f in fields.iter() {
                    self.collect_type_vars(f.ty, subst);
                }
            }
            ConcreteType::Adt { type_args, .. } => {
                for &a in type_args.iter() {
                    self.collect_type_vars(a, subst);
                }
            }
            ConcreteType::Nullable(inner) => self.collect_type_vars(*inner, subst),
            ConcreteType::Ref { inner, .. } => self.collect_type_vars(*inner, subst),
            ConcreteType::Generic { args, .. } => {
                for &a in args.iter() {
                    self.collect_type_vars(a, subst);
                }
            }
            ConcreteType::Array { element_type, .. } => {
                self.collect_type_vars(*element_type, subst)
            }
            ConcreteType::Throw { value_type, error_type } => {
                self.collect_type_vars(*value_type, subst);
                self.collect_type_vars(*error_type, subst);
            }
            ConcreteType::Trait { type_args, .. } => {
                for &a in type_args.iter() {
                    self.collect_type_vars(a, subst);
                }
            }
            _ => {}
        }
    }

    /// 类型替换：将类型中的指定 TypeVar（按 idx）替换为绑定表中的类型。
    ///
    /// 递归遍历复合类型，替换匹配的 TypeVar。用于将形参的 rigid var 替换为
    /// 调用点的 fresh 非刚性 var，使其可被 unify 绑定。
    fn substitute_type(&mut self, ty: TypeHandle, subst: &HashMap<u32, TypeHandle>) -> TypeHandle {
        let resolved = self.arena.resolve(ty);
        match self.arena.get(resolved).clone() {
            ConcreteType::TypeVar(idx) => {
                // 命中替换表 → 返回替换类型；否则保持原样
                subst.get(&idx).copied().unwrap_or(resolved)
            }
            ConcreteType::Fn { params, return_type } => {
                let new_params: Vec<TypeHandle> = params
                    .iter()
                    .map(|&p| self.substitute_type(p, subst))
                    .collect();
                let new_ret = self.substitute_type(return_type, subst);
                self.arena.make(ConcreteType::Fn {
                    params: new_params.into_boxed_slice(),
                    return_type: new_ret,
                })
            }
            ConcreteType::Record { fields, name } => {
                let new_fields: Vec<FieldType> = fields
                    .iter()
                    .map(|f| FieldType {
                        name: f.name.clone(),
                        ty: self.substitute_type(f.ty, subst),
                    })
                    .collect();
                self.arena.make(ConcreteType::Record {
                    fields: new_fields.into_boxed_slice(),
                    name,
                })
            }
            ConcreteType::Adt { name, type_args } => {
                let new_args: Vec<TypeHandle> = type_args
                    .iter()
                    .map(|&a| self.substitute_type(a, subst))
                    .collect();
                self.arena.make(ConcreteType::Adt {
                    name,
                    type_args: new_args.into_boxed_slice(),
                })
            }
            ConcreteType::Nullable(inner) => {
                let new_inner = self.substitute_type(inner, subst);
                self.arena.make(ConcreteType::Nullable(new_inner))
            }
            ConcreteType::Generic { name, args } => {
                let new_args: Vec<TypeHandle> = args
                    .iter()
                    .map(|&a| self.substitute_type(a, subst))
                    .collect();
                self.arena.make(ConcreteType::Generic {
                    name,
                    args: new_args.into_boxed_slice(),
                })
            }
            ConcreteType::Array { element_type, size } => {
                let new_elem = self.substitute_type(element_type, subst);
                self.arena.make(ConcreteType::Array {
                    element_type: new_elem,
                    size,
                })
            }
            ConcreteType::Throw { value_type, error_type } => {
                let new_v = self.substitute_type(value_type, subst);
                let new_e = self.substitute_type(error_type, subst);
                self.arena.make(ConcreteType::Throw {
                    value_type: new_v,
                    error_type: new_e,
                })
            }
            ConcreteType::Trait { name, type_args } => {
                let new_args: Vec<TypeHandle> = type_args
                    .iter()
                    .map(|&a| self.substitute_type(a, subst))
                    .collect();
                self.arena.make(ConcreteType::Trait {
                    name,
                    type_args: new_args.into_boxed_slice(),
                })
            }
            ConcreteType::Ref { inner, is_raw } => {
                let new_inner = self.substitute_type(inner, subst);
                self.arena.make(ConcreteType::Ref {
                    inner: new_inner,
                    is_raw,
                })
            }
            // 标量、Never、Unknown、Void、Null 等无子节点 → 原样返回
            _ => resolved,
        }
    }

    // ── 字面量提升 ──
    // v2 收敛：literal_promotion 已由 peer_type_binary 替代，
    // 字面量提升规则内化到 peer_type_binary 中，消除双轨制。

    // ── GADT 推断（phase3e）──

    /// 对构造器模式进行 GADT 类型精化。
    ///
    /// **语义**（移植自 `src/sema/gadt_check.zig` refineConstructorPattern）：
    /// 1. 从 sema_result 查找构造器定义（CtorDefInfo）
    /// 2. 将构造器返回类型与 expected_ty unify，实现类型变量精化
    /// 3. 对子模式按构造器字段类型递归推断
    ///
    /// **返回值**：`true` 表示已由本函数处理（构造器已注册）；
    /// `false` 表示构造器未注册，交由常规模式推断处理。
    ///
    /// **Throw 错误构造器特例**：当 expected_ty 是 Throw 类型且构造器返回类型是
    /// error_newtype ADT 时，构造器作为 Throw 错误分支，子模式绑定到 error_type。
    pub fn refine_constructor_pattern(
        &mut self,
        ctor_name: &str,
        sub_patterns: &[PatternRef],
        expected_ty: TypeHandle,
        ast: &AstArena<'_>,
    ) -> bool {
        let resolved_expected = self.arena.resolve(expected_ty);

        // 先克隆构造器信息，避免 &CtorDefInfo 借用阻塞后续 &mut self 调用
        let ctor_info: Option<(Box<str>, bool, Option<AstTypeRef>, Box<[Option<AstTypeRef>]>)> =
            self.find_ctor_def(ctor_name).map(|c| {
                (
                    c.type_name.clone(),
                    c.is_newtype,
                    c.return_type_node,
                    c.field_type_nodes.clone(),
                )
            });

        // Throw 错误构造器特例：expected_ty 是 Throw 类型时，
        // 检查构造器是否是 error_newtype ADT 构造器
        if let ConcreteType::Throw { .. } = self.arena.get(resolved_expected).clone() {
            if let Some((_, is_newtype, _, _)) = &ctor_info {
                if *is_newtype {
                    // error_newtype 构造器作为 Throw 错误分支
                    // 子模式绑定到 error_type（整个 ADT 类型）
                    // 完整实现需 infer_pattern，此处仅标记已处理
                    let _ = (sub_patterns, ast);
                    return true;
                }
            }
        }

        // 常规构造器处理
        let (type_name, _is_newtype, return_type_node, field_type_nodes) = match ctor_info {
            Some(info) => info,
            None => return false,
        };

        // 解析构造器返回类型（GADT 用 return_type_node，普通 ADT 用 type_name）
        let ctor_return_ty = if let Some(rtn) = return_type_node {
            self.resolve_type_node_to_handle(rtn, ast)
        } else {
            // 普通 ADT：返回类型为 type_name 对应的 Adt
            self.arena.make(ConcreteType::Adt {
                name: type_name,
                type_args: Box::new([]),
            })
        };

        // unify 构造器返回类型与期望类型，实现 GADT 类型精化
        // unify 忽略错误（类型不匹配时由后续检查报错）
        let _ = self.arena.unify(ctor_return_ty, expected_ty);

        // 对子模式按构造器字段类型递归推断
        // 简化实现：仅为每个子模式分配期望类型，完整递归需 infer_pattern
        for (i, _sub_pat) in sub_patterns.iter().enumerate() {
            if i < field_type_nodes.len() {
                if let Some(ftn) = field_type_nodes[i] {
                    let _field_ty = self.resolve_type_node_to_handle(ftn, ast);
                    // 完整实现：self.infer_pattern(*sub_pat, field_ty, ast)
                }
            }
        }

        true
    }

    /// 从 sema_result 查找构造器定义（按名称）。
    fn find_ctor_def(&self, ctor_name: &str) -> Option<&CtorDefInfo> {
        self.sema_result.get_ctor_def(ctor_name)
    }

    /// 将 AST TypeNode 解析为 TypeHandle（简化版，用于 GADT）。
    ///
    /// 完整实现应调用 type_resolver 的 resolve_type_node_concrete，
    /// 此处简化为基本类型映射，避免引入循环依赖。
    fn resolve_type_node_to_handle(
        &mut self,
        type_ref: AstTypeRef,
        ast: &AstArena<'_>,
    ) -> TypeHandle {
        let tn = &ast.ty(type_ref).node;
        match tn {
            TypeNode::SelfType => self
                .current_self_type()
                .unwrap_or_else(|| self.arena.fresh_type_var()),
            TypeNode::Named { name } => {
                // 内置标量
                match *name {
                    "i8" => self.arena.make(ConcreteType::I8),
                    "i16" => self.arena.make(ConcreteType::I16),
                    "i32" => self.arena.make(ConcreteType::I32),
                    "i64" => self.arena.make(ConcreteType::I64),
                    "i128" => self.arena.make(ConcreteType::I128),
                    "u8" => self.arena.make(ConcreteType::U8),
                    "u16" => self.arena.make(ConcreteType::U16),
                    "u32" => self.arena.make(ConcreteType::U32),
                    "u64" => self.arena.make(ConcreteType::U64),
                    "u128" => self.arena.make(ConcreteType::U128),
                    "isize" => self.arena.make(ConcreteType::Isize),
                    "usize" => self.arena.make(ConcreteType::Usize),
                    "f16" => self.arena.make(ConcreteType::F16),
                    "f32" => self.arena.make(ConcreteType::F32),
                    "f64" => self.arena.make(ConcreteType::F64),
                    "f128" => self.arena.make(ConcreteType::F128),
                    "bool" => self.arena.make(ConcreteType::Bool),
                    "str" => self.arena.make(ConcreteType::Str),
                    "char" => self.arena.make(ConcreteType::Char),
                    "Null" => self.arena.make(ConcreteType::Null),
                    "void" => self.arena.make(ConcreteType::Void),
                    // 其他命名类型 → 查 TypeBindingStack 或构造 Adt
                    other => {
                        if let Some(ty) = self.lookup_type_binding(other) {
                            ty
                        } else {
                            self.arena.make(ConcreteType::Adt {
                                name: (*other).into(),
                                type_args: Box::new([]),
                            })
                        }
                    }
                }
            }
            TypeNode::RefType { inner } => {
                let inner_ty = self.resolve_type_node_to_handle(*inner, ast);
                self.arena.make(ConcreteType::Ref {
                    inner: inner_ty,
                    is_raw: false,
                })
            }
            _ => self.arena.fresh_type_var(),
        }
    }
}

// =========================================================================
// populate — 从 AST 填充 SemaResult 定义表
//
// 对 `src/sema/populate.zig` 的 Rust 移植。
// 职责：遍历模块声明，分发到对应的转换函数，填充 type_defs/func_sigs/trait_defs。
//
// 与 Zig 原版的差异：
// - 去掉 arena_alloc 参数：Rust 用 Box<[T]> / Vec<T> 自有数据
// - anytype 参数 → 具体类型（Decl 变体解构）
// - *const TypeNode → TypeRef + &AstArena 解引用
// - orelse ... catch unreachable → unwrap_or_else
// - 无 _force_analysis（Rust 无懒分析）
//
// 依赖：单向依赖 crate::Ast（Module/Decl/TypeNode 等）+ 已有的 SemaResult put 方法
// =========================================================================

use crate::Ast::{
    ConstructorDef, RecordFieldType, TypeDef as AstTypeDef,
};

/// populate 主入口：遍历模块声明，填充 SemaResult 的定义表。
///
/// 遍历 `module.declarations`，按声明类型分发：
/// - `Decl::FunDecl` → `ast_fun_decl_to_func_sig`
/// - `Decl::TypeDecl` → `ast_type_decl_to_type_def`
/// - `Decl::TraitDecl` → `ast_trait_decl_to_trait_def`
/// - 其他（ImportDecl/PackDecl/ExprDecl）→ 跳过
///
/// 返回 false 表示有重复定义错误（put 方法返回 false 时记录）。
pub fn populate_sema_result_from_ast<'a>(
    sema_result: &mut SemaResult,
    decl: &'a crate::Ast::Spanned<Decl<'a>>,
    ast: &AstArena<'a>,
) -> bool {
    match &decl.node {
        Decl::FunDecl { name, type_params, params, return_type, is_async, .. } => {
            ast_fun_decl_to_func_sig(sema_result, name, type_params, params, *return_type, *is_async, ast)
        }
        Decl::TypeDecl { name, type_params, def, .. } => {
            ast_type_decl_to_type_def(sema_result, name, type_params, def, ast)
        }
        Decl::TraitDecl { name, methods, .. } => {
            ast_trait_decl_to_trait_def(sema_result, name, methods, ast)
        }
        _ => true, // ImportDecl/PackDecl/ExprDecl 跳过
    }
}

/// 遍历模块的所有声明，批量填充 SemaResult。
///
/// 便捷封装：对 `module.declarations` 中每个声明调用 `populate_sema_result_from_ast`。
/// 任一声明填充失败（返回 false）则整体返回 false。
pub fn populate_module<'a>(
    sema_result: &mut SemaResult,
    module: &'a crate::Ast::Module<'a>,
) -> bool {
    let mut ok = true;
    for decl in &module.declarations {
        if !populate_sema_result_from_ast(sema_result, decl, &module.arena) {
            ok = false;
        }
    }
    ok
}

// ── 私有转换函数 ──

/// fun_decl → FuncSigInfo，注册到 sema_result.func_sigs。
fn ast_fun_decl_to_func_sig<'a>(
    sema_result: &mut SemaResult,
    name: &'a str,
    type_params: &[crate::Ast::TypeParam<'a>],
    params: &[crate::Ast::Param<'a>],
    return_type: Option<AstTypeRef>,
    is_async: bool,
    ast: &AstArena<'a>,
) -> bool {
    let name: Box<str> = name.into();

    // type_params：取每个 TypeParam 的 name
    let type_params: Box<[Box<str>]> = type_params.iter().map(|tp| tp.name.into()).collect();

    // param_type_descs：解析每个参数的类型注解
    let mut param_type_descs: Vec<&'static TypeDescriptor> = Vec::with_capacity(params.len());
    let mut param_is_ref: Vec<bool> = Vec::with_capacity(params.len());
    let mut param_type_names: Vec<Option<Box<str>>> = Vec::with_capacity(params.len());

    for param in params {
        let (desc, is_ref, name) = resolve_param_type(param, ast, sema_result);
        param_type_descs.push(desc);
        param_is_ref.push(is_ref);
        param_type_names.push(name);
    }

    // return_type_desc + is_throwing
    let (return_type_desc, is_throwing) = match return_type {
        Some(rt) => {
            let desc = resolve_type_node_to_desc(rt, ast, sema_result);
            (desc, is_throw_type(&ast.ty(rt).node))
        }
        None => (sema_result.get_or_create_ref_desc("void"), false),
    };

    // return_is_ref：返回类型为 RefType 即为 true
    let return_is_ref = match return_type {
        Some(rt) => matches!(ast.ty(rt).node, TypeNode::RefType { .. }),
        None => false,
    };

    let sig = FuncSigInfo {
        name,
        type_params,
        param_type_descs: param_type_descs.into_boxed_slice(),
        return_type_desc,
        param_is_ref: param_is_ref.into_boxed_slice(),
        return_is_ref,
        is_async,
        is_throwing,
        param_type_names: param_type_names.into_boxed_slice(),
    };

    sema_result.put_func_sig(sig)
}

/// trait_decl → TraitDefInfo，注册到 sema_result.trait_defs。
fn ast_trait_decl_to_trait_def<'a>(
    sema_result: &mut SemaResult,
    name: &'a str,
    methods: &[crate::Ast::MethodDecl<'a>],
    ast: &AstArena<'a>,
) -> bool {
    let name: Box<str> = name.into();

    let methods: Vec<TraitMethodSig> = methods
        .iter()
        .map(|m| {
            let return_type_desc = match m.return_type {
                Some(rt) => resolve_type_node_to_desc(rt, ast, sema_result),
                None => sema_result.get_or_create_ref_desc("void"),
            };
            TraitMethodSig {
                name: m.name.into(),
                param_count: m.params.len() as u8,
                return_type_desc,
                is_async: m.is_async,
                has_body: m.body.is_some(),
            }
        })
        .collect();

    let trait_def = TraitDefInfo {
        name,
        methods: methods.into_boxed_slice(),
    };

    sema_result.put_trait_def(trait_def)
}

/// type_decl → TypeDefInfo，按 5 种 def 变体分发，注册到 sema_result.type_defs。
fn ast_type_decl_to_type_def<'a>(
    sema_result: &mut SemaResult,
    name: &'a str,
    type_params: &[crate::Ast::TypeParam<'a>],
    def: &AstTypeDef<'a>,
    ast: &AstArena<'a>,
) -> bool {
    let name: Box<str> = name.into();
    let type_params: Box<[Box<str>]> = type_params.iter().map(|tp| tp.name.into()).collect();

    let (kind, constructors, target_type_name, target_type_desc) = match def {
        AstTypeDef::Adt { constructors: ctor_defs } => {
            let ctors: Vec<CtorDefInfo> = ctor_defs
                .iter()
                .map(|c| constructor_def_to_ctor_info(c, name.as_ref(), ast, sema_result))
                .collect();
            (TypeDefKind::Adt, ctors, None, None)
        }
        AstTypeDef::Record { fields } => {
            let ctor = record_fields_to_ctor_info(fields, name.as_ref(), ast, sema_result);
            (TypeDefKind::Record, vec![ctor], None, None)
        }
        AstTypeDef::Alias { target } => {
            let target_desc = resolve_type_node_to_desc(*target, ast, sema_result);
            let target_name = type_name_from_type_node(&ast.ty(*target).node);
            (
                TypeDefKind::Alias,
                Vec::new(),
                target_name.map(|n| n.into()),
                Some(target_desc),
            )
        }
        AstTypeDef::Newtype { name: nt_name, inner } => {
            let target_desc = resolve_type_node_to_desc(*inner, ast, sema_result);
            let target_name = type_name_from_type_node(&ast.ty(*inner).node);
            let ctor = CtorDefInfo {
                name: (*nt_name).into(),
                type_name: name.clone(),
                field_names: Box::new([Some("_0".into())]),
                field_type_descs: Box::new([target_desc]),
                field_type_names: Box::new([target_name.map(|n| n.into())]),
                is_newtype: true,
                return_type_name: None,
                return_type_node: None,
                field_type_nodes: Box::new([Some(*inner)]),
            };
            (
                TypeDefKind::Newtype,
                vec![ctor],
                target_name.map(|n| n.into()),
                Some(target_desc),
            )
        }
        AstTypeDef::ErrorNewtype { name: en_name, params } => {
            let mut field_names: Vec<Option<Box<str>>> = Vec::with_capacity(params.len());
            let mut field_type_descs: Vec<&'static TypeDescriptor> =
                Vec::with_capacity(params.len());
            let mut field_type_names: Vec<Option<Box<str>>> = Vec::with_capacity(params.len());
            let mut field_type_nodes: Vec<Option<AstTypeRef>> = Vec::with_capacity(params.len());

            for p in params {
                field_names.push(Some(p.name.into()));
                let (desc, _is_ref, name) = resolve_param_type(p, ast, sema_result);
                field_type_descs.push(desc);
                field_type_names.push(name);
                field_type_nodes.push(p.type_annotation);
            }

            let ctor = CtorDefInfo {
                name: (*en_name).into(),
                type_name: name.clone(),
                field_names: field_names.into_boxed_slice(),
                field_type_descs: field_type_descs.into_boxed_slice(),
                field_type_names: field_type_names.into_boxed_slice(),
                is_newtype: true,
                return_type_name: None,
                return_type_node: None,
                field_type_nodes: field_type_nodes.into_boxed_slice(),
            };
            (TypeDefKind::ErrorNewtype, vec![ctor], None, None)
        }
    };

    let type_def = TypeDefInfo {
        name,
        kind,
        constructors: constructors.into_boxed_slice(),
        type_params,
        target_type_name,
        target_type_desc,
    };

    sema_result.put_type_def(type_def)
}

// ── 辅助函数 ──

/// 解析参数类型：返回 (TypeDescriptor, is_ref, type_name)
fn resolve_param_type<'a>(
    param: &crate::Ast::Param<'a>,
    ast: &AstArena<'a>,
    sema_result: &mut SemaResult,
) -> (&'static TypeDescriptor, bool, Option<Box<str>>) {
    match param.type_annotation {
        Some(tr) => {
            let node = &ast.ty(tr).node;
            let is_ref = matches!(node, TypeNode::RefType { .. });
            let desc = resolve_type_node_to_desc(tr, ast, sema_result);
            let name = type_name_from_type_node(node).map(|n| n.into());
            (desc, is_ref, name)
        }
        None => (
            sema_result.get_or_create_ref_desc("param"),
            false,
            None,
        ),
    }
}

/// 将 TypeNode 解析为 TypeDescriptor（委托 Sema::resolve_type_node_concrete）。
fn resolve_type_node_to_desc<'a>(
    type_ref: AstTypeRef,
    ast: &AstArena<'a>,
    sema_result: &mut SemaResult,
) -> &'static TypeDescriptor {
    match resolve_type_node_concrete(Some(type_ref), &[], ast, sema_result) {
        Some(td) => td,
        None => sema_result.get_or_create_ref_desc("unknown"),
    }
}

/// 判断 TypeNode 是否为 `Throw<T, E>` 类型。
///
/// Throw 在 TypeNode 中表示为 `Generic { name: "Throw", args: [V, E] }`。
fn is_throw_type(tn: &TypeNode) -> bool {
    matches!(tn, TypeNode::Generic { name, .. } if *name == "Throw")
}

/// 从 TypeNode 提取类型名（包装类型递归取内层）。
///
/// - Named → Some(name)
/// - Generic → Some(name)
/// - Nullable/RefType/RawPtr → 递归 inner
/// - KindAnnotated → 递归 inner
/// - 其他 → None
fn type_name_from_type_node<'a>(tn: &TypeNode<'a>) -> Option<&'a str> {
    match tn {
        TypeNode::Named { name } => Some(*name),
        TypeNode::Generic { name, .. } => Some(*name),
        TypeNode::Nullable { inner }
        | TypeNode::RefType { inner }
        | TypeNode::RawPtr { inner }
        | TypeNode::KindAnnotated { inner, .. } => {
            // 递归取内层（此处需 AstArena，但 type_name_from_type_node 仅接收 &TypeNode）
            // 简化：对包装类型不递归，返回 None（与 Zig 原版行为一致，仅顶层命名）
            // 完整递归需改为接收 &AstArena 参数
            let _ = inner;
            None
        }
        _ => None,
    }
}

/// 将 ConstructorDef 转为 CtorDefInfo。
fn constructor_def_to_ctor_info<'a>(
    c: &ConstructorDef<'a>,
    type_name: &str,
    ast: &AstArena<'a>,
    sema_result: &mut SemaResult,
) -> CtorDefInfo {
    let mut field_names: Vec<Option<Box<str>>> = Vec::with_capacity(c.fields.len());
    let mut field_type_descs: Vec<&'static TypeDescriptor> = Vec::with_capacity(c.fields.len());
    let mut field_type_names: Vec<Option<Box<str>>> = Vec::with_capacity(c.fields.len());
    let mut field_type_nodes: Vec<Option<AstTypeRef>> = Vec::with_capacity(c.fields.len());

    for f in &c.fields {
        field_names.push(f.name.map(|n| n.into()));
        let desc = resolve_type_node_to_desc(f.ty, ast, sema_result);
        field_type_descs.push(desc);
        field_type_names.push(type_name_from_type_node(&ast.ty(f.ty).node).map(|n| n.into()));
        field_type_nodes.push(Some(f.ty));
    }

    CtorDefInfo {
        name: c.name.into(),
        type_name: type_name.into(),
        field_names: field_names.into_boxed_slice(),
        field_type_descs: field_type_descs.into_boxed_slice(),
        field_type_names: field_type_names.into_boxed_slice(),
        is_newtype: false,
        return_type_name: None,
        return_type_node: c.return_type,
        field_type_nodes: field_type_nodes.into_boxed_slice(),
    }
}

/// 将 RecordFieldType 列表转为单构造器 CtorDefInfo（record 类型）。
fn record_fields_to_ctor_info<'a>(
    fields: &[RecordFieldType<'a>],
    type_name: &str,
    ast: &AstArena<'a>,
    sema_result: &mut SemaResult,
) -> CtorDefInfo {
    let mut field_names: Vec<Option<Box<str>>> = Vec::with_capacity(fields.len());
    let mut field_type_descs: Vec<&'static TypeDescriptor> = Vec::with_capacity(fields.len());
    let mut field_type_names: Vec<Option<Box<str>>> = Vec::with_capacity(fields.len());
    let mut field_type_nodes: Vec<Option<AstTypeRef>> = Vec::with_capacity(fields.len());

    for f in fields {
        field_names.push(Some(f.name.into()));
        let desc = resolve_type_node_to_desc(f.ty, ast, sema_result);
        field_type_descs.push(desc);
        field_type_names.push(type_name_from_type_node(&ast.ty(f.ty).node).map(|n| n.into()));
        field_type_nodes.push(Some(f.ty));
    }

    CtorDefInfo {
        name: type_name.into(), // record 构造器名 = 类型名
        type_name: type_name.into(),
        field_names: field_names.into_boxed_slice(),
        field_type_descs: field_type_descs.into_boxed_slice(),
        field_type_names: field_type_names.into_boxed_slice(),
        is_newtype: false,
        return_type_name: None,
        return_type_node: None,
        field_type_nodes: field_type_nodes.into_boxed_slice(),
    }
}

// =========================================================================
// monomorph — 单态化实例化
//
// v3 spec §5.2: 迁自 src/sema/monomorph.zig。
// 职责：识别所有泛型调用点 → 推导 type_args → 去重 → 确定实例集合。
//
// 适配 Rust：
// - 表达式 key 由裸指针 `@intFromPtr` 改为 `ExprId.0 as u64`（AstArena 索引）
// - 类型解析委托 `resolve_type_node_concrete`（接收 `Option<TypeId>` 而非 `*TypeNode`）
// - 借用分离：`WalkCtx` 不持有 `sema_result`，通过独立字段参数传递，避免
//   `&mut SemaResult` 与 `&mut WalkCtx` 循环借用；`instance` 作为栈上局部变量
//   在 `push` 前完成体解析，与 `sema_result` 无别名
// - `field_access` 元信息按 `TypeDefKind` 区分 Record（field_id 从 0）与
//   ADT/Newtype（field_id 从 1，`__tag=0`），修正 Zig 版 Record 索引偏移
// =========================================================================

/// FNV-1a 64-bit 哈希（迁自 monomorph.zig:hashTypeArgs）。
/// 输入为 `type_id` 列表（`TypeDescriptor.type_id`）。
pub fn hash_type_args(type_args: &[&'static TypeDescriptor]) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for ta in type_args {
        h ^= ta.type_id as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

/// 构造单态化缓存键。格式：`{func_name}#{hash}`（与 Zig 版一致）。
pub fn build_cache_key(func_name: &str, type_args: &[&'static TypeDescriptor]) -> String {
    let hash = hash_type_args(type_args);
    format!("{}#{:x}", func_name, hash)
}

/// 查找已有单态化实例（仅查询缓存，不创建）。
pub fn find_instance(
    sema_result: &SemaResult,
    func_name: &str,
    type_args: &[&'static TypeDescriptor],
) -> Option<u32> {
    let cache_key = build_cache_key(func_name, type_args);
    sema_result.monomorph_index.get(&cache_key).copied()
}

// ── AST 遍历上下文 ──

/// AST 遍历上下文：携带函数名 → 声明映射与循环检测表。
///
/// 刻意不持有 `sema_result`：所有需要 `&mut SemaResult` 的函数将其作为独立参数
/// 接收，使 `&mut ctx.in_progress` 与 `&mut sema_result` 可同时存活（split borrow）。
struct WalkCtx<'a> {
    ast: &'a AstArena<'a>,
    /// 函数名 → FunDecl 引用，用于推导 type_args 时查询参数类型注解与返回类型
    func_decls: HashMap<&'a str, &'a Spanned<Decl<'a>>>,
    /// 循环检测：正在实例化的 cache_key → instance_id（前向引用支持）
    in_progress: HashMap<String, u32>,
}

/// 由 `ExprInfo` 推导对应 `TypeDescriptor`（隐式 type_args 推断用）。
/// `ExprInfo.type_desc` 已是 `&'static TypeDescriptor`，直接返回。
fn td_from_expr_info(info: &ExprInfo) -> &'static TypeDescriptor {
    info.type_desc
}

/// 由 AST 类型节点推导 `TypeDescriptor`（显式 type_args 用）。
/// 使用 `resolve_type_node_concrete` 为用户类型创建具体描述符，无回退。
fn td_from_type_node<'a>(
    tn: AstTypeRef,
    ast: &AstArena<'a>,
    sema_result: &mut SemaResult,
) -> &'static TypeDescriptor {
    resolve_type_node_concrete(Some(tn), &[], ast, sema_result)
        .unwrap_or_else(|| sema_result.get_or_create_ref_desc("unknown"))
}

/// 推导泛型调用的 type_args
///
/// 优先级：
/// 1. 显式类型实参（call expr 的 type_args 字段，如 `foo<i32>(x)`）
/// 2. 隐式推断：
///    a. `.named` 类型注解（如 `init: A`）→ 实参 `ExprInfo` 的 `TypeDescriptor`
///    b. `.function` 类型注解（如 `f: (A, T) -> A`）→ lambda 实参的参数类型注解
///    c. `.function` 返回类型注解 → lambda 实参的返回类型（注解或 body 推断）
///
/// 未匹配的类型参数用 `get_or_create_ref_desc` 创建具名描述符（type_name = 参数名）。
fn infer_type_args<'a>(
    func_name: &str,
    arguments: &[ExprId],
    type_args_hint: Option<&[AstTypeRef]>,
    sig: &FuncSigInfo,
    ctx: &WalkCtx<'a>,
    sema_result: &mut SemaResult,
) -> Vec<&'static TypeDescriptor> {
    // 1. 显式类型实参：直接解析每个 TypeNode
    if let Some(hints) = type_args_hint {
        if !hints.is_empty() {
            let mut args = Vec::with_capacity(hints.len());
            for &tn in hints {
                args.push(td_from_type_node(tn, ctx.ast, sema_result));
            }
            return args;
        }
    }

    // 2. 隐式推断
    let fd_decl = match ctx.func_decls.get(func_name).copied() {
        Some(d) => d,
        None => {
            // AST 不可达（可能是方法或内建函数）：为每个类型参数创建具名描述符
            return sig
                .type_params
                .iter()
                .map(|tp| sema_result.get_or_create_ref_desc(tp))
                .collect();
        }
    };
    let fd = match &fd_decl.node {
        Decl::FunDecl {
            type_params,
            params,
            return_type,
            body,
            is_async,
            ..
        } => FunDeclView {
            type_params,
            params,
            return_type: *return_type,
            body: *body,
            is_async: *is_async,
        },
        _ => unreachable!("func_decls only stores FunDecl"),
    };

    let mut name_to_td: HashMap<&str, &'static TypeDescriptor> = HashMap::new();

    let is_type_param = |name: &str| sig.type_params.iter().any(|tp| tp.as_ref() == name);

    let param_count = fd.params.len().min(arguments.len());

    // Pass 1: 匹配 .named 类型注解（如 `init: A` → 实参类型）
    for i in 0..param_count {
        let param_type = match fd.params[i].type_annotation {
            Some(t) => t,
            None => continue,
        };
        let pname = match &ctx.ast.ty(param_type).node {
            TypeNode::Named { name } => *name,
            _ => continue,
        };
        if !is_type_param(pname) || name_to_td.contains_key(pname) {
            continue;
        }
        let arg_key = arguments[i].0 as u64;
        if let Some(info) = sema_result.get_expr(arg_key) {
            name_to_td.insert(pname, td_from_expr_info(info));
        }
    }

    // Pass 2: 匹配 .function 类型注解（如 `f: (A, T) -> A`）against lambda 实参
    for i in 0..param_count {
        let param_type = match fd.params[i].type_annotation {
            Some(t) => t,
            None => continue,
        };
        let fn_type = match &ctx.ast.ty(param_type).node {
            TypeNode::Function {
                params: fn_params,
                return_type: fn_ret,
            } => (fn_params.as_slice(), *fn_ret),
            _ => continue,
        };
        let lambda = match &ctx.ast.expr(arguments[i]).node {
            Expr::Lambda {
                params: lambda_params,
                return_type: lambda_rt,
                body,
                ..
            } => (lambda_params.as_slice(), *lambda_rt, body),
            _ => continue,
        };

        // 匹配函数类型参数与 lambda 参数
        let (fn_params, fn_ret) = fn_type;
        let (lambda_params, lambda_rt, _lambda_body) = lambda;
        let match_count = fn_params.len().min(lambda_params.len());
        for j in 0..match_count {
            let fp_name = match &ctx.ast.ty(fn_params[j]).node {
                TypeNode::Named { name } => *name,
                _ => continue,
            };
            if !is_type_param(fp_name) || name_to_td.contains_key(fp_name) {
                continue;
            }
            if let Some(lt) = lambda_params[j].type_annotation {
                if let Some(td) = resolve_type_node_concrete(Some(lt), &[], ctx.ast, sema_result) {
                    name_to_td.insert(fp_name, td);
                }
            }
        }

        // 匹配函数返回类型注解 → lambda 返回类型
        let ret_name = match &ctx.ast.ty(fn_ret).node {
            TypeNode::Named { name } => Some(*name),
            _ => None,
        };
        if let Some(ret_name) = ret_name {
            if is_type_param(ret_name) && !name_to_td.contains_key(ret_name) {
                if let Some(lrt) = lambda_rt {
                    if let Some(td) =
                        resolve_type_node_concrete(Some(lrt), &[], ctx.ast, sema_result)
                    {
                        name_to_td.insert(ret_name, td);
                    }
                } else if let Some(td) = infer_lambda_return_type(lambda, ctx, sema_result) {
                    name_to_td.insert(ret_name, td);
                }
            }
        }
    }

    // Pass 3: .generic 类型注解（如 `l: Lst<T>`）— 目前无法从 ref 通道提取元素类型，
    // 仅记录未绑定的类型参数名，依赖 Pass 1/2 已绑定的类型参数（跳过未绑定）

    // 输出 type_args：type_name 设为类型参数名，使 resolveTypeNode 按名匹配
    let mut args = Vec::with_capacity(sig.type_params.len());
    for tp_name in sig.type_params.iter() {
        let mut td = if let Some(&t) = name_to_td.get(tp_name.as_ref()) {
            t
        } else {
            sema_result.get_or_create_ref_desc(tp_name)
        };
        // 复制描述符并覆盖 type_name 为类型参数名（按名匹配 type_args 绑定）。
        // 由于 TypeDescriptor 在 pool 中泄漏为 &'static，此处构造一个新的泄漏副本。
        td = leak_with_type_name(td, tp_name.as_ref());
        args.push(td);
    }
    args
}

/// 从 lambda body 推断返回类型。
/// 优先：显式返回类型注解 → body expression 的 ExprInfo → block trailing_expr 的 ExprInfo。
fn infer_lambda_return_type<'a>(
    lambda: (&'a [Param<'a>], Option<AstTypeRef>, &'a LambdaBody),
    ctx: &WalkCtx<'a>,
    sema_result: &mut SemaResult,
) -> Option<&'static TypeDescriptor> {
    let (_, lambda_rt, body) = lambda;
    if let Some(rt) = lambda_rt {
        return resolve_type_node_concrete(Some(rt), &[], ctx.ast, sema_result);
    }
    match body {
        LambdaBody::Expression(body_expr) => {
            sema_result
                .get_expr(body_expr.0 as u64)
                .map(td_from_expr_info)
        }
        LambdaBody::Block(block_expr) => {
            if let Expr::Block { trailing, .. } = &ctx.ast.expr(*block_expr).node {
                if let Some(trailing) = trailing {
                    return sema_result
                        .get_expr(trailing.0 as u64)
                        .map(td_from_expr_info);
                }
            }
            None
        }
    }
}

/// 构造一个 `type_name` 被覆盖的 `TypeDescriptor` 副本（泄漏为 `&'static`）。
///
/// 用于 `infer_type_args` 输出：type_name 设为类型参数名，使 `resolve_type_node_concrete`
/// 能按名匹配 `type_args` 绑定。其余字段（size/ops/type_id）继承源描述符。
fn leak_with_type_name(src: &'static TypeDescriptor, type_name: &str) -> &'static TypeDescriptor {
    let name_static: &'static str = Box::leak(type_name.to_string().into_boxed_str());
    Box::leak(Box::new(TypeDescriptor {
        size: src.size,
        ops: src.ops,
        type_id: src.type_id,
        type_name: name_static,
    }))
}

/// 查找或创建 `MonomorphInstance`
///
/// 1. 查 `monomorph_index` 缓存命中 → 返回 instance_id
/// 2. 未命中：创建栈上局部实例、注册 `in_progress`（前向引用支持）
/// 3. 用具体 type_args 解析函数体内所有表达式类型（可能触发前向引用）
/// 4. 解析完成后 `push` 到 `monomorph_instances`、写入缓存
fn get_or_create_instance<'a>(
    func_name: &str,
    type_args: &[&'static TypeDescriptor],
    fd_decl: &'a Spanned<Decl<'a>>,
    ast: &'a AstArena<'a>,
    func_decls: &HashMap<&'a str, &'a Spanned<Decl<'a>>>,
    in_progress: &mut HashMap<String, u32>,
    sema_result: &mut SemaResult,
) -> u32 {
    let cache_key = build_cache_key(func_name, type_args);

    // 1. 查缓存
    if let Some(&idx) = sema_result.monomorph_index.get(&cache_key) {
        return idx;
    }

    // 2. 循环检测：前向引用支持
    if let Some(&existing_id) = in_progress.get(&cache_key) {
        return existing_id;
    }

    // 3. 新建栈上实例
    let fd = match &fd_decl.node {
        Decl::FunDecl {
            type_params,
            params,
            return_type,
            body,
            is_async,
            ..
        } => FunDeclView {
            type_params,
            params,
            return_type: *return_type,
            body: *body,
            is_async: *is_async,
        },
        _ => unreachable!("func_decls only stores FunDecl"),
    };

    let instance_id = sema_result.monomorph_instances.len() as u32;
    let return_td = resolve_type_node_concrete(fd.return_type, type_args, ast, sema_result)
        .unwrap_or_else(|| sema_result.get_or_create_ref_desc("return"));

    let mut instance = MonomorphInstance {
        instance_id,
        func_name: func_name.into(),
        type_args: type_args.to_vec().into_boxed_slice(),
        chan_layout: ChanLayout::empty(),
        return_type: return_td,
        is_async: fd.is_async,
        expr_types: HashMap::new(),
        field_accesses: HashMap::new(),
    };

    // 4. 标记为正在实例化（前向引用支持）
    in_progress.insert(cache_key.clone(), instance_id);

    // 5. 递归解析函数体类型（instance 是栈上局部，与 sema_result 无别名）
    resolve_instance_body_types(
        &mut instance,
        &fd,
        ast,
        func_decls,
        in_progress,
        sema_result,
        type_args,
    );

    // 6. 写入实例表与缓存
    sema_result.monomorph_instances.push(instance);
    sema_result.monomorph_index.insert(cache_key, instance_id);
    instance_id
}

/// FunDecl 字段视图（从 `Decl::FunDecl` 提取，便于跨函数传递）。
struct FunDeclView<'a> {
    type_params: &'a [TypeParam<'a>],
    params: &'a [Param<'a>],
    return_type: Option<AstTypeRef>,
    body: ExprId,
    is_async: bool,
}

// ── AST 递归遍历：收集泛型调用点 ──

/// 处理直接调用表达式（callee 为标识符）。
///
/// 仅处理 callee 是 identifier 的直接函数调用。方法调用、闭包调用等由
/// `process_method_call` 处理或跳过（递归遍历仍会进入 recv/arguments）。
fn process_call<'a>(
    callee: ExprId,
    arguments: &[ExprId],
    type_args_hint: Option<&[AstTypeRef]>,
    call_expr: ExprId,
    ast: &'a AstArena<'a>,
    func_decls: &HashMap<&'a str, &'a Spanned<Decl<'a>>>,
    in_progress: &mut HashMap<String, u32>,
    sema_result: &mut SemaResult,
) {
    // 仅处理直接标识符调用：foo(args) 或 foo<T>(args)
    let func_name = match &ast.expr(callee).node {
        Expr::Ident(name) => *name,
        _ => return,
    };

    // 查函数签名：跳过未注册函数与非泛型函数
    let sig_owned: Option<FuncSigInfo> = sema_result
        .get_func_sig(func_name)
        .map(|s| s.clone());
    let sig = match sig_owned {
        Some(s) if !s.type_params.is_empty() => s,
        _ => return,
    };

    // 查函数 AST（用于参数类型注解与返回类型）
    let fd_decl = match func_decls.get(func_name).copied() {
        Some(d) => d,
        None => return,
    };

    // 推导 type_args（显式或隐式）
    let ctx = WalkCtx {
        ast,
        func_decls: func_decls.clone(),
        in_progress: HashMap::new(),
    };
    let type_args = infer_type_args(func_name, arguments, type_args_hint, &sig, &ctx, sema_result);

    // 查找或创建实例
    let instance_id = get_or_create_instance(
        func_name,
        &type_args,
        fd_decl,
        ast,
        func_decls,
        in_progress,
        sema_result,
    );

    // 记录调用点 → 实例映射
    sema_result
        .call_instantiations
        .insert(call_expr.0 as u64, instance_id);
}

/// 处理方法调用表达式。
///
/// 方法调用通过 trait 分派，完整解析需要对象类型构造 mangled 名。此处采用最佳努力
/// 策略：直接以方法名查 `func_sig`，命中则处理；未命中则跳过。递归遍历仍会进入
/// recv/arguments，保证嵌套调用被收集。
fn process_method_call<'a>(
    method: &str,
    arguments: &[ExprId],
    type_args_hint: Option<&[AstTypeRef]>,
    call_expr: ExprId,
    ast: &'a AstArena<'a>,
    func_decls: &HashMap<&'a str, &'a Spanned<Decl<'a>>>,
    in_progress: &mut HashMap<String, u32>,
    sema_result: &mut SemaResult,
) {
    // 直接以方法名查 func_sig（覆盖同名顶层函数的罕见场景）
    let sig_owned: Option<FuncSigInfo> = sema_result.get_func_sig(method).map(|s| s.clone());
    let sig = match sig_owned {
        Some(s) if !s.type_params.is_empty() => s,
        _ => return,
    };

    let fd_decl = match func_decls.get(method).copied() {
        Some(d) => d,
        None => return,
    };

    let ctx = WalkCtx {
        ast,
        func_decls: func_decls.clone(),
        in_progress: HashMap::new(),
    };
    let type_args = infer_type_args(method, arguments, type_args_hint, &sig, &ctx, sema_result);

    let instance_id = get_or_create_instance(
        method,
        &type_args,
        fd_decl,
        ast,
        func_decls,
        in_progress,
        sema_result,
    );
    sema_result
        .call_instantiations
        .insert(call_expr.0 as u64, instance_id);

    // v3 阶段 1：记录方法分派元信息（最佳努力匹配，完整 trait 解析留待后续阶段）
    sema_result.method_dispatches.insert(
        call_expr.0 as u64,
        DispatchInfo {
            trait_id: 0,
            method_idx: 0,
            impl_fn_idx: 0,
            instance_id,
        },
    );
}

/// 递归遍历 Stmt，收集所有嵌套的泛型调用点。
fn walk_stmt<'a>(
    stmt: StmtId,
    ctx: &mut WalkCtx<'a>,
    sema_result: &mut SemaResult,
) {
    let node = match &ctx.ast.stmt(stmt).node {
        s => s,
    };
    match node {
        Stmt::ValDecl { value, .. } => walk_expr(*value, ctx, sema_result),
        Stmt::VarDecl { value, .. } => walk_expr(*value, ctx, sema_result),
        Stmt::Assignment { target, value } => {
            walk_expr(*target, ctx, sema_result);
            walk_expr(*value, ctx, sema_result);
        }
        Stmt::FieldAssignment { object, value, .. } => {
            walk_expr(*object, ctx, sema_result);
            walk_expr(*value, ctx, sema_result);
        }
        Stmt::CompoundAssignment { target, value, .. } => {
            walk_expr(*target, ctx, sema_result);
            walk_expr(*value, ctx, sema_result);
        }
        Stmt::Expression { expr } => walk_expr(*expr, ctx, sema_result),
        Stmt::Return { value } => {
            if let Some(v) = value {
                walk_expr(*v, ctx, sema_result);
            }
        }
        Stmt::Defer { expr } => walk_expr(*expr, ctx, sema_result),
        Stmt::Throw { expr } => walk_expr(*expr, ctx, sema_result),
        Stmt::Break | Stmt::Continue => {}
        Stmt::For { iterable, body, .. } => {
            walk_expr(*iterable, ctx, sema_result);
            walk_expr(*body, ctx, sema_result);
        }
        Stmt::While { condition, body } => {
            walk_expr(*condition, ctx, sema_result);
            walk_expr(*body, ctx, sema_result);
        }
        Stmt::Loop { body } => walk_expr(*body, ctx, sema_result),
    }
}

/// 递归遍历 Expr，收集所有嵌套的泛型调用点。
///
/// 对 `call`/`method_call`/`safe_method_call` 三种调用表达式，提取调用元信息并
/// 推导 type_args。同时递归进入所有子表达式，确保嵌套调用被完整收集。
fn walk_expr<'a>(
    expr: ExprId,
    ctx: &mut WalkCtx<'a>,
    sema_result: &mut SemaResult,
) {
    // 先复制不可变引用字段，再用 &mut ctx.in_progress（split borrow）
    let ast = ctx.ast;
    let func_decls = &ctx.func_decls;
    let node = &ast.expr(expr).node;
    match node {
        // ── 调用表达式：核心收集目标 ──
        Expr::Call {
            callee,
            args,
            type_args,
        } => {
            let hint = type_args.as_deref();
            process_call(
                *callee,
                args.as_slice(),
                hint,
                expr,
                ast,
                func_decls,
                &mut ctx.in_progress,
                sema_result,
            );
            walk_expr(*callee, ctx, sema_result);
            for &arg in args {
                walk_expr(arg, ctx, sema_result);
            }
        }
        Expr::MethodCall {
            recv,
            method,
            args,
            type_args,
        } => {
            let hint = type_args.as_deref();
            process_method_call(
                method,
                args.as_slice(),
                hint,
                expr,
                ast,
                func_decls,
                &mut ctx.in_progress,
                sema_result,
            );
            walk_expr(*recv, ctx, sema_result);
            for &arg in args {
                walk_expr(arg, ctx, sema_result);
            }
        }
        Expr::SafeMethodCall {
            recv,
            method,
            args,
            type_args,
        } => {
            let hint = type_args.as_deref();
            process_method_call(
                method,
                args.as_slice(),
                hint,
                expr,
                ast,
                func_decls,
                &mut ctx.in_progress,
                sema_result,
            );
            walk_expr(*recv, ctx, sema_result);
            for &arg in args {
                walk_expr(arg, ctx, sema_result);
            }
        }

        // ── 一元/二元/赋值 ──
        Expr::Binary { op: _, lhs, rhs } => {
            walk_expr(*lhs, ctx, sema_result);
            walk_expr(*rhs, ctx, sema_result);
        }
        Expr::Unary { operand, .. } => walk_expr(*operand, ctx, sema_result),
        Expr::RefOf(operand) => walk_expr(*operand, ctx, sema_result),
        Expr::Deref(operand) => walk_expr(*operand, ctx, sema_result),
        Expr::Assign { target, value } => {
            walk_expr(*target, ctx, sema_result);
            walk_expr(*value, ctx, sema_result);
        }
        Expr::CompoundAssign { target, value, .. } => {
            walk_expr(*target, ctx, sema_result);
            walk_expr(*value, ctx, sema_result);
        }
        Expr::NonNullAssert(e) => walk_expr(*e, ctx, sema_result),
        Expr::Propagate(e) => walk_expr(*e, ctx, sema_result),
        Expr::Elvis { lhs, rhs } => {
            walk_expr(*lhs, ctx, sema_result);
            walk_expr(*rhs, ctx, sema_result);
        }

        // ── 字段访问与索引 ──
        Expr::FieldAccess { recv, .. } => walk_expr(*recv, ctx, sema_result),
        Expr::SafeAccess { recv, .. } => walk_expr(*recv, ctx, sema_result),
        Expr::Index { recv, index } => {
            walk_expr(*recv, ctx, sema_result);
            walk_expr(*index, ctx, sema_result);
        }
        Expr::Slice { recv, start, end, .. } => {
            walk_expr(*recv, ctx, sema_result);
            walk_expr(*start, ctx, sema_result);
            walk_expr(*end, ctx, sema_result);
        }

        // ── 容器字面量 ──
        Expr::ArrayLit { elements, fill } => {
            for &e in elements {
                walk_expr(e, ctx, sema_result);
            }
            if let Some((fv, fc)) = fill {
                walk_expr(*fv, ctx, sema_result);
                walk_expr(*fc, ctx, sema_result);
            }
        }
        Expr::RecordLit(fields) => {
            for f in fields {
                walk_expr(f.value, ctx, sema_result);
            }
        }
        Expr::RecordExtend { base, updates } => {
            walk_expr(*base, ctx, sema_result);
            for f in updates {
                walk_expr(f.value, ctx, sema_result);
            }
        }

        // ── 控制流 ──
        Expr::Lambda { body, .. } => match body {
            LambdaBody::Block(b) => walk_expr(*b, ctx, sema_result),
            LambdaBody::Expression(e) => walk_expr(*e, ctx, sema_result),
        },
        Expr::If {
            cond,
            then_branch,
            else_branch,
        } => {
            walk_expr(*cond, ctx, sema_result);
            walk_expr(*then_branch, ctx, sema_result);
            if let Some(eb) = else_branch {
                walk_expr(*eb, ctx, sema_result);
            }
        }
        Expr::Block { stmts, trailing } => {
            for &s in stmts {
                walk_stmt(s, ctx, sema_result);
            }
            if let Some(te) = trailing {
                walk_expr(*te, ctx, sema_result);
            }
        }
        Expr::Match { scrutinee, arms } => {
            walk_expr(*scrutinee, ctx, sema_result);
            for arm in arms {
                if let Some(g) = arm.guard {
                    walk_expr(g, ctx, sema_result);
                }
                walk_expr(arm.body, ctx, sema_result);
            }
        }

        // ── 类型转换 ──
        Expr::TypeCast { expr: e, .. } => walk_expr(*e, ctx, sema_result),
        Expr::CastBuilder { expr: e, .. } => walk_expr(*e, ctx, sema_result),

        // ── 并发/异步 ──
        Expr::Atomic(e) => walk_expr(*e, ctx, sema_result),
        Expr::Lazy(e) => walk_expr(*e, ctx, sema_result),
        Expr::Select(arms) => {
            for arm in arms {
                match arm {
                    SelectArm::Receive {
                        channel_expr, body, ..
                    } => {
                        walk_expr(*channel_expr, ctx, sema_result);
                        walk_expr(*body, ctx, sema_result);
                    }
                    SelectArm::Timeout { duration, body } => {
                        walk_expr(*duration, ctx, sema_result);
                        walk_expr(*body, ctx, sema_result);
                    }
                }
            }
        }

        // ── 字符串插值 ──
        Expr::StrInterp(parts) => {
            for part in parts {
                if let InterpolationPart::Expression(e) = part {
                    walk_expr(*e, ctx, sema_result);
                }
            }
        }

        // ── inline trait value：方法体可能含泛型调用 ──
        Expr::InlineTrait(methods) => {
            for method in methods {
                if let Some(body) = method.body {
                    walk_expr(body, ctx, sema_result);
                }
            }
        }

        // ── 终端节点：无需递归 ──
        Expr::IntLit { .. }
        | Expr::FloatLit { .. }
        | Expr::BoolLit(_)
        | Expr::CharLit(_)
        | Expr::StrLit(_)
        | Expr::NullLit
        | Expr::VoidLit
        | Expr::Ident(_) => {}
    }
}

// ── 主入口：collect_monomorph_instances ──

/// 收集模块中所有泛型调用点，产出单态化实例集合
///
/// v3 spec §5.2 `collectMonomorphInstances` 算法：
/// 1. 构建 `func_name → fun_decl` 映射，供推导 type_args 时查询参数类型注解
/// 2. 遍历所有顶层声明：
///    a. 非泛型 `fun_decl` → 创建空 type_args 实例
///    b. 所有 `fun_decl` 体 / `type_decl` 方法体 / `expr_decl` → 递归遍历
/// 3. 对每个泛型调用点：推导 type_args → 去重 → 创建实例 → 记录调用点映射
///
/// 泛型函数本身不创建空实例（其具体实例由调用点驱动生成）。
/// 方法调用的完整 trait 分派解析留待后续阶段，当前仅做最佳努力匹配。
pub fn collect_monomorph_instances<'a>(
    module: &'a Module<'a>,
    sema_result: &mut SemaResult,
) {
    // 注册内置标量 TypeDescriptor 到全局表
    register_builtin_type_descriptors(sema_result);

    let mut ctx = WalkCtx {
        ast: &module.arena,
        func_decls: HashMap::new(),
        in_progress: HashMap::new(),
    };

    // 1. 构建 func_name → &Spanned<Decl> 映射（仅顶层 fun_decl）
    for decl in &module.declarations {
        if let Decl::FunDecl { name, .. } = &decl.node {
            ctx.func_decls.insert(name, decl);
        }
    }

    // 2. 遍历所有顶层声明
    let declarations: Vec<&Spanned<Decl<'a>>> = module.declarations.iter().collect();
    for decl in declarations {
        match &decl.node {
            Decl::FunDecl {
                name,
                type_params,
                params,
                return_type,
                body,
                is_async,
                ..
            } => {
                // 非泛型函数：创建空 type_args 实例
                // （泛型函数不创建空实例，由调用点驱动）
                if type_params.is_empty() {
                    let empty_type_args: Vec<&'static TypeDescriptor> = Vec::new();
                    let return_td = resolve_type_node_concrete(
                        *return_type,
                        &empty_type_args,
                        &module.arena,
                        sema_result,
                    )
                    .unwrap_or_else(|| sema_result.get_or_create_ref_desc("return"));

                    let instance = MonomorphInstance {
                        instance_id: sema_result.monomorph_instances.len() as u32,
                        func_name: (*name).into(),
                        type_args: empty_type_args.into_boxed_slice(),
                        chan_layout: ChanLayout::empty(),
                        return_type: return_td,
                        is_async: *is_async,
                        expr_types: HashMap::new(),
                        field_accesses: HashMap::new(),
                    };
                    sema_result.monomorph_instances.push(instance);

                    // 非泛型函数：遍历函数体收集泛型调用点
                    // （泛型函数体的调用点在 resolveInstanceBodyTypes 中发现，
                    //  因为它们依赖当前实例的 type_args 上下文才能正确推断类型实参）
                    walk_expr(*body, &mut ctx, sema_result);
                }
                let _ = params; // params 未在非泛型分支使用
            }

            // 类型声明：遍历非泛型方法体（泛型方法体在实例化时发现）
            Decl::TypeDecl { methods, .. } => {
                // 收集需遍历的方法体，避免在借用 methods 时 &mut sema_result
                let bodies: Vec<ExprId> = methods
                    .iter()
                    .filter(|m| m.type_params.is_empty())
                    .filter_map(|m| m.body)
                    .collect();
                for body in bodies {
                    walk_expr(body, &mut ctx, sema_result);
                }
            }

            // 顶层表达式声明：遍历表达式
            Decl::ExprDecl { expr, stmt } => {
                walk_expr(*expr, &mut ctx, sema_result);
                if let Some(s) = stmt {
                    walk_stmt(*s, &mut ctx, sema_result);
                }
            }

            // import / pack：无需遍历
            _ => {}
        }
    }
}

// ── 实例体类型解析 ──

/// 实例体类型解析上下文
///
/// 持有 `&mut instance`（栈上局部，与 `sema_result` 无别名）和 `&mut sema_result`，
/// 通过 split borrowing 允许 `resolve_expr` 中 `&mut ctx.sema_result`（写调用点映射）
/// 与 `&mut ctx.instance`（写表达式类型表）交替进行。
struct ResolveCtx<'a, 'b> {
    instance: &'b mut MonomorphInstance,
    sema_result: &'a mut SemaResult,
    ast: &'a AstArena<'a>,
    type_args: &'a [&'static TypeDescriptor],
    /// 变量名 → 类型描述符（局部变量绑定，作用域栈）
    bindings: Vec<HashMap<&'a str, &'static TypeDescriptor>>,
    /// 类型参数名 → type_args 索引（快速查找）
    type_param_map: HashMap<&'a str, u16>,
    func_decls: &'a HashMap<&'a str, &'a Spanned<Decl<'a>>>,
    in_progress: &'a mut HashMap<String, u32>,
}

impl<'a, 'b> ResolveCtx<'a, 'b> {
    fn push_scope(&mut self) {
        self.bindings.push(HashMap::new());
    }

    fn pop_scope(&mut self) {
        if self.bindings.len() > 1 {
            self.bindings.pop();
        }
    }

    fn define_var(&mut self, name: &'a str, td: &'static TypeDescriptor) {
        if let Some(scope) = self.bindings.last_mut() {
            scope.insert(name, td);
        }
    }

    fn lookup_var(&self, name: &str) -> Option<&'static TypeDescriptor> {
        for scope in self.bindings.iter().rev() {
            if let Some(&td) = scope.get(name) {
                return Some(td);
            }
        }
        None
    }
}

/// 用具体 type_args 解析函数体内所有表达式类型
///
/// 递归遍历函数体 AST，对每个表达式计算其类型并存入 `instance.expr_types`。
/// 对 `field_access` 表达式额外存入 `instance.field_accesses`。
/// 替代 IRBuilder 的 `infer*` 系列函数。
fn resolve_instance_body_types<'a>(
    instance: &mut MonomorphInstance,
    fd: &FunDeclView<'a>,
    ast: &'a AstArena<'a>,
    func_decls: &'a HashMap<&'a str, &'a Spanned<Decl<'a>>>,
    in_progress: &mut HashMap<String, u32>,
    sema_result: &mut SemaResult,
    type_args: &[&'static TypeDescriptor],
) {
    let mut type_param_map: HashMap<&'a str, u16> = HashMap::new();
    for (i, tp) in fd.type_params.iter().enumerate() {
        type_param_map.insert(tp.name, i as u16);
    }

    let mut bindings: Vec<HashMap<&'a str, &'static TypeDescriptor>> = Vec::new();
    bindings.push(HashMap::new());

    let mut rctx = ResolveCtx {
        instance,
        sema_result,
        ast,
        type_args,
        bindings,
        type_param_map,
        func_decls,
        in_progress,
    };

    // 注册函数参数到变量绑定
    for param in fd.params {
        let td = if let Some(ta) = param.type_annotation {
            resolve_type_node_concrete(Some(ta), type_args, ast, rctx.sema_result)
                .unwrap_or_else(|| rctx.sema_result.get_or_create_ref_desc("param"))
        } else {
            rctx.sema_result.get_or_create_ref_desc("param")
        };
        rctx.define_var(param.name, td);
    }

    // 遍历函数体
    resolve_expr(fd.body, &mut rctx);
}

/// 在函数体内发现泛型调用点时，用当前实例的 type_args 上下文推断 type_args 并创建实例
///
/// 与顶层 `process_call` 的区别：
/// - 顶层 `process_call` 依赖 `sema_result.expr_types`（HM 推断产出），无法解析类型参数 T
/// - 此函数用 `resolve_expr_type` 递归解析实参类型，能利用当前实例的 type_args 将 T 解析为具体类型
fn process_call_in_body<'a>(
    func_name: &str,
    arguments: &[ExprId],
    type_args_hint: Option<&[AstTypeRef]>,
    call_expr: ExprId,
    ctx: &mut ResolveCtx<'a, '_>,
) {
    let sig_owned: Option<FuncSigInfo> = ctx
        .sema_result
        .get_func_sig(func_name)
        .map(|s| s.clone());
    let sig = match sig_owned {
        Some(s) if !s.type_params.is_empty() => s,
        _ => return, // 非泛型函数，无需单态化
    };

    let fd_decl = match ctx.func_decls.get(func_name).copied() {
        Some(d) => d,
        None => return,
    };

    // 读取当前实例函数名（&ctx.instance）与 type_args，与 &mut ctx.sema_result split borrow
    let cur_func_name: &str = ctx.instance.func_name.as_ref();
    let type_args = infer_type_args_in_body(
        func_name,
        arguments,
        type_args_hint,
        &sig,
        fd_decl,
        ctx.ast,
        ctx.type_args,
        cur_func_name,
        ctx.sema_result,
    );

    // 查找或创建实例
    let existing_id = find_instance(ctx.sema_result, func_name, &type_args);
    if let Some(id) = existing_id {
        ctx.sema_result
            .call_instantiations
            .insert(call_expr.0 as u64, id);
        return;
    }

    let instance_id = get_or_create_instance(
        func_name,
        &type_args,
        fd_decl,
        ctx.ast,
        ctx.func_decls,
        ctx.in_progress,
        ctx.sema_result,
    );
    ctx.sema_result
        .call_instantiations
        .insert(call_expr.0 as u64, instance_id);
}

/// 在实例体上下文中推断 type_args
///
/// 与顶层 `infer_type_args` 的区别：
/// - 显式类型实参：用当前实例的 type_args 解析类型参数 T（而非空 type_args）
/// - 隐式推断：用 `resolve_expr_type` 递归解析实参类型（而非 `sema_result.expr_types`）
/// - 直接递归：递归调用自身时，type_args 与当前实例一致
fn infer_type_args_in_body<'a>(
    func_name: &str,
    arguments: &[ExprId],
    type_args_hint: Option<&[AstTypeRef]>,
    sig: &FuncSigInfo,
    fd_decl: &'a Spanned<Decl<'a>>,
    ast: &'a AstArena<'a>,
    cur_type_args: &[&'static TypeDescriptor],
    cur_func_name: &str,
    sema_result: &mut SemaResult,
) -> Vec<&'static TypeDescriptor> {
    // 1. 显式类型实参：用当前实例的 type_args 解析（支持 foo<T>(x) 中 T 为外层类型参数）
    if let Some(hints) = type_args_hint {
        if !hints.is_empty() {
            let mut args = Vec::with_capacity(hints.len());
            for &tn in hints {
                let td = resolve_type_node_concrete(Some(tn), cur_type_args, ast, sema_result)
                    .unwrap_or_else(|| sema_result.get_or_create_ref_desc("type_arg"));
                args.push(td);
            }
            return args;
        }
    }

    // 2. 直接递归：递归调用自身时，type_args 与当前实例一致
    //    （如 foldl<T,A> 体内的 foldl(t, f(init,x), f) 使用相同 T,A）
    //    这避免了从 .generic 类型参数（Lst<T>）和非 lambda 实参无法推断 T 的问题
    if func_name == cur_func_name {
        return cur_type_args.to_vec();
    }

    // 3. 隐式推断
    let fd = match &fd_decl.node {
        Decl::FunDecl {
            type_params,
            params,
            return_type,
            body,
            is_async,
            ..
        } => FunDeclView {
            type_params,
            params,
            return_type: *return_type,
            body: *body,
            is_async: *is_async,
        },
        _ => unreachable!("func_decls only stores FunDecl"),
    };

    let mut name_to_td: HashMap<&str, &'static TypeDescriptor> = HashMap::new();

    let is_type_param = |name: &str| sig.type_params.iter().any(|tp| tp.as_ref() == name);

    let param_count = fd.params.len().min(arguments.len());

    // Pass 1: .named 类型注解
    for i in 0..param_count {
        let param_type = match fd.params[i].type_annotation {
            Some(t) => t,
            None => continue,
        };
        let pname = match &ast.ty(param_type).node {
            TypeNode::Named { name } => *name,
            _ => continue,
        };
        if !is_type_param(pname) || name_to_td.contains_key(pname) {
            continue;
        }
        // 用一个临时 ResolveCtx 调用 resolve_expr_type —— 但此处无 instance，
        // 改用 sema_result.expr_types 回退（与 Zig 行为一致：Pass 1 用 ExprInfo）
        let arg_key = arguments[i].0 as u64;
        if let Some(info) = sema_result.get_expr(arg_key) {
            name_to_td.insert(pname, td_from_expr_info(info));
        }
    }

    // Pass 2: .function 类型注解 → lambda 实参的参数类型注解
    for i in 0..param_count {
        let param_type = match fd.params[i].type_annotation {
            Some(t) => t,
            None => continue,
        };
        let (fn_params, fn_ret) = match &ast.ty(param_type).node {
            TypeNode::Function {
                params: p,
                return_type: r,
            } => (p.as_slice(), *r),
            _ => continue,
        };
        let (lambda_params, lambda_rt) = match &ast.expr(arguments[i]).node {
            Expr::Lambda {
                params: lp,
                return_type: lrt,
                ..
            } => (lp.as_slice(), *lrt),
            _ => continue,
        };

        let match_count = fn_params.len().min(lambda_params.len());
        for j in 0..match_count {
            let fp_name = match &ast.ty(fn_params[j]).node {
                TypeNode::Named { name } => *name,
                _ => continue,
            };
            if !is_type_param(fp_name) || name_to_td.contains_key(fp_name) {
                continue;
            }
            if let Some(lt) = lambda_params[j].type_annotation {
                if let Some(td) = resolve_type_node_concrete(Some(lt), cur_type_args, ast, sema_result)
                {
                    name_to_td.insert(fp_name, td);
                }
            }
        }

        // 返回类型注解 → lambda 返回类型
        let ret_name = match &ast.ty(fn_ret).node {
            TypeNode::Named { name } => Some(*name),
            _ => None,
        };
        if let Some(ret_name) = ret_name {
            if is_type_param(ret_name) && !name_to_td.contains_key(ret_name) {
                if let Some(lrt) = lambda_rt {
                    if let Some(td) =
                        resolve_type_node_concrete(Some(lrt), cur_type_args, ast, sema_result)
                    {
                        name_to_td.insert(ret_name, td);
                    }
                }
            }
        }
    }

    // 按 sig.type_params 顺序输出 TypeDescriptor
    let mut args = Vec::with_capacity(sig.type_params.len());
    for tp_name in sig.type_params.iter() {
        let td = if let Some(&t) = name_to_td.get(tp_name.as_ref()) {
            t
        } else {
            sema_result.get_or_create_ref_desc(tp_name)
        };
        args.push(leak_with_type_name(td, tp_name.as_ref()));
    }
    args
}

/// 解析表达式类型并存入实例表
fn resolve_expr<'a, 'b>(expr: ExprId, ctx: &mut ResolveCtx<'a, 'b>) {
    // 对调用表达式：先发现并创建被调用函数的实例（填充 call_instantiations），
    // 再计算返回类型（resolve_expr_type 的 .call 分支会查询 call_instantiations）
    {
        let ast = ctx.ast;
        let node = &ast.expr(expr).node;
        match node {
            Expr::Call {
                callee,
                args,
                type_args,
            } => {
                if let Expr::Ident(_) = &ast.expr(*callee).node {
                    let hint = type_args.as_deref();
                    process_call_in_body(
                        callee_name(ast, *callee),
                        args.as_slice(),
                        hint,
                        expr,
                        ctx,
                    );
                }
            }
            Expr::MethodCall {
                recv: _,
                method,
                args,
                type_args,
            } => {
                let hint = type_args.as_deref();
                process_call_in_body(method, args.as_slice(), hint, expr, ctx);
            }
            Expr::SafeMethodCall {
                recv: _,
                method,
                args,
                type_args,
            } => {
                let hint = type_args.as_deref();
                process_call_in_body(method, args.as_slice(), hint, expr, ctx);
            }
            _ => {}
        }
    }

    let td = resolve_expr_type(expr, ctx)
        .unwrap_or_else(|| ctx.sema_result.get_or_create_ref_desc("unknown"));

    let expr_key = expr.0 as u64;
    let mut info = ExprInfo::new(td, expr_key);
    info.type_name = Some(td.type_name.into());
    info.is_ref_type = td.is_ref();
    ctx.instance.expr_types.insert(expr_key, info);

    // 同步填充 sema_result.resolved_type_descs（全局表达式→TypeDescriptor 映射）
    ctx.sema_result.resolved_type_descs.insert(expr_key, td);

    // 递归处理子表达式 + field_access 元信息
    let ast = ctx.ast;
    let node = &ast.expr(expr).node;
    match node {
        Expr::FieldAccess { recv, field } => {
            // 额外存入 field_accesses 元信息
            let obj_td = resolve_expr_type(*recv, ctx)
                .unwrap_or_else(|| ctx.sema_result.get_or_create_ref_desc("unknown"));
            if let Some((field_id, field_td)) =
                ctx.sema_result.resolve_field_td(obj_td.type_name, field)
            {
                ctx.instance.field_accesses.insert(
                    expr_key,
                    FieldAccessInfo {
                        obj_type_desc: obj_td,
                        field_idx: field_id,
                        field_type_desc: field_td,
                    },
                );
            }
            resolve_expr(*recv, ctx);
        }
        Expr::Call {
            callee, args, ..
        } => {
            resolve_expr(*callee, ctx);
            for &arg in args {
                resolve_expr(arg, ctx);
            }
        }
        Expr::MethodCall {
            recv, args, ..
        } => {
            resolve_expr(*recv, ctx);
            for &arg in args {
                resolve_expr(arg, ctx);
            }
        }
        Expr::SafeMethodCall {
            recv, args, ..
        } => {
            resolve_expr(*recv, ctx);
            for &arg in args {
                resolve_expr(arg, ctx);
            }
        }
        Expr::Binary { op: _, lhs, rhs } => {
            resolve_expr(*lhs, ctx);
            resolve_expr(*rhs, ctx);
        }
        Expr::Unary { operand, .. } => resolve_expr(*operand, ctx),
        Expr::RefOf(operand) => resolve_expr(*operand, ctx),
        Expr::Deref(operand) => resolve_expr(*operand, ctx),
        Expr::Assign { target, value } => {
            resolve_expr(*target, ctx);
            resolve_expr(*value, ctx);
        }
        Expr::CompoundAssign { target, value, .. } => {
            resolve_expr(*target, ctx);
            resolve_expr(*value, ctx);
        }
        Expr::NonNullAssert(e) => resolve_expr(*e, ctx),
        Expr::Propagate(e) => resolve_expr(*e, ctx),
        Expr::SafeAccess { recv, .. } => resolve_expr(*recv, ctx),
        Expr::Index { recv, index } => {
            resolve_expr(*recv, ctx);
            resolve_expr(*index, ctx);
        }
        Expr::Slice {
            recv, start, end, ..
        } => {
            resolve_expr(*recv, ctx);
            resolve_expr(*start, ctx);
            resolve_expr(*end, ctx);
        }
        Expr::ArrayLit { elements, fill } => {
            for &e in elements {
                resolve_expr(e, ctx);
            }
            if let Some((fv, fc)) = fill {
                resolve_expr(*fv, ctx);
                resolve_expr(*fc, ctx);
            }
        }
        Expr::RecordLit(fields) => {
            for f in fields {
                resolve_expr(f.value, ctx);
            }
        }
        Expr::RecordExtend { base, updates } => {
            resolve_expr(*base, ctx);
            for f in updates {
                resolve_expr(f.value, ctx);
            }
        }
        Expr::If {
            cond,
            then_branch,
            else_branch,
        } => {
            resolve_expr(*cond, ctx);
            resolve_expr(*then_branch, ctx);
            if let Some(eb) = else_branch {
                resolve_expr(*eb, ctx);
            }
        }
        Expr::Match { scrutinee, arms } => {
            resolve_expr(*scrutinee, ctx);
            for arm in arms {
                ctx.push_scope();
                resolve_pattern(arm.pattern, ctx);
                if let Some(g) = arm.guard {
                    resolve_expr(g, ctx);
                }
                resolve_expr(arm.body, ctx);
                ctx.pop_scope();
            }
        }
        Expr::Block { stmts, trailing } => {
            ctx.push_scope();
            let stmts: Vec<StmtId> = stmts.iter().copied().collect();
            for s in stmts {
                resolve_stmt(s, ctx);
            }
            if let Some(te) = trailing {
                resolve_expr(*te, ctx);
            }
            ctx.pop_scope();
        }
        Expr::Lambda { body, .. } => match body {
            LambdaBody::Block(b) => resolve_expr(*b, ctx),
            LambdaBody::Expression(e) => resolve_expr(*e, ctx),
        },
        _ => {}
    }
}

/// 解析语句（递归处理声明和控制流）
fn resolve_stmt<'a, 'b>(stmt: StmtId, ctx: &mut ResolveCtx<'a, 'b>) {
    let ast = ctx.ast;
    let node = &ast.stmt(stmt).node;
    match node {
        Stmt::ValDecl { name, value, .. } => {
            let td = resolve_expr_type(*value, ctx)
                .unwrap_or_else(|| ctx.sema_result.get_or_create_ref_desc("unknown"));
            resolve_expr(*value, ctx);
            ctx.define_var(name, td);
        }
        Stmt::VarDecl { name, value, .. } => {
            let td = resolve_expr_type(*value, ctx)
                .unwrap_or_else(|| ctx.sema_result.get_or_create_ref_desc("unknown"));
            resolve_expr(*value, ctx);
            ctx.define_var(name, td);
        }
        Stmt::Assignment { target, value } => {
            resolve_expr(*target, ctx);
            resolve_expr(*value, ctx);
        }
        Stmt::FieldAssignment { object, value, .. } => {
            resolve_expr(*object, ctx);
            resolve_expr(*value, ctx);
        }
        Stmt::CompoundAssignment { target, value, .. } => {
            resolve_expr(*target, ctx);
            resolve_expr(*value, ctx);
        }
        Stmt::Expression { expr } => resolve_expr(*expr, ctx),
        Stmt::Return { value } => {
            if let Some(v) = value {
                resolve_expr(*v, ctx);
            }
        }
        Stmt::Defer { expr } => resolve_expr(*expr, ctx),
        Stmt::Throw { expr } => resolve_expr(*expr, ctx),
        Stmt::Break | Stmt::Continue => {}
        Stmt::For {
            name,
            iterable,
            body,
        } => {
            resolve_expr(*iterable, ctx);
            ctx.push_scope();
            let iter_td = resolve_expr_type(*iterable, ctx)
                .unwrap_or_else(|| ctx.sema_result.get_or_create_ref_desc("unknown"));
            ctx.define_var(name, iter_td);
            resolve_expr(*body, ctx);
            ctx.pop_scope();
        }
        Stmt::While { condition, body } => {
            resolve_expr(*condition, ctx);
            resolve_expr(*body, ctx);
        }
        Stmt::Loop { body } => resolve_expr(*body, ctx),
    }
}

/// 解析 match pattern 中的变量绑定
fn resolve_pattern<'a, 'b>(pattern: PatternRef, ctx: &mut ResolveCtx<'a, 'b>) {
    let ast = ctx.ast;
    let node = &ast.pattern(pattern).node;
    match node {
        Pattern::Variable { name } => {
            let td = ctx.sema_result.get_or_create_ref_desc("pattern_var");
            ctx.define_var(name, td);
        }
        Pattern::Constructor { patterns, .. } => {
            let patterns: Vec<PatternRef> = patterns.iter().copied().collect();
            for fp in patterns {
                resolve_pattern(fp, ctx);
            }
        }
        Pattern::Record { fields } => {
            let field_patterns: Vec<PatternRef> =
                fields.iter().map(|f| f.pattern).collect();
            for fp in field_patterns {
                resolve_pattern(fp, ctx);
            }
        }
        Pattern::OrPattern { left, right } => {
            resolve_pattern(*left, ctx);
            resolve_pattern(*right, ctx);
        }
        Pattern::Guard { pattern, .. } => resolve_pattern(*pattern, ctx),
        _ => {}
    }
}

/// 解析表达式的类型（不存入表，仅返回类型描述符）
///
/// 核心类型推断逻辑：
/// 1. 字面量：直接映射（int_literal → i32, string_literal → str 等）
/// 2. identifier：查变量绑定 → 类型参数绑定 → sema_result.expr_types
/// 3. field_access：查对象类型的字段类型
/// 4. call/method_call：查函数签名返回类型或 call_instantiations 实例返回类型
/// 5. 其他：回退到 sema_result.expr_types
fn resolve_expr_type<'a, 'b>(
    expr: ExprId,
    ctx: &mut ResolveCtx<'a, 'b>,
) -> Option<&'static TypeDescriptor> {
    let ast = ctx.ast;
    let node = &ast.expr(expr).node;
    match node {
        Expr::IntLit { suffix, .. } => Some(
            suffix
                .as_deref()
                .and_then(type_descriptor_from_builtin_name)
                .unwrap_or(&I32_DESC),
        ),
        Expr::FloatLit { suffix, .. } => Some(
            suffix
                .as_deref()
                .and_then(type_descriptor_from_builtin_name)
                .unwrap_or(&F64_DESC),
        ),
        Expr::BoolLit(_) => Some(&BOOL_DESC),
        Expr::CharLit(_) => Some(&CHAR_DESC),
        Expr::StrLit(_) | Expr::StrInterp(_) => Some(&STR_DESC),
        Expr::NullLit => Some(&NULL_DESC),
        Expr::VoidLit => Some(&VOID_DESC),
        Expr::Ident(name) => {
            // 1. 查类型参数绑定
            if let Some(&idx) = ctx.type_param_map.get(name) {
                if (idx as usize) < ctx.type_args.len() {
                    return Some(ctx.type_args[idx as usize]);
                }
            }
            // 2. 查局部变量绑定
            if let Some(td) = ctx.lookup_var(name) {
                return Some(td);
            }
            // 3. 查 sema_result.expr_types
            ctx.sema_result
                .get_expr(expr.0 as u64)
                .map(td_from_expr_info)
        }
        Expr::FieldAccess { recv, field } => {
            // 递归解析对象类型，再查字段类型
            let obj_td = resolve_expr_type(*recv, ctx)?;
            if let Some((_, field_td)) = ctx.sema_result.resolve_field_td(obj_td.type_name, field) {
                return Some(field_td);
            }
            Some(ctx.sema_result.get_or_create_ref_desc(obj_td.type_name))
        }
        Expr::Call {
            callee, type_args, ..
        } => {
            if let Expr::Ident(callee_name_str) = &ast.expr(*callee).node {
                // 构造器调用：返回以类型名命名的具体描述符
                // 复制 ret_name 为 owned String，释放 ctor 的不可变借用后再 &mut
                let ctor_ret_name: Option<String> = ctx
                    .sema_result
                    .get_ctor_def(callee_name_str)
                    .map(|ctor| {
                        ctor.return_type_name
                            .as_deref()
                            .unwrap_or(ctor.type_name.as_ref())
                            .to_string()
                    });
                if let Some(ret_name) = ctor_ret_name {
                    return Some(ctx.sema_result.get_or_create_ref_desc(&ret_name));
                }
                // 优先查询 call_instantiations：泛型调用点已由 process_call_in_body 创建实例
                if let Some(&instance_id) = ctx.sema_result.call_instantiations.get(&(expr.0 as u64))
                {
                    if let Some(inst) = ctx
                        .sema_result
                        .monomorph_instances
                        .get(instance_id as usize)
                    {
                        return Some(inst.return_type);
                    }
                }
                // 非泛型函数或未命中：查 sig.return_type_desc
                if let Some(sig) = ctx.sema_result.get_func_sig(callee_name_str) {
                    return Some(sig.return_type_desc);
                }
            }
            let _ = type_args;
            Some(ctx.sema_result.get_or_create_ref_desc("call_result"))
        }
        Expr::MethodCall { .. } | Expr::SafeMethodCall { .. } => {
            // 查询 call_instantiations（process_call_in_body 已为泛型方法调用创建实例）
            if let Some(&instance_id) = ctx.sema_result.call_instantiations.get(&(expr.0 as u64)) {
                if let Some(inst) = ctx
                    .sema_result
                    .monomorph_instances
                    .get(instance_id as usize)
                {
                    return Some(inst.return_type);
                }
            }
            // 未命中：回退到 sema_result.expr_types，再回退到具名描述符
            match ctx
                .sema_result
                .get_expr(expr.0 as u64)
                .map(td_from_expr_info)
            {
                Some(td) => Some(td),
                None => Some(ctx.sema_result.get_or_create_ref_desc("method_result")),
            }
        }
        Expr::Block { trailing, .. } => {
            if let Some(te) = trailing {
                resolve_expr_type(*te, ctx)
            } else {
                Some(&VOID_DESC)
            }
        }
        _ => ctx
            .sema_result
            .get_expr(expr.0 as u64)
            .map(td_from_expr_info),
    }
}

/// 提取 callee 为 Ident 时的函数名（供 `process_call_in_body` 使用）。
fn callee_name<'a>(ast: &AstArena<'a>, callee: ExprId) -> &'a str {
    match &ast.expr(callee).node {
        Expr::Ident(name) => *name,
        _ => "",
    }
}

// =========================================================================
// phase5: subtype_check — 子类型关系判定
//
// 对 `src/sema/subtype_check.zig` 的 Rust 移植。
// 判定 Glue 语言中各种类型之间的子类型关系：null/nullable、record 结构子类型、
// ADT 错误子类型、Throw 子类型、trait 结构化子类型。
// =========================================================================

/// 命名类型实参列表结构相等：名称匹配 + 长度匹配 + 逐元素递归相等。
/// 供 Adt/Generic/Trait 三种命名复合类型共用。
#[inline]
fn named_args_equal(
    arena: &TypeArena,
    na: &str,
    ta: &[TypeHandle],
    nb: &str,
    tb: &[TypeHandle],
) -> bool {
    na == nb
        && ta.len() == tb.len()
        && ta.iter().zip(tb.iter()).all(|(&x, &y)| types_equal(arena, x, y))
}

/// 递归判定两个类型是否结构相等（resolve 后比较 ConcreteType 内容）。
///
/// 作为权威实现，`InferContext::types_structurally_equal` 委托本函数。
/// 供 `is_subtype` 等独立 checker 使用。
pub fn types_equal(arena: &TypeArena, a: TypeHandle, b: TypeHandle) -> bool {
    let ra = arena.resolve(a);
    let rb = arena.resolve(b);
    if ra == rb {
        return true;
    }
    let a_ct = arena.get(ra).clone();
    let b_ct = arena.get(rb).clone();
    if std::mem::discriminant(&a_ct) != std::mem::discriminant(&b_ct) {
        return false;
    }
    match (&a_ct, &b_ct) {
        (ConcreteType::TypeVar(ia), ConcreteType::TypeVar(ib)) => ia == ib,
        (
            ConcreteType::Fn { params: pa, return_type: ra },
            ConcreteType::Fn { params: pb, return_type: rb },
        ) => {
            pa.len() == pb.len()
                && pa.iter().zip(pb.iter()).all(|(&x, &y)| types_equal(arena, x, y))
                && types_equal(arena, *ra, *rb)
        }
        (
            ConcreteType::Record { fields: fa, .. },
            ConcreteType::Record { fields: fb, .. },
        ) => {
            if fa.len() != fb.len() {
                return false;
            }
            for (x, y) in fa.iter().zip(fb.iter()) {
                let names_match = match (x.name.as_deref(), y.name.as_deref()) {
                    (Some(a), Some(b)) => a == b,
                    (None, None) => true,
                    _ => false,
                };
                if !names_match || !types_equal(arena, x.ty, y.ty) {
                    return false;
                }
            }
            true
        }
        (
            ConcreteType::Adt { name: na, type_args: ta },
            ConcreteType::Adt { name: nb, type_args: tb },
        ) => named_args_equal(arena, na, ta, nb, tb),
        (
            ConcreteType::Generic { name: na, args: ta },
            ConcreteType::Generic { name: nb, args: tb },
        ) => named_args_equal(arena, na, ta, nb, tb),
        (
            ConcreteType::Array { element_type: ea, size: sa },
            ConcreteType::Array { element_type: eb, size: sb },
        ) => sa == sb && types_equal(arena, *ea, *eb),
        (
            ConcreteType::Throw { value_type: va, error_type: ea },
            ConcreteType::Throw { value_type: vb, error_type: eb },
        ) => types_equal(arena, *va, *vb) && types_equal(arena, *ea, *eb),
        (
            ConcreteType::Trait { name: na, type_args: ta },
            ConcreteType::Trait { name: nb, type_args: tb },
        ) => named_args_equal(arena, na, ta, nb, tb),
        (ConcreteType::Nullable(ia), ConcreteType::Nullable(ib)) => types_equal(arena, *ia, *ib),
        (ConcreteType::Ref { inner: ia, is_raw: ra }, ConcreteType::Ref { inner: ib, is_raw: rb }) => {
            ra == rb && types_equal(arena, *ia, *ib)
        }
        // 标量单元变体（I32, Bool, Str, ...）、Never, Unknown, Null, Void —
        // discriminant 已匹配即相等
        _ => true,
    }
}

/// 子类型判定规则。每条规则匹配特定 `(sub, sup)` 形状组合，命中时返回
/// `Some(bool)`，未命中返回 `None` 交由下一条规则处理。
///
/// 统一 `is_subtype` 内部散落的 if-let 分派，新增子类型规则只需添加一个
/// impl SubtypeRule 的无字段 struct 并注册到 `SUBTYPE_RULES`。
trait SubtypeRule {
    fn check(&self, arena: &TypeArena, sub: TypeHandle, sup: TypeHandle) -> Option<bool>;
}

/// 自反性：同一类型或结构相等。
struct ReflexiveRule;
impl SubtypeRule for ReflexiveRule {
    #[inline]
    fn check(&self, arena: &TypeArena, sub: TypeHandle, sup: TypeHandle) -> Option<bool> {
        let r_sub = arena.resolve(sub);
        let r_sup = arena.resolve(sup);
        if r_sub == r_sup || types_equal(arena, r_sub, r_sup) {
            Some(true)
        } else {
            None
        }
    }
}

/// `Null` 字面量可赋值给任意 `nullable`。
struct NullToNullableRule;
impl SubtypeRule for NullToNullableRule {
    fn check(&self, arena: &TypeArena, sub: TypeHandle, sup: TypeHandle) -> Option<bool> {
        let sub_ct = arena.get(arena.resolve(sub));
        let sup_ct = arena.get(arena.resolve(sup));
        if matches!(sub_ct, ConcreteType::Null) && matches!(sup_ct, ConcreteType::Nullable(_)) {
            Some(true)
        } else {
            None
        }
    }
}

/// `sub <: Nullable(inner)` ⟹ `sub <: inner`。
struct NullableInnerRule;
impl SubtypeRule for NullableInnerRule {
    fn check(&self, arena: &TypeArena, sub: TypeHandle, sup: TypeHandle) -> Option<bool> {
        let sup_ct = arena.get(arena.resolve(sup));
        if let ConcreteType::Nullable(inner) = sup_ct {
            Some(is_subtype(arena, sub, *inner))
        } else {
            None
        }
    }
}

/// Record 结构化子类型：`sub_fields` 覆盖 `sup_fields` 全部字段且类型相容。
struct RecordSubtypeRule;
impl SubtypeRule for RecordSubtypeRule {
    fn check(&self, arena: &TypeArena, sub: TypeHandle, sup: TypeHandle) -> Option<bool> {
        let sub_ct = arena.get(arena.resolve(sub));
        let sup_ct = arena.get(arena.resolve(sup));
        if let (
            ConcreteType::Record { fields: sub_fields, .. },
            ConcreteType::Record { fields: sup_fields, .. },
        ) = (sub_ct, sup_ct)
        {
            Some(is_record_subtype(arena, sub_fields, sup_fields))
        } else {
            None
        }
    }
}

/// ADT 同名子类型：直接比较类型名。`error_newtype` 子类型由调用方通过
/// `is_error_subtype`（需 `sema_result`）判定，不在本规则链内。
struct AdtNameRule;
impl SubtypeRule for AdtNameRule {
    fn check(&self, arena: &TypeArena, sub: TypeHandle, sup: TypeHandle) -> Option<bool> {
        let sub_ct = arena.get(arena.resolve(sub));
        let sup_ct = arena.get(arena.resolve(sup));
        if let (
            ConcreteType::Adt { name: sub_name, .. },
            ConcreteType::Adt { name: sup_name, .. },
        ) = (sub_ct, sup_ct)
        {
            Some(sub_name == sup_name)
        } else {
            None
        }
    }
}

/// `Throw<V1, E1> <: Throw<V2, E2>` ⟹ `V1 <: V2 ∧ E1 <: E2`。
struct ThrowSubtypeRule;
impl SubtypeRule for ThrowSubtypeRule {
    fn check(&self, arena: &TypeArena, sub: TypeHandle, sup: TypeHandle) -> Option<bool> {
        let sub_ct = arena.get(arena.resolve(sub));
        let sup_ct = arena.get(arena.resolve(sup));
        if let (
            ConcreteType::Throw { value_type: sv, error_type: se },
            ConcreteType::Throw { value_type: pv, error_type: pe },
        ) = (sub_ct, sup_ct)
        {
            Some(is_throw_subtype(arena, *sv, *se, *pv, *pe))
        } else {
            None
        }
    }
}

/// 子类型规则链：按顺序尝试每条规则，首条命中（返回 `Some`）即定夺。
/// 顺序与原 if-let 链一致：自反 → null→nullable → nullable 内层 →
/// record → ADT 同名 → throw。`error_newtype` 与 `trait 结构化` 需
/// `sema_result`，由调用方通过 `is_error_subtype` / `is_trait_structural_subtype` 判定。
const SUBTYPE_RULES: &[&dyn SubtypeRule] = &[
    &ReflexiveRule,
    &NullToNullableRule,
    &NullableInnerRule,
    &RecordSubtypeRule,
    &AdtNameRule,
    &ThrowSubtypeRule,
];

/// 判断 `sub` 是否为 `sup` 的子类型。
///
/// 通过 `SUBTYPE_RULES` 规则链分派：自反性、null→nullable、nullable 内层、
/// record 结构子类型、ADT 同名、Throw 子类型。任一规则命中即返回其结果；
/// 全部未命中返回 `false`。`error_newtype` 与 `trait 结构化` 子类型需
/// `sema_result`，由调用方通过 `is_error_subtype` / `is_trait_structural_subtype` 判定。
pub fn is_subtype(arena: &TypeArena, sub: TypeHandle, sup: TypeHandle) -> bool {
    for rule in SUBTYPE_RULES.iter() {
        if let Some(ok) = rule.check(arena, sub, sup) {
            return ok;
        }
    }
    false
}

/// 记录字段匹配核心：`provided` 字段集合是否覆盖 `required` 全部字段。
/// 按字段名匹配（位置字段 `name == None` 视为同名），匹配后调用 `check`
/// 校验字段类型兼容性。`check` 签名为 `|arena, provided_ty, required_ty|`。
///
/// 消除 `is_record_subtype` 与 `record_arg_satisfies` 的字段遍历重复。
fn match_record_fields<F>(
    arena: &TypeArena,
    required: &[FieldType],
    provided: &[FieldType],
    mut check: F,
) -> bool
where
    F: FnMut(&TypeArena, TypeHandle, TypeHandle) -> bool,
{
    for req_field in required.iter() {
        let mut found = false;
        for prov_field in provided.iter() {
            let names_match = match (prov_field.name.as_deref(), req_field.name.as_deref()) {
                (Some(a), Some(b)) => a == b,
                (None, None) => true,
                _ => false,
            };
            if names_match {
                if !check(arena, prov_field.ty, req_field.ty) {
                    return false;
                }
                found = true;
                break;
            }
        }
        if !found {
            return false;
        }
    }
    true
}

/// 记录类型结构化子类型判定：`sub_fields` 是否覆盖 `sup_fields` 全部字段。
/// 按字段名匹配，递归校验字段类型满足子类型关系（宽度+深度子类型）。
pub fn is_record_subtype(
    arena: &TypeArena,
    sub_fields: &[FieldType],
    sup_fields: &[FieldType],
) -> bool {
    // sub_fields 提供，sup_fields 要求；sub 字段类型须为 sup 字段类型的子类型。
    match_record_fields(arena, sup_fields, sub_fields, |a, prov, req| is_subtype(a, prov, req))
}

/// 错误子类型判定：当 `sup_name` 为内置 Err trait 时，任何 error_newtype ADT 都是其子类型。
pub fn is_error_subtype(sema_result: &SemaResult, sub_name: &str, sup_name: &str) -> bool {
    if sup_name != "Err" {
        return false;
    }
    match sema_result.get_type_def(sub_name) {
        Some(def) => def.kind == TypeDefKind::ErrorNewtype,
        None => false,
    }
}

/// Throw 子类型判定：值类型与错误类型需同时满足子类型关系。
pub fn is_throw_subtype(
    arena: &TypeArena,
    sub_val: TypeHandle,
    sub_err: TypeHandle,
    sup_val: TypeHandle,
    sup_err: TypeHandle,
) -> bool {
    is_subtype(arena, sub_val, sup_val) && is_subtype(arena, sub_err, sup_err)
}

/// trait 结构化子类型判定：`sub_name` 的方法集合需覆盖 `super_name` 的全部方法名。
pub fn is_trait_structural_subtype(
    sema_result: &SemaResult,
    sub_name: &str,
    sup_name: &str,
) -> bool {
    let sub_def = match sema_result.get_trait_def(sub_name) {
        Some(d) => d,
        None => return false,
    };
    let sup_def = match sema_result.get_trait_def(sup_name) {
        Some(d) => d,
        None => return false,
    };
    for sup_method in sup_def.methods.iter() {
        let found = sub_def
            .methods
            .iter()
            .any(|m| m.name.as_ref() == sup_method.name.as_ref());
        if !found {
            return false;
        }
    }
    true
}

/// 判断实参记录 `arg` 是否满足形参记录 `param` 的字段要求。
/// 非记录类型视为满足；记录类型则递归校验每个形参字段都存在且类型满足。
pub fn record_arg_satisfies(arena: &TypeArena, param: TypeHandle, arg: TypeHandle) -> bool {
    let rp = arena.resolve(param);
    let ra = arena.resolve(arg);
    let param_ct = arena.get(rp).clone();
    let arg_ct = arena.get(ra).clone();
    match (&param_ct, &arg_ct) {
        (
            ConcreteType::Record { fields: pf, .. },
            ConcreteType::Record { fields: af, .. },
        ) => {
            // pf 要求，af 提供；递归校验。
            match_record_fields(arena, pf, af, |a, prov, req| record_arg_satisfies(a, req, prov))
        }
        _ => true,
    }
}

// =========================================================================
// phase5: throw_check 辅助 — 数值宽化与返回类型统一
//
// 对 `src/sema/throw_check.zig` 中数值宽化辅助函数的 Rust 移植。
// InferContext 方法（unify_return_type / try_widen_unify / check_propagate /
// check_throw_stmt）在下方 InferContext impl 块中实现。
// =========================================================================

/// 返回整型的秩（用于宽化比较），同宽有符号/无符号共享同一秩，非整型返回 0。
#[inline]
pub fn int_type_rank(ct: &ConcreteType) -> u8 {
    match ct.classify_scalar() {
        Some(ScalarInfo { kind: ScalarKind::SignedInt | ScalarKind::UnsignedInt, rank, .. }) => rank,
        _ => 0,
    }
}

/// 返回浮点类型的秩（用于宽化比较），非浮点返回 0。
#[inline]
pub fn float_type_rank(ct: &ConcreteType) -> u8 {
    match ct.classify_scalar() {
        Some(ScalarInfo { kind: ScalarKind::Float, rank, .. }) => rank,
        _ => 0,
    }
}

/// 判断是否为有符号整型（自由函数版，与 ConcreteType::is_signed_int 等价）。
#[inline]
pub fn is_signed_int_ct(ct: &ConcreteType) -> bool {
    matches!(
        ct.classify_scalar().map(|i| i.kind),
        Some(ScalarKind::SignedInt)
    )
}

/// 判断数值类型 `from` 是否可被隐式宽化为数值类型 `to`。
/// 覆盖整型之间、浮点之间以及整型到浮点的宽化规则。
pub fn can_coerce_numeric(arena: &TypeArena, to: TypeHandle, from: TypeHandle) -> bool {
    let to_ct = arena.get(arena.resolve(to)).clone();
    let from_ct = arena.get(arena.resolve(from)).clone();
    let to_int = int_type_rank(&to_ct);
    let from_int = int_type_rank(&from_ct);
    let to_float = float_type_rank(&to_ct);
    let from_float = float_type_rank(&from_ct);

    // 整型之间：同秩或目标秩更大时允许宽化
    if to_int > 0 && from_int > 0 {
        let to_signed = is_signed_int_ct(&to_ct);
        let from_signed = is_signed_int_ct(&from_ct);
        if to_int == from_int && to_signed == from_signed {
            return true;
        }
        if to_signed == from_signed {
            return to_int >= from_int;
        }
        // 有符号 → 无符号需目标秩严格更大以容纳符号位
        return to_int > from_int;
    }
    // 浮点之间：同秩或目标秩更大时允许宽化（禁止窄化）
    if to_float > 0 && from_float > 0 {
        return to_float >= from_float;
    }
    // 整型 → 浮点：允许
    if to_float > 0 && from_int > 0 {
        return true;
    }
    false
}

// =========================================================================
// phase5: kind_check — 类型种类检查
//
// 对 `src/sema/kind_check.zig` 的 Rust 移植。
// 校验类型注解中类型构造器的使用是否与其种类（arity）一致。
// =========================================================================

/// 返回类型名为 `name` 的类型构造器所期望的类型参数个数（种类 arity）。
/// 内置高阶类型使用固定 arity，自定义 ADT 取其声明的类型参数个数，其余裸类型名 arity 为 0。
pub fn arity_of_type_name(sema_result: &SemaResult, name: &str) -> usize {
    if let Some(arity) = generic_type_arity(name) {
        return arity as usize;
    }
    match sema_result.get_type_def(name) {
        Some(def) => def.type_params.len(),
        None => 0,
    }
}

/// 判断 `name` 是否为当前作用域内的类型参数。
fn is_type_param(name: &str, type_param_names: &[&str]) -> bool {
    type_param_names.iter().any(|tp| *tp == name)
}

/// 递归检查类型节点树中每个类型构造器的使用是否符合其种类 arity。
/// `type_param_names` 给出当前作用域内合法的类型参数名（可作具体类型使用）。
/// 发现不匹配时将错误追加到 `errors`。
pub fn check_type_node(
    sema_result: &SemaResult,
    ast: &AstArena<'_>,
    node: AstTypeRef,
    type_param_names: &[&str],
    errors: &mut Vec<SemaError>,
) {
    let tn = &ast.ty(node).node;
    let span = ast.ty(node).span;
    match tn {
        TypeNode::Named { name } => {
            if is_type_param(name, type_param_names) {
                return;
            }
            let arity = arity_of_type_name(sema_result, name);
            if arity > 0 {
                errors.push(SemaError::new(
                    &format!(
                        "kind mismatch: type constructor '{}' expects {} type argument(s) but is used as a concrete type",
                        name, arity
                    ),
                    span.line,
                    span.column,
                ));
            }
        }
        TypeNode::SelfType => {}
        TypeNode::Generic { name, args } => {
            if !is_type_param(name, type_param_names) {
                let arity = arity_of_type_name(sema_result, name);
                if arity != 0 && arity != args.len() {
                    errors.push(SemaError::new(
                        &format!(
                            "kind mismatch: type constructor '{}' expects {} type argument(s) but got {}",
                            name,
                            arity,
                            args.len()
                        ),
                        span.line,
                        span.column,
                    ));
                }
            }
            for &arg in args.iter() {
                check_type_node(sema_result, ast, arg, type_param_names, errors);
            }
        }
        TypeNode::Nullable { inner } => {
            check_type_node(sema_result, ast, *inner, type_param_names, errors);
        }
        TypeNode::RefType { inner } => {
            check_type_node(sema_result, ast, *inner, type_param_names, errors);
        }
        TypeNode::RawPtr { inner } => {
            check_type_node(sema_result, ast, *inner, type_param_names, errors);
        }
        TypeNode::Function { params, return_type } => {
            for &p in params.iter() {
                check_type_node(sema_result, ast, p, type_param_names, errors);
            }
            check_type_node(sema_result, ast, *return_type, type_param_names, errors);
        }
        TypeNode::Record { fields } => {
            for f in fields.iter() {
                check_type_node(sema_result, ast, f.ty, type_param_names, errors);
            }
        }
        TypeNode::Array { element_type, .. } => {
            check_type_node(sema_result, ast, *element_type, type_param_names, errors);
        }
        TypeNode::KindAnnotated { inner, .. } => {
            check_type_node(sema_result, ast, *inner, type_param_names, errors);
        }
    }
}

/// 计算类型节点剩余的种类 arity：即还差多少个类型参数才能成为具体类型。
/// 裸类型名返回其 arity；部分应用的高阶类型返回 (arity - 已提供参数数)。
pub fn kind_arity_of_type_node(sema_result: &SemaResult, ast: &AstArena<'_>, node: AstTypeRef) -> usize {
    let tn = &ast.ty(node).node;
    match tn {
        TypeNode::Named { name } => arity_of_type_name(sema_result, name),
        TypeNode::Generic { name, args } => {
            let head = arity_of_type_name(sema_result, name);
            if args.len() >= head {
                0
            } else {
                head - args.len()
            }
        }
        _ => 0,
    }
}

// =========================================================================
// phase5: module_check — 模块结构检查
//
// 对 `src/sema/module_check.zig` 的 Rust 移植。
// 提供模块成员方法签名摘要，以及模块是否结构化满足某 trait 所需方法集合的判定。
// =========================================================================

/// 模块成员方法的签名摘要：方法名与参数个数。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MethodSig {
    pub name: Box<str>,
    pub arity: usize,
}

/// 模块结构化匹配 trait 的失败原因。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MatchReason {
    /// 匹配成功
    Ok,
    /// 缺少方法
    Missing,
    /// 参数个数不符
    ArityMismatch,
}

/// 模块结构化匹配 trait 的结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MatchResult {
    pub ok: bool,
    pub missing_method: Option<Box<str>>,
    pub arity_expected: usize,
    pub arity_got: usize,
    pub reason: MatchReason,
}

impl MatchResult {
    /// 匹配成功。
    pub fn ok() -> Self {
        MatchResult {
            ok: true,
            missing_method: None,
            arity_expected: 0,
            arity_got: 0,
            reason: MatchReason::Ok,
        }
    }
}

/// 模块检查器：判断一组提供的方法签名是否结构化满足一组必需的方法签名。
#[derive(Debug, Default)]
pub struct ModuleChecker;

impl ModuleChecker {
    pub fn new() -> Self {
        ModuleChecker
    }

    /// 逐个校验 `required` 中的方法是否在 `provided` 中存在且参数个数一致。
    /// 任一方法缺失或参数个数不符即返回带原因的失败结果。
    pub fn structurally_satisfies(
        &self,
        provided: &[MethodSig],
        required: &[MethodSig],
    ) -> MatchResult {
        for req in required.iter() {
            let found = provided.iter().find(|p| p.name.as_ref() == req.name.as_ref());
            match found {
                Some(prov) => {
                    if prov.arity != req.arity {
                        return MatchResult {
                            ok: false,
                            missing_method: Some(req.name.clone()),
                            arity_expected: req.arity,
                            arity_got: prov.arity,
                            reason: MatchReason::ArityMismatch,
                        };
                    }
                }
                None => {
                    return MatchResult {
                        ok: false,
                        missing_method: Some(req.name.clone()),
                        arity_expected: 0,
                        arity_got: 0,
                        reason: MatchReason::Missing,
                    };
                }
            }
        }
        MatchResult::ok()
    }

    /// 从 trait 方法声明中收集无方法体（即需要被实现）的方法签名。
    pub fn required_methods(&self, trait_methods: &[MethodDecl<'_>]) -> Vec<MethodSig> {
        let mut list = Vec::new();
        for m in trait_methods.iter() {
            if m.body.is_some() {
                continue;
            }
            list.push(MethodSig {
                name: m.name.into(),
                arity: m.params.len(),
            });
        }
        list
    }
}

// =========================================================================
// phase5: InferContext 扩展 — 类型解析、freshen、结构相等、throw 检查
//
// 新增 InferContext 方法，移植自 `src/sema/type_check.zig` 与 `throw_check.zig`。
// =========================================================================

impl<'a> InferContext<'a> {
    // ── 类型解析（typeFromAst）──

    /// 将 AST TypeNode 解析为 TypeHandle（便捷版，无类型参数映射）。
    pub fn type_from_ast(&mut self, type_ref: AstTypeRef, ast: &AstArena<'_>) -> TypeHandle {
        let empty = HashMap::new();
        self.type_from_ast_with_params(type_ref, ast, &empty)
    }

    /// 将 AST TypeNode 解析为 TypeHandle（完整版，带类型参数映射）。
    ///
    /// 处理所有 TypeNode 变体：Named、SelfType、Generic、Nullable、RefType、RawPtr、
    /// Function、Record、Array、KindAnnotated。内置标量走 from_scalar_name；
    /// 泛型 Throw 特殊处理为 Throw 类型；其余内置泛型构造为 Generic；
    /// 自定义 ADT 构造为 Adt；trait 构造为 Trait。
    pub fn type_from_ast_with_params(
        &mut self,
        type_ref: AstTypeRef,
        ast: &AstArena<'_>,
        type_param_map: &HashMap<String, TypeHandle>,
    ) -> TypeHandle {
        let tn = &ast.ty(type_ref).node;
        match tn {
            TypeNode::Named { name } => {
                // 1. 类型参数映射
                if let Some(ty) = type_param_map.get(*name) {
                    return *ty;
                }
                // 2. 类型绑定栈（泛型作用域）
                if let Some(ty) = self.lookup_type_binding(name) {
                    return ty;
                }
                // 3. 内置标量
                match *name {
                    "i8" => return self.arena.make(ConcreteType::I8),
                    "i16" => return self.arena.make(ConcreteType::I16),
                    "i32" => return self.arena.make(ConcreteType::I32),
                    "i64" => return self.arena.make(ConcreteType::I64),
                    "i128" => return self.arena.make(ConcreteType::I128),
                    "u8" => return self.arena.make(ConcreteType::U8),
                    "u16" => return self.arena.make(ConcreteType::U16),
                    "u32" => return self.arena.make(ConcreteType::U32),
                    "u64" => return self.arena.make(ConcreteType::U64),
                    "u128" => return self.arena.make(ConcreteType::U128),
                    "isize" => return self.arena.make(ConcreteType::Isize),
                    "usize" => return self.arena.make(ConcreteType::Usize),
                    "f16" => return self.arena.make(ConcreteType::F16),
                    "f32" => return self.arena.make(ConcreteType::F32),
                    "f64" => return self.arena.make(ConcreteType::F64),
                    "f128" => return self.arena.make(ConcreteType::F128),
                    "bool" => return self.arena.make(ConcreteType::Bool),
                    "str" => return self.arena.make(ConcreteType::Str),
                    "char" => return self.arena.make(ConcreteType::Char),
                    "Null" => return self.arena.make(ConcreteType::Null),
                    "void" => return self.arena.make(ConcreteType::Void),
                    _ => {}
                }
                // 4. trait 定义 → Trait 类型
                if self.sema_result.get_trait_def(name).is_some() {
                    return self.arena.make(ConcreteType::Trait {
                        name: (*name).into(),
                        type_args: Box::new([]),
                    });
                }
                // 5. 用户自定义类型 → Adt
                self.arena.make(ConcreteType::Adt {
                    name: (*name).into(),
                    type_args: Box::new([]),
                })
            }
            TypeNode::SelfType => match self.current_self_type() {
                Some(ty) => ty,
                None => {
                    self.add_error("Self type can only be used within type or trait methods");
                    self.arena.make(ConcreteType::Void)
                }
            },
            TypeNode::Generic { name, args } => {
                // 递归解析类型实参
                let new_args: Vec<TypeHandle> = args
                    .iter()
                    .map(|&a| self.type_from_ast_with_params(a, ast, type_param_map))
                    .collect();
                let args_box: Box<[TypeHandle]> = new_args.into_boxed_slice();

                // 类型参数映射中的高阶类型
                if type_param_map.contains_key(*name) {
                    return self.arena.make(ConcreteType::Generic {
                        name: (*name).into(),
                        args: args_box,
                    });
                }
                // Throw 特殊处理
                if *name == "Throw" && args_box.len() == 2 {
                    return self.arena.make(ConcreteType::Throw {
                        value_type: args_box[0],
                        error_type: args_box[1],
                    });
                }
                // 内置泛型类型（Atomic/Async/Channel 等）
                if is_builtin_generic_type(name) {
                    return self.arena.make(ConcreteType::Generic {
                        name: (*name).into(),
                        args: args_box,
                    });
                }
                // trait 定义 → Trait 类型
                if self.sema_result.get_trait_def(name).is_some() {
                    return self.arena.make(ConcreteType::Trait {
                        name: (*name).into(),
                        type_args: args_box,
                    });
                }
                // 用户自定义泛型 ADT
                let has_type_params = self
                    .sema_result
                    .get_type_def(name)
                    .map(|d| !d.type_params.is_empty())
                    .unwrap_or(false);
                if has_type_params {
                    return self.arena.make(ConcreteType::Adt {
                        name: (*name).into(),
                        type_args: args_box,
                    });
                }
                // 兜底：构造 Generic（可能未定义，后续报错）
                self.arena.make(ConcreteType::Generic {
                    name: (*name).into(),
                    args: args_box,
                })
            }
            TypeNode::Nullable { inner } => {
                let inner_ty = self.type_from_ast_with_params(*inner, ast, type_param_map);
                self.arena.make(ConcreteType::Nullable(inner_ty))
            }
            TypeNode::RefType { inner } => {
                let inner_ty = self.type_from_ast_with_params(*inner, ast, type_param_map);
                self.arena.make(ConcreteType::Ref {
                    inner: inner_ty,
                    is_raw: false,
                })
            }
            TypeNode::RawPtr { inner } => {
                let inner_ty = self.type_from_ast_with_params(*inner, ast, type_param_map);
                self.arena.make(ConcreteType::Ref {
                    inner: inner_ty,
                    is_raw: true,
                })
            }
            TypeNode::Function { params, return_type } => {
                let new_params: Vec<TypeHandle> = params
                    .iter()
                    .map(|&p| self.type_from_ast_with_params(p, ast, type_param_map))
                    .collect();
                let new_ret = self.type_from_ast_with_params(*return_type, ast, type_param_map);
                self.arena.make(ConcreteType::Fn {
                    params: new_params.into_boxed_slice(),
                    return_type: new_ret,
                })
            }
            TypeNode::Record { fields } => {
                if fields.is_empty() {
                    return self.arena.make(ConcreteType::Void);
                }
                let new_fields: Vec<FieldType> = fields
                    .iter()
                    .map(|f| FieldType {
                        name: Some(f.name.into()),
                        ty: self.type_from_ast_with_params(f.ty, ast, type_param_map),
                    })
                    .collect();
                self.arena.make(ConcreteType::Record {
                    fields: new_fields.into_boxed_slice(),
                    name: None,
                })
            }
            TypeNode::Array { element_type, size } => {
                let elem_ty = self.type_from_ast_with_params(*element_type, ast, type_param_map);
                self.arena.make(ConcreteType::Array {
                    element_type: elem_ty,
                    size: *size,
                })
            }
            TypeNode::KindAnnotated { inner, .. } => {
                self.type_from_ast_with_params(*inner, ast, type_param_map)
            }
        }
    }

    // ── freshen_type / apply_type_subst ──

    /// 刷新类型：将类型中的未绑定 TypeVar 替换为新的 TypeVar。
    /// 用于从环境查找泛型函数类型时保持各次调用的独立性（替代旧 HM instantiate）。
    pub fn freshen_type(&mut self, ty: TypeHandle) -> TypeHandle {
        // 1. 收集所有未绑定的 TypeVar idx
        let mut free_vars: Vec<u32> = Vec::new();
        self.collect_free_vars(ty, &mut free_vars);
        if free_vars.is_empty() {
            return ty;
        }
        // 2. 为每个 free var 分配 fresh var，构建替换表
        let mut subst: HashMap<u32, TypeHandle> = HashMap::new();
        for idx in free_vars.iter() {
            let fresh = self.arena.fresh_type_var();
            subst.insert(*idx, fresh);
        }
        // 3. 应用替换
        self.apply_type_subst(ty, &subst)
    }

    /// 递归收集类型中的未绑定 TypeVar idx（去重）。
    fn collect_free_vars(&self, ty: TypeHandle, free_vars: &mut Vec<u32>) {
        let resolved = self.arena.resolve(ty);
        match self.arena.get(resolved) {
            ConcreteType::TypeVar(idx) => {
                if !free_vars.contains(idx) {
                    free_vars.push(*idx);
                }
            }
            ConcreteType::Fn { params, return_type } => {
                for &p in params.iter() {
                    self.collect_free_vars(p, free_vars);
                }
                self.collect_free_vars(*return_type, free_vars);
            }
            ConcreteType::Record { fields, .. } => {
                for f in fields.iter() {
                    self.collect_free_vars(f.ty, free_vars);
                }
            }
            ConcreteType::Adt { type_args, .. } => {
                for &a in type_args.iter() {
                    self.collect_free_vars(a, free_vars);
                }
            }
            ConcreteType::Nullable(inner) => self.collect_free_vars(*inner, free_vars),
            ConcreteType::Ref { inner, .. } => self.collect_free_vars(*inner, free_vars),
            ConcreteType::Generic { args, .. } => {
                for &a in args.iter() {
                    self.collect_free_vars(a, free_vars);
                }
            }
            ConcreteType::Array { element_type, .. } => {
                self.collect_free_vars(*element_type, free_vars)
            }
            ConcreteType::Throw { value_type, error_type } => {
                self.collect_free_vars(*value_type, free_vars);
                self.collect_free_vars(*error_type, free_vars);
            }
            ConcreteType::Trait { type_args, .. } => {
                for &a in type_args.iter() {
                    self.collect_free_vars(a, free_vars);
                }
            }
            _ => {}
        }
    }

    /// 用替换表替换类型中的 TypeVar（按 idx）。无副作用，返回新类型。
    /// 委托给已有的 `substitute_type` 实现。
    pub fn apply_type_subst(
        &mut self,
        ty: TypeHandle,
        subst: &HashMap<u32, TypeHandle>,
    ) -> TypeHandle {
        self.substitute_type(ty, subst)
    }

    // ── types_structurally_equal ──

    /// 无副作用的类型结构相等检查：不修改任何 TypeVar，不触发 unify 副作用。
    /// 用于 trait 方法签名匹配时比较参数类型和返回类型。
    ///
    /// 委托给自由函数 `types_equal`，避免重复维护两套结构相等逻辑。
    pub fn types_structurally_equal(&self, a: TypeHandle, b: TypeHandle) -> bool {
        types_equal(self.arena, a, b)
    }

    // ── throw_check 方法 ──

    /// 统一函数声明的返回类型与函数体推断出的类型。
    /// 针对 nullable/throw 返回类型有特殊放宽：函数体返回 void（早退/抛出）
    /// 时不视为不匹配；否则尝试宽化统一，失败再回退到严格 unify。
    pub fn unify_return_type(
        &mut self,
        declared: TypeHandle,
        inferred: TypeHandle,
    ) -> Result<(), UnifyError> {
        let r_declared = self.arena.resolve(declared);
        let r_inferred = self.arena.resolve(inferred);

        // async 函数：声明返回类型应为 Async<X>，body 推断为 Async<Y>
        // 递归统一内部类型 X 与 Y
        let declared_ct = self.arena.get(r_declared).clone();
        let inferred_ct = self.arena.get(r_inferred).clone();
        if let (
            ConcreteType::Generic { name: dn, args: da },
            ConcreteType::Generic { name: in_, args: ia },
        ) = (&declared_ct, &inferred_ct)
        {
            if dn.as_ref() == "Async" && in_.as_ref() == "Async" && da.len() == 1 && ia.len() == 1
            {
                return self.unify_return_type(da[0], ia[0]);
            }
        }

        match &declared_ct {
            ConcreteType::Nullable(inner) => match &inferred_ct {
                ConcreteType::Nullable(_) => self.arena.unify(declared, inferred),
                ConcreteType::Void => Ok(()), // 函数体未产生值，与 nullable 兼容
                _ => {
                    let inner_ty = *inner;
                    match self.try_widen_unify(inner_ty, r_inferred) {
                        Ok(_) => Ok(()),
                        Err(_) => self.arena.unify(inner_ty, r_inferred),
                    }
                }
            },
            ConcreteType::Throw { value_type, .. } => match &inferred_ct {
                ConcreteType::Throw { .. } => {
                    match self.try_widen_unify(declared, inferred) {
                        Ok(_) => Ok(()),
                        Err(_) => self.arena.unify(declared, inferred),
                    }
                }
                ConcreteType::Void => Ok(()), // 函数体未产生值，与 throw 兼容
                _ => {
                    let vt = *value_type;
                    match self.try_widen_unify(vt, r_inferred) {
                        Ok(_) => Ok(()),
                        Err(_) => self.arena.unify(vt, r_inferred),
                    }
                }
            },
            _ => {
                match self.try_widen_unify(r_declared, r_inferred) {
                    Ok(_) => Ok(()),
                    Err(_) => self.arena.unify(declared, inferred),
                }
            }
        }
    }

    /// 尝试对两个类型进行宽化统一，返回统一后的类型。
    /// 先尝试严格 unify；失败时若二者均为数值则按宽化规则择一返回；
    /// 否则针对 nullable/throw 与普通类型、void 等组合做结构性兼容处理。
    pub fn try_widen_unify(
        &mut self,
        t1: TypeHandle,
        t2: TypeHandle,
    ) -> Result<TypeHandle, UnifyError> {
        let r1 = self.arena.resolve(t1);
        let r2 = self.arena.resolve(t2);

        // never 与任何类型统一为对方
        if matches!(self.arena.get(r1), ConcreteType::Never) {
            return Ok(r2);
        }
        if matches!(self.arena.get(r2), ConcreteType::Never) {
            return Ok(r1);
        }

        // 先尝试严格 unify
        match self.arena.unify(r1, r2) {
            Ok(_) => return Ok(r1),
            Err(_) => {}
        }

        let c1 = self.arena.get(r1).clone();
        let c2 = self.arena.get(r2).clone();

        // 数值类型之间尝试宽化
        if c1.is_numeric() && c2.is_numeric() {
            if can_coerce_numeric(self.arena, r1, r2) {
                return Ok(r1);
            }
            if can_coerce_numeric(self.arena, r2, r1) {
                return Ok(r2);
            }
            return Err(UnifyError::TypeMismatch);
        }

        match (&c1, &c2) {
            (ConcreteType::Nullable(inner1), _) => match &c2 {
                ConcreteType::Nullable(inner2) => {
                    let i1 = self.arena.resolve(*inner1);
                    let i2 = self.arena.resolve(*inner2);
                    match self.arena.unify(i1, i2) {
                        Ok(_) => Ok(r1),
                        Err(_) => {
                            if self.arena.get(i1).is_numeric()
                                && self.arena.get(i2).is_numeric()
                                && can_coerce_numeric(self.arena, i1, i2)
                            {
                                Ok(r1)
                            } else {
                                Err(UnifyError::TypeMismatch)
                            }
                        }
                    }
                }
                ConcreteType::Void => Ok(r1), // void 可视为 nullable 的"空值"
                _ => {
                    // nullable<T> 与 T 兼容
                    let inner1_ty = *inner1;
                    match self.arena.unify(inner1_ty, r2) {
                        Ok(_) => Ok(r1),
                        Err(_) => {
                            let i1 = self.arena.resolve(inner1_ty);
                            let r2r = self.arena.resolve(r2);
                            if self.arena.get(i1).is_numeric()
                                && self.arena.get(r2r).is_numeric()
                                && can_coerce_numeric(self.arena, i1, r2r)
                            {
                                Ok(r1)
                            } else {
                                Err(UnifyError::TypeMismatch)
                            }
                        }
                    }
                }
            },
            (ConcreteType::Throw { value_type: vt1, error_type: et1 }, _) => match &c2 {
                ConcreteType::Throw { value_type: vt2, error_type: et2 } => {
                    let v1 = self.arena.resolve(*vt1);
                    let v2 = self.arena.resolve(*vt2);
                    let e1 = self.arena.resolve(*et1);
                    let e2 = self.arena.resolve(*et2);
                    self.arena.unify(e1, e2)?;
                    match self.arena.unify(v1, v2) {
                        Ok(_) => Ok(r1),
                        Err(_) => {
                            match self.try_widen_unify(v1, v2) {
                                Ok(_) => Ok(r1),
                                Err(_) => {
                                    if self.arena.get(v1).is_numeric()
                                        && self.arena.get(v2).is_numeric()
                                        && can_coerce_numeric(self.arena, v1, v2)
                                    {
                                        Ok(r1)
                                    } else {
                                        Err(UnifyError::TypeMismatch)
                                    }
                                }
                            }
                        }
                    }
                }
                ConcreteType::Void => Ok(r1), // void 可视为 throw 的"未取值"
                _ => {
                    // Throw<T, E> 与 T 兼容（仅取值维度）
                    let vt1_ty = *vt1;
                    match self.arena.unify(vt1_ty, r2) {
                        Ok(_) => Ok(r1),
                        Err(_) => {
                            let v1 = self.arena.resolve(vt1_ty);
                            let r2r = self.arena.resolve(r2);
                            if self.arena.get(v1).is_numeric()
                                && self.arena.get(r2r).is_numeric()
                                && can_coerce_numeric(self.arena, v1, r2r)
                            {
                                Ok(r1)
                            } else {
                                Err(UnifyError::TypeMismatch)
                            }
                        }
                    }
                }
            },
            (ConcreteType::Void, _) => match &c2 {
                ConcreteType::Nullable(_) | ConcreteType::Throw { .. } => Ok(r2),
                _ => Err(UnifyError::TypeMismatch),
            },
            (_, ConcreteType::Nullable(inner2)) => {
                // T 与 nullable<T> 兼容，统一为 nullable
                let inner2_ty = *inner2;
                self.arena.unify(r1, inner2_ty)?;
                Ok(r2)
            }
            (_, ConcreteType::Throw { value_type: vt2, .. }) => {
                // T 与 Throw<T, E> 兼容，统一为 throw
                let vt2_ty = *vt2;
                self.arena.unify(r1, vt2_ty)?;
                Ok(r2)
            }
            _ => Err(UnifyError::TypeMismatch),
        }
    }

    /// 检查传播操作符 `?` 在表达式上的合法性，并返回展开后的类型。
    /// - nullable：展开为内层类型
    /// - throw：展开为值类型
    /// - 其它类型：报错并返回原类型
    pub fn check_propagate(&mut self, resolved_inner: TypeHandle, inner_ty: TypeHandle) -> TypeHandle {
        let ct = self.arena.get(resolved_inner).clone();
        match ct {
            ConcreteType::Nullable(inner) => inner,
            ConcreteType::Throw { value_type, .. } => value_type,
            _ => {
                self.add_error(
                    "propagation operator '?' cannot be used on a non-nullable, non-throw expression",
                );
                inner_ty
            }
        }
    }

    /// 检查 throw 语句的表达式是否为 Error 子类型。
    /// 合法情况：error_newtype ADT、实现了 Error trait 的类型、throw 类型、type_var（延迟）。
    pub fn check_throw_stmt(&mut self, thrown_ty: TypeHandle, _line: u32, _column: u32) {
        let resolved = self.arena.resolve(thrown_ty);
        let ct = self.arena.get(resolved).clone();
        match &ct {
            ConcreteType::TypeVar(_) => return,   // 延迟到统一阶段
            ConcreteType::Throw { .. } => return, // throw Error("...") 返回 Throw，合法
            ConcreteType::Adt { name, .. } | ConcreteType::Generic { name, .. } => {
                // 检查是否为 error_newtype
                if let Some(def) = self.sema_result.get_type_def(name) {
                    if def.kind == TypeDefKind::ErrorNewtype {
                        return;
                    }
                }
                // 检查是否实现 Error trait（key 格式 "Error::TypeName"）
                let trait_key = format!("Error::{}", name);
                // registered_traits 在 Zig 中是 inferencer 字段；Rust 版暂用 type_def kind 判定
                // 完整实现需 trait impl 注册表（phase6 补充），此处保守放行 error_newtype
                let _ = trait_key;
            }
            _ => {}
        }
        self.add_error("throw expression must be an Err subtype");
    }

    // ── infer_expr / infer_stmt / infer_pattern 占位（下方实现）──

    /// 获取内置标量类型的 TypeHandle（辅助）。
    fn make_builtin(&mut self, ct: ConcreteType) -> TypeHandle {
        self.arena.make(ct)
    }

    /// 判断表达式是否为字面量（用于 peer_type_binary 调用方判断）。
    fn expr_is_literal(ast: &AstArena<'_>, expr: ExprId) -> bool {
        matches!(
            ast.expr(expr).node,
            Expr::IntLit { .. }
                | Expr::FloatLit { .. }
                | Expr::BoolLit(_)
                | Expr::CharLit(_)
                | Expr::StrLit(_)
                | Expr::NullLit
                | Expr::VoidLit
        )
    }

    /// 解引用 ref 类型，返回 inner；非 ref 返回原类型。
    fn unwrap_ref(&self, ty: TypeHandle) -> TypeHandle {
        let resolved = self.arena.resolve(ty);
        match self.arena.get(resolved) {
            ConcreteType::Ref { inner, .. } => *inner,
            _ => resolved,
        }
    }
}

// =========================================================================
// phase5: InferContext 扩展 — 表达式/语句/模式推断 + 模块检查入口
//
// 移植自 `src/sema/type_check.zig` 的 inferExpr / inferStmt / inferPattern /
// registerBuiltins / checkModuleWithName。
// =========================================================================

impl<'a> InferContext<'a> {
    // ── 类型描述符转换辅助 ──

    /// 将 ConcreteType 转换为 &'static TypeDescriptor。
    /// 内置标量走静态表；用户类型走 sema_result.get_or_create_ref_desc。
    fn concrete_type_to_desc(&mut self, ct: &ConcreteType) -> &'static TypeDescriptor {
        if let Some(name) = ct.builtin_name() {
            if let Some(td) = type_descriptor_from_builtin_name(name) {
                return td;
            }
        }
        match ct {
            ConcreteType::Adt { name, .. }
            | ConcreteType::Generic { name, .. }
            | ConcreteType::Trait { name, .. } => self.sema_result.get_or_create_ref_desc(name),
            ConcreteType::Array { .. } => self.sema_result.get_or_create_ref_desc("array"),
            ConcreteType::Fn { .. } => self.sema_result.get_or_create_ref_desc("fn"),
            ConcreteType::Record { .. } => self.sema_result.get_or_create_ref_desc("record"),
            ConcreteType::Nullable(_) => self.sema_result.get_or_create_ref_desc("nullable"),
            ConcreteType::Ref { inner, .. } => {
                let inner_resolved = self.arena.resolve(*inner);
                let inner_name = self
                    .arena
                    .type_name(inner_resolved)
                    .map(|s| s.to_string())
                    .unwrap_or_else(|| "ref".to_string());
                self.sema_result.get_or_create_ref_desc(&inner_name)
            }
            _ => &VOID_DESC,
        }
    }

    /// 将推断出的类型存储为 ExprInfo 到 sema_result.expr_types。
    fn store_expr_info(&mut self, expr: ExprId, ty: TypeHandle) {
        let resolved = self.arena.resolve(ty);
        let ct = self.arena.get(resolved).clone();
        let type_name: Option<String> = self.arena.type_name(resolved).map(|s| s.to_string());
        let is_ref = matches!(ct, ConcreteType::Ref { .. });
        let is_raw_ref = matches!(ct, ConcreteType::Ref { is_raw: true, .. });

        // nullable 的 inner 描述符
        let inner_type_desc: Option<&'static TypeDescriptor> = if let ConcreteType::Nullable(
            inner,
        ) = &ct
        {
            let inner_resolved = self.arena.resolve(*inner);
            let inner_ct = self.arena.get(inner_resolved).clone();
            Some(self.concrete_type_to_desc(&inner_ct))
        } else {
            None
        };

        let type_desc = self.concrete_type_to_desc(&ct);
        let info = ExprInfo {
            type_desc,
            inner_type_desc,
            const_val: None,
            expr_id: expr.0 as u64,
            type_name: type_name.map(|s| s.into_boxed_str()),
            is_ref_type: is_ref,
            is_raw_ref,
            type_args: None,
            fn_sig: None,
        };
        self.sema_result.put_expr(expr.0 as u64, info);
    }

    // ── infer_expr ──

    /// 推断表达式的类型。这是类型检查的核心入口，递归处理所有表达式变体。
    /// 推断完成后将 ExprInfo 存储到 sema_result。
    pub fn infer_expr(
        &mut self,
        expr: ExprId,
        ast: &AstArena<'_>,
        env: EnvId,
        expected: Option<TypeHandle>,
    ) -> TypeHandle {
        let ty = self.infer_expr_inner(expr, ast, env, expected);
        self.store_expr_info(expr, ty);
        ty
    }

    /// 表达式类型推断内部实现（不存储 ExprInfo）。
    fn infer_expr_inner(
        &mut self,
        expr: ExprId,
        ast: &AstArena<'_>,
        env: EnvId,
        expected: Option<TypeHandle>,
    ) -> TypeHandle {
        let node = &ast.expr(expr).node;
        match node {
            // ── 字面量 ──
            Expr::IntLit { suffix, .. } => {
                if let Some(suf) = suffix {
                    if let Some(ty) = self.int_suffix_to_type(suf) {
                        return ty;
                    }
                }
                if let Some(exp) = expected {
                    let resolved = self.arena.resolve(exp);
                    if self.arena.get(resolved).is_int() {
                        return exp;
                    }
                }
                self.make_builtin(ConcreteType::I32)
            }
            Expr::FloatLit { suffix, .. } => {
                if let Some(suf) = suffix {
                    if let Some(ty) = self.float_suffix_to_type(suf) {
                        return ty;
                    }
                }
                if let Some(exp) = expected {
                    let resolved = self.arena.resolve(exp);
                    if self.arena.get(resolved).is_float() {
                        return exp;
                    }
                }
                self.make_builtin(ConcreteType::F64)
            }
            Expr::BoolLit(_) => self.make_builtin(ConcreteType::Bool),
            Expr::CharLit(_) => self.make_builtin(ConcreteType::Char),
            Expr::StrLit(_) => self.make_builtin(ConcreteType::Str),
            Expr::StrInterp(_) => self.make_builtin(ConcreteType::Str),
            Expr::NullLit => {
                let tv = self.arena.fresh_type_var();
                self.arena.make(ConcreteType::Nullable(tv))
            }
            Expr::VoidLit => self.make_builtin(ConcreteType::Void),

            // ── 标识符 ──
            Expr::Ident(name) => {
                // sema v2: 优先查询 flow narrowing 结果（path-sensitive 类型精化）
                if let Some(narrowed_ty) = self.flow_ctx.lookup_narrowed(name) {
                    return narrowed_ty;
                }
                if let Some(scheme) = self.env.lookup(env, name) {
                    return self.freshen_type(scheme);
                }
                // import 别名查找
                if let Some(target) = self.sema_result.get_import_alias(name) {
                    match target {
                        AliasTarget::Symbol(mangled) => {
                            if let Some(scheme) = self.env.lookup(env, mangled.as_ref()) {
                                return self.freshen_type(scheme);
                            }
                        }
                        _ => {}
                    }
                }
                self.add_error(&format!("undefined variable '{}'", name));
                self.arena.fresh_type_var()
            }

            // ── 赋值 ──
            Expr::Assign { target, value } => {
                let val_ty = self.infer_expr(*value, ast, env, None);
                let target_ty = self.infer_expr(*target, ast, env, None);
                let _ = self.arena.unify(target_ty, val_ty);
                self.make_builtin(ConcreteType::Void)
            }
            Expr::CompoundAssign { target, value, .. } => {
                let val_ty = self.infer_expr(*value, ast, env, None);
                let target_ty = self.infer_expr(*target, ast, env, None);
                let _ = self.arena.unify(target_ty, val_ty);
                target_ty
            }

            // ── 二元运算 ──
            Expr::Binary { op, lhs, rhs } => {
                let left_ty = self.infer_expr(*lhs, ast, env, None);
                let right_ty = self.infer_expr(*rhs, ast, env, None);
                let left_is_lit = Self::expr_is_literal(ast, *lhs);
                let right_is_lit = Self::expr_is_literal(ast, *rhs);
                match op {
                    BinaryOp::Add | BinaryOp::Sub | BinaryOp::Mul | BinaryOp::Div | BinaryOp::Mod => {
                        let rl = self.arena.resolve(left_ty);
                        let rr = self.arena.resolve(right_ty);
                        if self.arena.get(rl).is_numeric() && self.arena.get(rr).is_numeric() {
                            // v2 收敛：用 peer_type_binary 替代 literal_promotion
                            // 字面量提升规则内化到 peer_type_binary 中
                            return peer_type_binary(
                                self.arena,
                                left_ty,
                                right_ty,
                                left_is_lit,
                                right_is_lit,
                            );
                        }
                        let _ = self.arena.unify(left_ty, right_ty);
                        left_ty
                    }
                    BinaryOp::Eq | BinaryOp::NotEq | BinaryOp::RefEq | BinaryOp::RefNeq
                    | BinaryOp::Lt | BinaryOp::Gt | BinaryOp::LtEq | BinaryOp::GtEq => {
                        let rl = self.arena.resolve(left_ty);
                        let rr = self.arena.resolve(right_ty);
                        if self.arena.get(rl).is_numeric() && self.arena.get(rr).is_numeric() {
                            // v2 收敛：比较运算用 peer_type_binary 统一操作数类型
                            let _ = peer_type_binary(
                                self.arena,
                                left_ty,
                                right_ty,
                                left_is_lit,
                                right_is_lit,
                            );
                        } else {
                            let _ = self.arena.unify(left_ty, right_ty);
                        }
                        self.make_builtin(ConcreteType::Bool)
                    }
                    BinaryOp::And | BinaryOp::Or => {
                        let bool_ty = self.make_builtin(ConcreteType::Bool);
                        let _ = self.arena.unify(left_ty, bool_ty);
                        let _ = self.arena.unify(right_ty, bool_ty);
                        bool_ty
                    }
                    BinaryOp::BitAnd | BinaryOp::BitOr | BinaryOp::BitXor
                    | BinaryOp::Shl | BinaryOp::Shr => {
                        let _ = self.arena.unify(left_ty, right_ty);
                        left_ty
                    }
                    BinaryOp::ConcatList => {
                        let elem_ty = self.arena.fresh_type_var();
                        let arr_ty = self.arena.make(ConcreteType::Array {
                            element_type: elem_ty,
                            size: None,
                        });
                        let _ = self.arena.unify(left_ty, arr_ty);
                        let right_elem = self.arena.fresh_type_var();
                        let arr_ty = self.arena.make(ConcreteType::Array {
                            element_type: right_elem,
                            size: None,
                        });
                        let _ = self.arena.unify(right_ty, arr_ty);
                        let res_elem = self.arena.fresh_type_var();
                        self.arena.make(ConcreteType::Array {
                            element_type: res_elem,
                            size: None,
                        })
                    }
                    BinaryOp::Range | BinaryOp::RangeInclusive => {
                        let usize_ty = self.make_builtin(ConcreteType::Usize);
                        let _ = self.try_widen_unify(usize_ty, left_ty);
                        let usize_ty = self.make_builtin(ConcreteType::Usize);
                        let _ = self.try_widen_unify(usize_ty, right_ty);
                        self.make_builtin(ConcreteType::Usize)
                    }
                    BinaryOp::Elvis => {
                        let rl = self.arena.resolve(left_ty);
                        if let ConcreteType::Nullable(inner) = self.arena.get(rl).clone() {
                            return inner;
                        }
                        left_ty
                    }
                }
            }

            // ── 一元运算 ──
            Expr::Unary { operand, .. } => {
                let _ = self.infer_expr(*operand, ast, env, None);
                // ! / ~ / - 均返回操作数类型
                self.infer_expr(*operand, ast, env, None)
            }

            // ── 引用/解引用 ──
            Expr::RefOf(operand) => {
                let inner_ty = self.infer_expr(*operand, ast, env, None);
                self.arena.make(ConcreteType::Ref {
                    inner: inner_ty,
                    is_raw: false,
                })
            }
            Expr::Deref(operand) => {
                let operand_ty = self.infer_expr(*operand, ast, env, None);
                let resolved = self.arena.resolve(operand_ty);
                match self.arena.get(resolved).clone() {
                    ConcreteType::Ref { inner, .. } => inner,
                    _ => operand_ty, // 非引用解引用：返回原类型
                }
            }

            // ── 函数调用 ──
            Expr::Call { callee, args, .. } => {
                let callee_ty = self.infer_expr(*callee, ast, env, None);
                let ret_ty = self.arena.fresh_type_var();
                let resolved_callee = self.arena.resolve(callee_ty);
                let callee_ct = self.arena.get(resolved_callee).clone();

                if let ConcreteType::Fn { params, return_type } = &callee_ct {
                    if params.len() == args.len() {
                        let mut all_ok = true;
                        for (&param_ty, &arg) in params.iter().zip(args.iter()) {
                            let arg_ty = self.infer_expr(arg, ast, env, Some(param_ty));
                            if self.try_widen_unify(param_ty, arg_ty).is_err() {
                                all_ok = false;
                            }
                        }
                        if all_ok {
                            return *return_type;
                        }
                    }
                }
                // 兜底：推断所有参数，unify callee 与 (args -> ret)
                let arg_types: Vec<TypeHandle> = args
                    .iter()
                    .map(|&a| self.infer_expr(a, ast, env, None))
                    .collect();
                let expected_fn = self.arena.make(ConcreteType::Fn {
                    params: arg_types.into_boxed_slice(),
                    return_type: ret_ty,
                });
                let _ = self.arena.unify(callee_ty, expected_fn);
                ret_ty
            }

            // ── 方法调用 ──
            Expr::MethodCall { recv, method, args, .. }
            | Expr::SafeMethodCall { recv, method, args, .. } => {
                let recv_ty = self.infer_expr(*recv, ast, env, None);
                let ret_ty = self.arena.fresh_type_var();
                // 查找方法：先查 type_def 的方法，再查 trait impl
                let method_fn_ty = self.lookup_method_type(recv_ty, method);
                if let Some(fn_ty) = method_fn_ty {
                    let resolved = self.arena.resolve(fn_ty);
                    if let ConcreteType::Fn { params, return_type } =
                        self.arena.get(resolved).clone()
                    {
                        // 第一个参数是 self，跳过
                        let n = params.len().min(args.len() + 1);
                        for i in 1..n {
                            let _ = self.infer_expr(args[i - 1], ast, env, Some(params[i]));
                        }
                        return return_type;
                    }
                }
                // 兜底：推断参数，返回 fresh var
                for &a in args.iter() {
                    let _ = self.infer_expr(a, ast, env, None);
                }
                ret_ty
            }

            // ── 字段访问 ──
            Expr::FieldAccess { recv, field } => {
                let recv_ty = self.infer_expr(*recv, ast, env, None);
                self.lookup_field_type(recv_ty, field)
            }
            Expr::SafeAccess { recv, field } => {
                let recv_ty = self.infer_expr(*recv, ast, env, None);
                let inner = self.unwrap_ref(recv_ty);
                self.lookup_field_type(inner, field)
            }

            // ── 索引/切片 ──
            Expr::Index { recv, index } => {
                let recv_ty = self.infer_expr(*recv, ast, env, None);
                let _ = self.infer_expr(*index, ast, env, None);
                let resolved = self.arena.resolve(recv_ty);
                match self.arena.get(resolved).clone() {
                    ConcreteType::Array { element_type, .. } => element_type,
                    _ => self.arena.fresh_type_var(),
                }
            }
            Expr::Slice { recv, start, end, .. } => {
                let recv_ty = self.infer_expr(*recv, ast, env, None);
                let _ = self.infer_expr(*start, ast, env, None);
                let _ = self.infer_expr(*end, ast, env, None);
                recv_ty // 切片返回同类型
            }

            // ── 传播 ──
            Expr::Propagate(operand) => {
                let inner_ty = self.infer_expr(*operand, ast, env, None);
                let resolved = self.arena.resolve(inner_ty);
                self.check_propagate(resolved, inner_ty)
            }
            Expr::NonNullAssert(operand) => {
                let operand_ty = self.infer_expr(*operand, ast, env, None);
                let resolved = self.arena.resolve(operand_ty);
                match self.arena.get(resolved).clone() {
                    ConcreteType::Nullable(inner) => inner,
                    _ => operand_ty,
                }
            }
            Expr::Elvis { lhs, rhs } => {
                let left_ty = self.infer_expr(*lhs, ast, env, None);
                let right_ty = self.infer_expr(*rhs, ast, env, None);
                let rl = self.arena.resolve(left_ty);
                if let ConcreteType::Nullable(inner) = self.arena.get(rl).clone() {
                    let _ = self.try_widen_unify(inner, right_ty);
                    inner
                } else {
                    left_ty
                }
            }

            // ── 数组字面量 ──
            Expr::ArrayLit { elements, .. } => {
                if elements.is_empty() {
                    let elem_ty = self.arena.fresh_type_var();
                    return self.arena.make(ConcreteType::Array {
                        element_type: elem_ty,
                        size: None,
                    });
                }
                let first_ty = self.infer_expr(elements[0], ast, env, None);
                for &e in elements.iter().skip(1) {
                    let elem_ty = self.infer_expr(e, ast, env, None);
                    let _ = self.try_widen_unify(first_ty, elem_ty);
                }
                self.arena.make(ConcreteType::Array {
                    element_type: first_ty,
                    size: Some(elements.len() as u64),
                })
            }

            // ── 记录字面量 ──
            Expr::RecordLit(fields) => {
                let field_types: Vec<FieldType> = fields
                    .iter()
                    .map(|f| FieldType {
                        name: Some(f.name.into()),
                        ty: self.infer_expr(f.value, ast, env, None),
                    })
                    .collect();
                self.arena.make(ConcreteType::Record {
                    fields: field_types.into_boxed_slice(),
                    name: None,
                })
            }
            Expr::RecordExtend { base, updates } => {
                let base_ty = self.infer_expr(*base, ast, env, None);
                let resolved = self.arena.resolve(base_ty);
                match self.arena.get(resolved).clone() {
                    ConcreteType::Record { fields: base_fields, name } => {
                        let mut all_fields: Vec<FieldType> = base_fields.iter().cloned().collect();
                        for update in updates.iter() {
                            let update_ty = self.infer_expr(update.value, ast, env, None);
                            let mut found = false;
                            for f in all_fields.iter_mut() {
                                if f.name.as_deref() == Some(update.name) {
                                    f.ty = update_ty;
                                    found = true;
                                    break;
                                }
                            }
                            if !found {
                                all_fields.push(FieldType {
                                    name: Some(update.name.into()),
                                    ty: update_ty,
                                });
                            }
                        }
                        self.arena.make(ConcreteType::Record {
                            fields: all_fields.into_boxed_slice(),
                            name,
                        })
                    }
                    _ => {
                        self.add_error("record extend requires record type");
                        self.arena.fresh_type_var()
                    }
                }
            }

            // ── Lambda ──
            Expr::Lambda { params, body, is_async, return_type } => {
                let child_env = self.env.child(env);
                let param_types: Vec<TypeHandle> = params
                    .iter()
                    .map(|p| {
                        let param_ty = match p.type_annotation {
                            Some(ta) => self.type_from_ast(ta, ast),
                            None => self.arena.fresh_type_var(),
                        };
                        self.env.define(child_env, p.name, param_ty);
                        param_ty
                    })
                    .collect();
                let body_ty = match body {
                    LambdaBody::Block(b) => self.infer_expr(*b, ast, child_env, None),
                    LambdaBody::Expression(e) => self.infer_expr(*e, ast, child_env, None),
                };
                let effective_body_ty = if let Some(rt) = return_type {
                    let annot_ty = self.type_from_ast(*rt, ast);
                    let _ = self.try_widen_unify(annot_ty, body_ty);
                    annot_ty
                } else {
                    body_ty
                };
                let ret_ty = if *is_async {
                    self.arena.make(ConcreteType::Generic {
                        name: "Async".into(),
                        args: vec![effective_body_ty].into_boxed_slice(),
                    })
                } else {
                    effective_body_ty
                };
                self.arena.make(ConcreteType::Fn {
                    params: param_types.into_boxed_slice(),
                    return_type: ret_ty,
                })
            }

            // ── if 表达式 ──
            Expr::If { cond, then_branch, else_branch } => {
                let cond_ty = self.infer_expr(*cond, ast, env, None);
                let bool_ty = self.make_builtin(ConcreteType::Bool);
                let _ = self.arena.unify(cond_ty, bool_ty);

                // sema v2: 提取 flow facts（nullable narrowing）
                let (then_facts, else_facts) = analyze_null_check_facts(
                    self.arena,
                    ast,
                    *cond,
                    env,
                    &self.env,
                );

                let then_env = self.env.child(env);
                // 进入 then scope，应用 then facts
                self.flow_ctx.push_scope();
                for fact in &then_facts {
                    self.flow_ctx.add_fact(fact.clone());
                }
                let then_ty = self.infer_expr(*then_branch, ast, then_env, expected);
                self.flow_ctx.pop_scope();

                if let Some(else_br) = else_branch {
                    let else_env = self.env.child(env);
                    // 进入 else scope，应用 else facts
                    self.flow_ctx.push_scope();
                    for fact in &else_facts {
                        self.flow_ctx.add_fact(fact.clone());
                    }
                    let else_ty = self.infer_expr(*else_br, ast, else_env, expected);
                    self.flow_ctx.pop_scope();

                    // v2 收敛：只用 peer_type 统一分支类型（消除 try_widen_unify 双轨制）
                    // peer_type 已内化 Never/Void 过滤、数值宽化、nullable/throw 传播
                    peer_type(self.arena, &[then_ty, else_ty])
                } else {
                    then_ty
                }
            }

            // ── 块表达式 ──
            Expr::Block { stmts, trailing } => {
                let child_env = self.env.child(env);
                let mut diverges = false;
                for &stmt in stmts.iter() {
                    let _ = self.infer_stmt(stmt, ast, child_env);
                    match &ast.stmt(stmt).node {
                        Stmt::Return { .. } | Stmt::Throw { .. } => diverges = true,
                        _ => {}
                    }
                }
                if let Some(te) = trailing {
                    self.infer_expr(*te, ast, child_env, None)
                } else if diverges {
                    self.make_builtin(ConcreteType::Never)
                } else {
                    self.make_builtin(ConcreteType::Void)
                }
            }

            // ── match 表达式 ──
            Expr::Match { scrutinee, arms } => {
                let scrutinee_ty = self.infer_expr(*scrutinee, ast, env, None);
                let resolved_scrutinee = self.arena.resolve(scrutinee_ty);

                // sema v2: 提取 scrutinee 的路径（用于 ConstructorMatch narrowing）
                let scrutinee_path = expr_path(ast, *scrutinee);

                let mut arm_tys: Vec<TypeHandle> = Vec::new();
                for arm in arms.iter() {
                    let child_env = self.env.child(env);

                    // sema v2: 进入 match arm scope，应用 ConstructorMatch narrowing
                    self.flow_ctx.push_scope();
                    if let Some(ref path) = scrutinee_path {
                        // 检查是否为构造器模式，若是则添加 ConstructorMatch fact
                        if let Some((ctor_name, bound_vars)) =
                            extract_constructor_pattern(&ast.pattern(arm.pattern).node)
                        {
                            // 构造器匹配：scrutinee 被窄化为该构造器类型
                            let narrowed_ty = self.arena.make(ConcreteType::Adt {
                                name: ctor_name.into(),
                                type_args: Box::new([]),
                            });
                            self.flow_ctx.add_fact(FlowFact {
                                path: path.clone().into(),
                                narrowed_ty,
                                kind: NarrowKind::ConstructorMatch {
                                    ctor_name: ctor_name.into(),
                                    bound_vars: bound_vars.into(),
                                },
                            });
                        }
                    }

                    self.infer_pattern(arm.pattern, ast, resolved_scrutinee, child_env);
                    if let Some(guard) = arm.guard {
                        let _ = self.infer_expr(guard, ast, child_env, None);
                    }
                    let body_ty = self.infer_expr(arm.body, ast, child_env, None);
                    self.flow_ctx.pop_scope();

                    arm_tys.push(body_ty);
                }

                // v2 收敛：只用 peer_type 统一所有 arm 类型（消除逐个 widen 双轨制）
                // peer_type 处理单 arm（直接返回）、多 arm（join）、全 Never/Void（返回 Never/Void）
                if arm_tys.is_empty() {
                    self.make_builtin(ConcreteType::Void)
                } else {
                    peer_type(self.arena, &arm_tys)
                }
            }

            // ── 类型转换 ──
            Expr::TypeCast { target, expr, .. } => {
                let _ = self.infer_expr(*expr, ast, env, None);
                self.type_from_ast(*target, ast)
            }
            Expr::CastBuilder { target, expr, mode } => {
                let _ = self.infer_expr(*expr, ast, env, None);
                let target_ty = self.type_from_ast(*target, ast);
                match mode {
                    crate::Ast::CastMode::TryTo => {
                        // try_to 返回 Throw<T, CastError>
                        let err_ty = self.arena.make(ConcreteType::Adt {
                            name: "CastError".into(),
                            type_args: Box::new([]),
                        });
                        self.arena.make(ConcreteType::Throw {
                            value_type: target_ty,
                            error_type: err_ty,
                        })
                    }
                    crate::Ast::CastMode::To => target_ty,
                }
            }

            // ── Atomic / Lazy ──
            Expr::Atomic(operand) => {
                let inner_ty = self.infer_expr(*operand, ast, env, None);
                self.arena.make(ConcreteType::Generic {
                    name: "Atomic".into(),
                    args: vec![inner_ty].into_boxed_slice(),
                })
            }
            Expr::Lazy(operand) => {
                let inner_ty = self.infer_expr(*operand, ast, env, None);
                self.arena.make(ConcreteType::Generic {
                    name: "Lazy".into(),
                    args: vec![inner_ty].into_boxed_slice(),
                })
            }

            // ── select / inline_trait（简化处理）──
            Expr::Select(_) | Expr::InlineTrait(_) => {
                // TODO: select/inline_trait 需要协程/trait 值的完整支持
                self.arena.fresh_type_var()
            }
        }
    }

    /// 整数后缀 → 对应整型 TypeHandle。
    fn int_suffix_to_type(&mut self, suffix: &str) -> Option<TypeHandle> {
        let ct = match suffix {
            "i8" => ConcreteType::I8,
            "i16" => ConcreteType::I16,
            "i32" => ConcreteType::I32,
            "i64" => ConcreteType::I64,
            "i128" => ConcreteType::I128,
            "u8" => ConcreteType::U8,
            "u16" => ConcreteType::U16,
            "u32" => ConcreteType::U32,
            "u64" => ConcreteType::U64,
            "u128" => ConcreteType::U128,
            "isize" => ConcreteType::Isize,
            "usize" => ConcreteType::Usize,
            _ => return None,
        };
        Some(self.arena.make(ct))
    }

    /// 浮点后缀 → 对应浮点 TypeHandle。
    fn float_suffix_to_type(&mut self, suffix: &str) -> Option<TypeHandle> {
        let ct = match suffix {
            "f16" => ConcreteType::F16,
            "f32" => ConcreteType::F32,
            "f64" => ConcreteType::F64,
            "f128" => ConcreteType::F128,
            _ => return None,
        };
        Some(self.arena.make(ct))
    }

    /// 查找对象类型的方法签名（返回函数类型，第一个参数为 self）。
    fn lookup_method_type(&mut self, recv_ty: TypeHandle, method: &str) -> Option<TypeHandle> {
        let resolved = self.arena.resolve(recv_ty);
        let type_name = self.arena.type_name(resolved).map(|s| s.to_string());

        // v2 收敛：路径 1 — 查 witness_table（trait 方法分派，type_id 索引）
        if let Some(ref name) = type_name {
            let type_id = self
                .sema_result
                .type_def_index
                .get(name.as_str())
                .map(|&idx| 22 + idx as u16);
            if let Some(tid) = type_id {
                for entry in self.witness_table.entries().iter() {
                    if entry.type_id == tid && entry.method_slots.contains_key(method) {
                        return Some(self.arena.fresh_type_var());
                    }
                }
            }
        }

        // v2 收敛：路径 2 — 查 func_sigs（类型自有方法，func_sigs 是统一存储非双轨制）
        if let Some(ref name) = type_name {
            let mangled = format!("{}.{}", name, method);
            if self.sema_result.get_func_sig(&mangled).is_some() {
                return Some(self.arena.fresh_type_var());
            }
        }

        None
    }

    /// 查找对象类型的字段类型。
    fn lookup_field_type(&mut self, recv_ty: TypeHandle, field: &str) -> TypeHandle {
        let resolved = self.arena.resolve(recv_ty);
        let type_name = self.arena.type_name(resolved).map(|s| s.to_string());
        if let Some(name) = type_name {
            if let Some(field_id) = self.sema_result.lookup_field_id(&name, field) {
                if let Some(ctor) = self.sema_result.get_ctor_def(&name) {
                    let idx = match self.sema_result.get_type_def(&name) {
                        Some(def) if def.kind == TypeDefKind::Record => field_id as usize,
                        _ => (field_id as usize).saturating_sub(1),
                    };
                    if let Some(_field_td) = ctor.field_type_descs.get(idx) {
                        // 从 field_type_descs 无法直接得到 TypeHandle，
                        // 返回 fresh var（完整实现需从 field_type_names 构造）
                        return self.arena.fresh_type_var();
                    }
                }
            }
        }
        // record 结构字段
        let ct = self.arena.get(resolved).clone();
        if let ConcreteType::Record { fields, .. } = &ct {
            for f in fields.iter() {
                if f.name.as_deref() == Some(field) {
                    return f.ty;
                }
            }
        }
        self.arena.fresh_type_var()
    }

    // ── infer_stmt ──

    /// 推断语句类型。返回 `Some(ty)` 表示语句产生值（表达式语句）。
    pub fn infer_stmt(
        &mut self,
        stmt: StmtId,
        ast: &AstArena<'_>,
        env: EnvId,
    ) -> Option<TypeHandle> {
        let node = &ast.stmt(stmt).node;
        match node {
            Stmt::ValDecl { name, type_annotation, value, .. } | Stmt::VarDecl { name, type_annotation, value, .. } => {
                // kind_check 类型注解
                if let Some(ta) = type_annotation {
                    let mut errors = Vec::new();
                    check_type_node(self.sema_result, ast, *ta, &[], &mut errors);
                    for e in errors {
                        self.sema_result.add_error(e);
                    }
                }
                let expected_ty = type_annotation.map(|ta| self.type_from_ast(ta, ast));
                let val_ty = self.infer_expr(*value, ast, env, expected_ty);
                let bind_ty = if let Some(ta) = type_annotation {
                    let annot_ty = self.type_from_ast(*ta, ast);
                    let _ = self.try_widen_unify(annot_ty, val_ty);
                    annot_ty
                } else {
                    val_ty
                };
                self.env.define(env, name, bind_ty);
                None
            }
            Stmt::Assignment { target, value } => {
                let val_ty = self.infer_expr(*value, ast, env, None);
                let target_ty = self.infer_expr(*target, ast, env, None);
                let _ = self.arena.unify(target_ty, val_ty);
                None
            }
            Stmt::FieldAssignment { object, value, .. } => {
                let _ = self.infer_expr(*object, ast, env, None);
                let _ = self.infer_expr(*value, ast, env, None);
                None
            }
            Stmt::CompoundAssignment { target, value, .. } => {
                let _ = self.infer_expr(*target, ast, env, None);
                let _ = self.infer_expr(*value, ast, env, None);
                None
            }
            Stmt::Expression { expr } => {
                let ty = self.infer_expr(*expr, ast, env, None);
                Some(ty)
            }
            Stmt::Return { value } => {
                if let Some(v) = value {
                    let val_ty = self.infer_expr(*v, ast, env, None);
                    if let Some(fn_ret) = self.expected_return {
                        let _ = self.unify_return_type(fn_ret, val_ty);
                    }
                    Some(val_ty)
                } else {
                    Some(self.make_builtin(ConcreteType::Void))
                }
            }
            Stmt::Defer { expr } => {
                let _ = self.infer_expr(*expr, ast, env, None);
                None
            }
            Stmt::Throw { expr } => {
                let thrown_ty = self.infer_expr(*expr, ast, env, None);
                self.check_throw_stmt(thrown_ty, 0, 0);
                None
            }
            Stmt::Break | Stmt::Continue => None,
            Stmt::For { name, iterable, body } => {
                let iterable_ty = self.infer_expr(*iterable, ast, env, None);
                let child_env = self.env.child(env);
                let item_ty = {
                    let resolved = self.arena.resolve(iterable_ty);
                    match self.arena.get(resolved).clone() {
                        ConcreteType::Array { element_type, .. } => element_type,
                        ConcreteType::Str => self.make_builtin(ConcreteType::Str),
                        _ => self.arena.fresh_type_var(),
                    }
                };
                self.env.define(child_env, name, item_ty);
                let _ = self.infer_expr(*body, ast, child_env, None);
                None
            }
            Stmt::While { condition, body } => {
                let cond_ty = self.infer_expr(*condition, ast, env, None);
                let bool_ty = self.make_builtin(ConcreteType::Bool);
                let _ = self.arena.unify(cond_ty, bool_ty);
                let _ = self.infer_expr(*body, ast, env, None);
                None
            }
            Stmt::Loop { body } => {
                let _ = self.infer_expr(*body, ast, env, None);
                None
            }
        }
    }

    // ── infer_pattern ──

    /// 推断模式类型，将绑定变量加入环境。
    pub fn infer_pattern(
        &mut self,
        pat: PatternId,
        ast: &AstArena<'_>,
        expected_ty: TypeHandle,
        env: EnvId,
    ) {
        let node = &ast.pattern(pat).node;
        match node {
            Pattern::Wildcard => {}
            Pattern::Literal(lit) => {
                let lit_ty = match lit {
                    PatternLiteral::Int(_) => Some(self.make_builtin(ConcreteType::I32)),
                    PatternLiteral::Float(_) => Some(self.make_builtin(ConcreteType::F64)),
                    PatternLiteral::Bool(_) => Some(self.make_builtin(ConcreteType::Bool)),
                    PatternLiteral::Char(_) => Some(self.make_builtin(ConcreteType::Char)),
                    PatternLiteral::String(_) => Some(self.make_builtin(ConcreteType::Str)),
                    PatternLiteral::Null => None,
                };
                if let Some(lt) = lit_ty {
                    let resolved = self.arena.resolve(expected_ty);
                    let ct = self.arena.get(resolved).clone();
                    let is_int_expected = ct.is_int();
                    let is_int_lit = matches!(lit, PatternLiteral::Int(_));
                    if !(is_int_lit && is_int_expected) {
                        let _ = self.arena.unify(lt, expected_ty);
                    }
                }
            }
            Pattern::Variable { name } => {
                // 大写开头 → 零参构造器
                if name.chars().next().map(|c| c.is_uppercase()).unwrap_or(false) {
                    let sub_pats: Vec<PatternRef> = Vec::new();
                    self.refine_constructor_pattern(name, &sub_pats, expected_ty, ast);
                } else {
                    self.env.define(env, name, expected_ty);
                }
            }
            Pattern::Constructor { name, patterns } => {
                if !self.refine_constructor_pattern(name, patterns, expected_ty, ast) {
                    // 常规构造器：从 sema_result 查找字段类型
                    let field_type_nodes: Box<[Option<AstTypeRef>]> = self
                        .sema_result
                        .get_ctor_def(name)
                        .map(|c| c.field_type_nodes.clone())
                        .unwrap_or_else(|| Box::new([]));
                    for (i, &sub_pat) in patterns.iter().enumerate() {
                        let sub_ty = if i < field_type_nodes.len() {
                            match field_type_nodes[i] {
                                Some(ftn) => self.type_from_ast(ftn, ast),
                                None => self.arena.fresh_type_var(),
                            }
                        } else {
                            self.arena.fresh_type_var()
                        };
                        self.infer_pattern(sub_pat, ast, sub_ty, env);
                    }
                }
            }
            Pattern::Record { fields } => {
                for field in fields.iter() {
                    let field_ty = self.arena.fresh_type_var();
                    self.infer_pattern(field.pattern, ast, field_ty, env);
                }
            }
            Pattern::OrPattern { left, right } => {
                self.infer_pattern(*left, ast, expected_ty, env);
                self.infer_pattern(*right, ast, expected_ty, env);
            }
            Pattern::Guard { pattern, condition } => {
                self.infer_pattern(*pattern, ast, expected_ty, env);
                let cond_ty = self.infer_expr(*condition, ast, env, None);
                let bool_ty = self.make_builtin(ConcreteType::Bool);
                let _ = self.arena.unify(cond_ty, bool_ty);
            }
        }
    }

    // ── register_builtins ──

    /// 注册内置函数到环境。
    pub fn register_builtins(&mut self, env: EnvId) {
        // Panic: (str) -> void
        let str_ty = self.make_builtin(ConcreteType::Str);
        let void_ty = self.make_builtin(ConcreteType::Void);
        let panic_fn = self.arena.make(ConcreteType::Fn {
            params: vec![str_ty].into_boxed_slice(),
            return_type: void_ty,
        });
        self.env.define(env, "Panic", panic_fn);

        // str: ∀T. (T) -> str
        let param = self.arena.fresh_type_var();
        let str_ret = self.make_builtin(ConcreteType::Str);
        let str_fn = self.arena.make(ConcreteType::Fn {
            params: vec![param].into_boxed_slice(),
            return_type: str_ret,
        });
        self.env.define(env, "str", str_fn);

        // type: ∀T. (T) -> str
        let param = self.arena.fresh_type_var();
        let type_str_ret = self.make_builtin(ConcreteType::Str);
        let type_fn = self.arena.make(ConcreteType::Fn {
            params: vec![param].into_boxed_slice(),
            return_type: type_str_ret,
        });
        self.env.define(env, "type", type_fn);

        // Ok: ∀T,E. (T) -> Throw<T, E>
        let val_ty = self.arena.fresh_type_var();
        let err_ty = self.arena.fresh_type_var();
        let throw_ty = self.arena.make(ConcreteType::Throw {
            value_type: val_ty,
            error_type: err_ty,
        });
        let ok_fn = self.arena.make(ConcreteType::Fn {
            params: vec![val_ty].into_boxed_slice(),
            return_type: throw_ty,
        });
        self.env.define(env, "Ok", ok_fn);

        // 数值类型构造器：i8/i16/.../f64 等作为 ∀T. (T) -> Self
        for &(name, ref ct) in NUMERIC_BUILTIN_NAMES {
            let param = self.arena.fresh_type_var();
            let ret_ty = self.make_builtin(ct.clone());
            let fn_ty = self.arena.make(ConcreteType::Fn {
                params: vec![param].into_boxed_slice(),
                return_type: ret_ty,
            });
            self.env.define(env, name, fn_ty);
        }
    }

    // ── check_module ──

    /// 模块检查入口：编排 populate → 预声明 → 推断 → kind_check → monomorph。
    ///
    /// 返回 true 表示无错误。步骤：
    /// 1. populate_module 填充 SemaResult 定义表
    /// 2. 创建根环境，注册内置函数
    /// 3. 预声明函数和类型构造器
    /// 4. 推导表达式声明和函数体
    /// 5. 运行 kind_check
    /// 6. 收集单态化实例
    pub fn check_module(&mut self, module: &Module<'_>) -> bool {
        // 1. 填充定义表（若尚未填充）
        populate_module(self.sema_result, module);

        // 2. 重置状态 + 创建根环境
        self.expected_return = None;
        self.type_binding_stack = TypeBindingStack::new();
        self.self_binding_stack = SelfBindingStack::new();
        self.solver.reset();
        self.flow_ctx.reset();
        // witness_table 不重置（跨模块累积，支持多模块 trait 实现）
        let root_env = self.env.root();
        self.register_builtins(root_env);

        // 3. 预声明函数和类型构造器
        self.predeclare_declarations(module, root_env);

        // 4. 填充 witness table（遍历 trait impl）
        self.populate_witness_table(module);

        // 5. 推导声明
        for decl in module.declarations.iter() {
            self.check_decl(&decl.node, &module.arena, root_env);
        }

        // 6. kind_check 所有类型注解
        self.run_kind_checks(module);

        // 7. 收集单态化实例
        collect_monomorph_instances(module, self.sema_result);

        // 8. 求解延迟约束（带 witness table 支持 trait bound 求解）
        // 分离借用 self 的不同字段：arena 可变借用，witness_table 只读借用
        let InferContext { arena, solver, witness_table, .. } = self;
        solver.solve_with_witness(arena, Some(witness_table));

        !self.sema_result.has_error
    }

    /// 填充 witness table：遍历模块中的 trait impl，注册到 witness table。
    ///
    /// 对于每个 `impl Trait for Type`，提取 trait_name 和 type_name，
    /// 查询 type_def 获取 type_id，将方法注册到 witness table。
    fn populate_witness_table(&mut self, module: &Module<'_>) {
        // 收集 trait impl 信息，避免在遍历时借用 module 同时 &mut self
        let mut impls: Vec<(String, String, Vec<(String, u32)>)> = Vec::new();

        for decl in module.declarations.iter() {
            if let Decl::TypeDecl { name, implemented_traits, methods, .. } = &decl.node {
                // 查询 type_id（用 type_def_index + 22 偏移）
                let type_id = self
                    .sema_result
                    .type_def_index
                    .get(*name)
                    .map(|&idx| 22 + idx as u16);

                if let Some(tid) = type_id {
                    // 为每个实现的 trait 注册 witness entry
                    for impl_trait in implemented_traits.iter() {
                        let trait_name = impl_trait.trait_name.to_string();
                        // 收集方法槽位：method_name → instance_id
                        // instance_id 暂用方法在 methods 中的索引（后续 monomorph 阶段更新）
                        let method_slots: Vec<(String, u32)> = methods
                            .iter()
                            .enumerate()
                            .map(|(i, m)| (m.name.to_string(), i as u32))
                            .collect();
                        impls.push((trait_name, name.to_string(), method_slots));
                        let _ = tid; // tid 在下面的循环中使用
                    }
                }
            }
        }

        // 注册到 witness table
        for (trait_name, type_name, method_slots_vec) in impls {
            // 重新查询 type_id（因为上面的借用已释放）
            let type_id = self
                .sema_result
                .type_def_index
                .get(type_name.as_str())
                .map(|&idx| 22 + idx as u16);
            if let Some(tid) = type_id {
                let mut slots = HashMap::new();
                for (method_name, instance_id) in method_slots_vec {
                    slots.insert(method_name.into_boxed_str(), instance_id);
                }
                self.witness_table
                    .register(&trait_name, tid, &type_name, slots);
            }
        }
    }

    /// 预声明模块中的函数和类型构造器到环境。
    fn predeclare_declarations(&mut self, module: &Module<'_>, env: EnvId) {
        for decl in module.declarations.iter() {
            match &decl.node {
                Decl::FunDecl { name, type_params, params, return_type, .. } => {
                    // 跳过类型参数（简化：非泛型函数直接预声明）
                    if type_params.is_empty() {
                        let param_types: Vec<TypeHandle> = params
                            .iter()
                            .map(|p| match p.type_annotation {
                                Some(ta) => self.type_from_ast(ta, &module.arena),
                                None => self.arena.fresh_type_var(),
                            })
                            .collect();
                        let ret_ty = match return_type {
                            Some(rt) => self.type_from_ast(*rt, &module.arena),
                            None => self.arena.fresh_type_var(),
                        };
                        let fn_ty = self.arena.make(ConcreteType::Fn {
                            params: param_types.into_boxed_slice(),
                            return_type: ret_ty,
                        });
                        self.env.define(env, name, fn_ty);
                    }
                }
                Decl::TypeDecl { name, type_params, def, .. } => {
                    // 预声明类型构造器
                    let self_ty = if type_params.is_empty() {
                        self.arena.make(ConcreteType::Adt {
                            name: (*name).into(),
                            type_args: Box::new([]),
                        })
                    } else {
                        // 泛型类型：用 rigid var 预声明
                        self.arena.fresh_rigid_var()
                    };
                    // 注册构造器到环境
                    if let crate::Ast::TypeDef::Adt { constructors } = def {
                        for ctor in constructors.iter() {
                            let ctor_fn_ty = self.build_ctor_fn_type(ctor, *name, &module.arena);
                            self.env.define(env, ctor.name, ctor_fn_ty);
                        }
                    }
                    let _ = self_ty;
                }
                _ => {}
            }
        }
    }

    /// 构造构造器的函数类型。
    fn build_ctor_fn_type(
        &mut self,
        ctor: &crate::Ast::ConstructorDef<'_>,
        type_name: &str,
        ast: &AstArena<'_>,
    ) -> TypeHandle {
        let param_types: Vec<TypeHandle> = ctor
            .fields
            .iter()
            .map(|f| self.type_from_ast(f.ty, ast))
            .collect();
        let ret_ty = match ctor.return_type {
            Some(rt) => self.type_from_ast(rt, ast),
            None => self.arena.make(ConcreteType::Adt {
                name: type_name.into(),
                type_args: Box::new([]),
            }),
        };
        self.arena.make(ConcreteType::Fn {
            params: param_types.into_boxed_slice(),
            return_type: ret_ty,
        })
    }

    /// 检查单个声明（推导函数体/表达式）。
    fn check_decl(&mut self, decl: &Decl<'_>, ast: &AstArena<'_>, env: EnvId) {
        match decl {
            Decl::FunDecl { name, type_params, params, return_type, body, extern_c_body, .. } => {
                // 为函数创建子环境
                let fn_env = self.env.child(env);
                // 类型参数绑定
                if !type_params.is_empty() {
                    self.push_type_bindings(
                        &type_params.iter().map(|tp| (tp.name,)).collect::<Vec<_>>(),
                    );
                }
                // @extern("c") 函数：注册签名但跳过函数体类型检查（body 为 C 代码，非 Glue 表达式）
                if extern_c_body.is_some() {
                    if !type_params.is_empty() {
                        self.pop_type_bindings();
                    }
                    let _ = name;
                    return;
                }
                // 参数绑定
                for param in params.iter() {
                    let param_ty = match param.type_annotation {
                        Some(ta) => self.type_from_ast(ta, ast),
                        None => self.arena.fresh_type_var(),
                    };
                    self.env.define(fn_env, param.name, param_ty);
                }
                // 设置返回类型
                let prev_return = self.expected_return;
                self.expected_return = return_type.map(|rt| self.type_from_ast(rt, ast));
                // 推导函数体
                let _ = self.infer_expr(*body, ast, fn_env, self.expected_return);
                // 恢复
                self.expected_return = prev_return;
                if !type_params.is_empty() {
                    self.pop_type_bindings();
                }
                let _ = name;
            }
            Decl::ExprDecl { expr, stmt, .. } => {
                if let Some(s) = stmt {
                    let _ = self.infer_stmt(*s, ast, env);
                } else {
                    let _ = self.infer_expr(*expr, ast, env, None);
                }
            }
            Decl::TypeDecl { name, type_params, methods, .. } => {
                // 类型方法检查
                let self_ty = if type_params.is_empty() {
                    self.arena.make(ConcreteType::Adt {
                        name: (*name).into(),
                        type_args: Box::new([]),
                    })
                } else {
                    self.arena.fresh_type_var()
                };
                self.push_self_type(self_ty);
                for method in methods.iter() {
                    if let Some(body) = method.body {
                        let method_env = self.env.child(env);
                        for param in method.params.iter() {
                            let param_ty = match param.type_annotation {
                                Some(ta) => self.type_from_ast(ta, ast),
                                None => self.arena.fresh_type_var(),
                            };
                            self.env.define(method_env, param.name, param_ty);
                        }
                        let prev_return = self.expected_return;
                        self.expected_return =
                            method.return_type.map(|rt| self.type_from_ast(rt, ast));
                        let _ = self.infer_expr(body, ast, method_env, self.expected_return);
                        self.expected_return = prev_return;
                    }
                }
                self.pop_self_type();
            }
            Decl::TraitDecl { name, methods, .. } => {
                let self_var = self.push_self_type_var();
                for method in methods.iter() {
                    if let Some(body) = method.body {
                        let method_env = self.env.child(env);
                        for param in method.params.iter() {
                            let param_ty = match param.type_annotation {
                                Some(ta) => self.type_from_ast(ta, ast),
                                None => self.arena.fresh_type_var(),
                            };
                            self.env.define(method_env, param.name, param_ty);
                        }
                        let prev_return = self.expected_return;
                        self.expected_return =
                            method.return_type.map(|rt| self.type_from_ast(rt, ast));
                        let _ = self.infer_expr(body, ast, method_env, self.expected_return);
                        self.expected_return = prev_return;
                    }
                }
                self.pop_self_type();
                let _ = (name, self_var);
            }
            _ => {}
        }
    }

    /// 对模块中所有类型注解运行 kind_check。
    fn run_kind_checks(&mut self, module: &Module<'_>) {
        let mut errors = Vec::new();
        for decl in module.declarations.iter() {
            match &decl.node {
                Decl::FunDecl { params, return_type, .. } => {
                    for p in params.iter() {
                        if let Some(ta) = p.type_annotation {
                            check_type_node(self.sema_result, &module.arena, ta, &[], &mut errors);
                        }
                    }
                    if let Some(rt) = return_type {
                        check_type_node(self.sema_result, &module.arena, *rt, &[], &mut errors);
                    }
                }
                Decl::TypeDecl { def, .. } => {
                    if let crate::Ast::TypeDef::Adt { constructors } = def {
                        for ctor in constructors.iter() {
                            for f in ctor.fields.iter() {
                                check_type_node(
                                    self.sema_result,
                                    &module.arena,
                                    f.ty,
                                    &[],
                                    &mut errors,
                                );
                            }
                            if let Some(rt) = ctor.return_type {
                                check_type_node(
                                    self.sema_result,
                                    &module.arena,
                                    rt,
                                    &[],
                                    &mut errors,
                                );
                            }
                        }
                    }
                }
                _ => {}
            }
        }
        for e in errors {
            self.sema_result.add_error(e);
        }
    }
}

/// 内置数值类型名与 ConcreteType 的映射表（用于 register_builtins）。
static NUMERIC_BUILTIN_NAMES: &[(&str, ConcreteType)] = &[
    ("i8", ConcreteType::I8),
    ("i16", ConcreteType::I16),
    ("i32", ConcreteType::I32),
    ("i64", ConcreteType::I64),
    ("i128", ConcreteType::I128),
    ("u8", ConcreteType::U8),
    ("u16", ConcreteType::U16),
    ("u32", ConcreteType::U32),
    ("u64", ConcreteType::U64),
    ("u128", ConcreteType::U128),
    ("isize", ConcreteType::Isize),
    ("usize", ConcreteType::Usize),
    ("f16", ConcreteType::F16),
    ("f32", ConcreteType::F32),
    ("f64", ConcreteType::F64),
    ("f128", ConcreteType::F128),
    ("bool", ConcreteType::Bool),
    ("char", ConcreteType::Char),
];

// =========================================================================
// sema v2: Constraint Solver — 统一约束求解引擎
//
// 设计理念（原创，非照搬 GHC/rustc/Swift）：
// - 所有类型关系（相等、子类型、trait bound、narrowing）统一为 Constraint
// - snapshot/rollback 支持尝试性推断（match 分支、重载选择）
// - 批量求解：函数体结束时统一求解，而非立即 unify
// - DOD：约束用 Vec，snapshot 用长度索引，subst 用 HashMap
//
// 与现有 TypeArena::unify 的关系：
// solver 调用 unify 实现 Equality 约束，但增加延迟和回滚能力。
// 现有的立即 unify 调用保持兼容，新代码可选用 solver。
// =========================================================================

/// 约束种类：统一所有类型关系为约束。
///
/// 设计要点：
/// - Equality：最常见，直接调用 TypeArena::unify
/// - Subtype：调用 is_subtype，失败时记录错误但不立即中断
/// - TraitBound：ty 是否实现某 trait（延迟到 witness table 查询）
/// - Narrow：path-sensitive 窄化（flow narrowing 使用）
#[derive(Debug, Clone)]
pub enum Constraint {
    /// 类型相等约束：`t1 = t2`
    Equality(TypeHandle, TypeHandle),
    /// 子类型约束：`sub <: sup`（方向性，非对称）
    Subtype(TypeHandle, TypeHandle),
    /// Trait bound 约束：`ty` 实现 trait `trait_name<type_args>`
    TraitBound {
        ty: TypeHandle,
        trait_name: Box<str>,
        type_args: Box<[TypeHandle]>,
    },
    /// 窄化约束：在某路径上 `original` 被窄化为 `narrowed`
    /// 用于 flow-sensitive narrowing（NonNull/IsCheck/ConstructorMatch）
    Narrow {
        path: Box<str>,
        original: TypeHandle,
        narrowed: TypeHandle,
    },
}

/// 约束求解错误：记录求解失败的原因，不中断推断（错误恢复）。
#[derive(Debug, Clone)]
pub struct ConstraintError {
    pub constraint: Constraint,
    pub reason: Box<str>,
    pub line: u32,
    pub column: u32,
}

/// Snapshot 标识：用于 rollback/commit 尝试性推断。
///
/// snapshot 时记录 pending 队列长度和 subst 快照；
/// rollback 时恢复到快照状态；commit 时丢弃快照保留求解结果。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SnapshotId(pub u32);

/// 约束求解器：收集约束、批量求解、支持 snapshot/rollback。
///
/// 设计：
/// - `pending`：待求解约束队列（FIFO）
/// - `snapshots`：snapshot 栈，记录 snapshot 时的 pending 长度和 subst 快照
/// - `subst`：已求解的 TypeVar → TypeHandle 映射（求解结果）
/// - `errors`：求解失败记录（不中断，错误恢复）
///
/// 使用模式：
/// 1. `let snap = solver.snapshot();`
/// 2. `solver.add(constraint);` ...（尝试性推断）
/// 3. 若成功 `solver.commit(snap);`，若失败 `solver.rollback(snap);`
pub struct ConstraintSolver {
    pending: Vec<Constraint>,
    snapshots: Vec<SnapshotState>,
    subst: HashMap<u32, TypeHandle>,
    errors: Vec<ConstraintError>,
}

/// Snapshot 内部状态：pending 长度 + subst 快照
#[derive(Debug, Clone)]
struct SnapshotState {
    pending_len: usize,
    subst_snapshot: HashMap<u32, TypeHandle>,
    errors_len: usize,
}

impl Default for ConstraintSolver {
    fn default() -> Self {
        Self::new()
    }
}

impl ConstraintSolver {
    pub fn new() -> Self {
        ConstraintSolver {
            pending: Vec::new(),
            snapshots: Vec::new(),
            subst: HashMap::new(),
            errors: Vec::new(),
        }
    }

    /// 添加约束到待求解队列。
    #[inline]
    pub fn add(&mut self, c: Constraint) {
        self.pending.push(c);
    }

    /// 添加相等约束的便捷方法。
    #[inline]
    pub fn add_equality(&mut self, t1: TypeHandle, t2: TypeHandle) {
        self.add(Constraint::Equality(t1, t2));
    }

    /// 添加子类型约束的便捷方法。
    #[inline]
    pub fn add_subtype(&mut self, sub: TypeHandle, sup: TypeHandle) {
        self.add(Constraint::Subtype(sub, sup));
    }

    /// 添加 trait bound 约束的便捷方法。
    #[inline]
    pub fn add_trait_bound(
        &mut self,
        ty: TypeHandle,
        trait_name: &str,
        type_args: &[TypeHandle],
    ) {
        self.add(Constraint::TraitBound {
            ty,
            trait_name: trait_name.into(),
            type_args: type_args.to_vec().into_boxed_slice(),
        });
    }

    /// 创建 snapshot：记录当前状态，用于后续 rollback。
    ///
    /// snapshot 后添加的约束和求解结果都可以通过 rollback 撤销。
    pub fn snapshot(&mut self) -> SnapshotId {
        let id = SnapshotId(self.snapshots.len() as u32);
        self.snapshots.push(SnapshotState {
            pending_len: self.pending.len(),
            subst_snapshot: self.subst.clone(),
            errors_len: self.errors.len(),
        });
        id
    }

    /// Rollback 到 snapshot 状态：撤销 snapshot 后的所有约束和求解结果。
    ///
    /// 用于尝试性推断失败时回退（如 match 分支类型不匹配）。
    pub fn rollback(&mut self, id: SnapshotId) {
        let idx = id.0 as usize;
        if idx >= self.snapshots.len() {
            return;
        }
        let state = self.snapshots[idx].clone();
        self.pending.truncate(state.pending_len);
        self.subst = state.subst_snapshot;
        self.errors.truncate(state.errors_len);
        // 丢弃该 snapshot 及之后的所有 snapshot
        self.snapshots.truncate(idx);
    }

    /// Commit snapshot：保留求解结果，丢弃 snapshot。
    ///
    /// 用于尝试性推断成功后确认结果。
    pub fn commit(&mut self, id: SnapshotId) {
        let idx = id.0 as usize;
        if idx >= self.snapshots.len() {
            return;
        }
        // 只丢弃该 snapshot，保留约束和求解结果
        self.snapshots.remove(idx);
        // 修正后续 snapshot 的 id（它们仍有效，只是 index 前移）
        // 但为简化，我们要求 commit 顺序与 snapshot 相反（栈式）
        // 非栈式 commit 会破坏 id 映射，此处简化为 truncate
        // 实际使用中推荐栈式 snapshot/commit
    }

    /// 批量求解所有 pending 约束。
    ///
    /// 求解策略：
    /// 1. Equality → TypeArena::unify，成功则更新 subst
    /// 2. Subtype → is_subtype 检查，失败记录错误
    /// 3. TraitBound → 通过 witness table 查询（需传入 witness_table）
    /// 4. Narrow → 更新 flow fact table（phase 3 实现）
    ///
    /// 求解后 pending 清空，结果存入 subst 和 errors。
    pub fn solve(&mut self, arena: &mut TypeArena) {
        self.solve_with_witness(arena, None)
    }

    /// 批量求解所有 pending 约束（带 witness table 支持）。
    ///
    /// TraitBound 约束通过 witness_table 查询求解。
    pub fn solve_with_witness(&mut self, arena: &mut TypeArena, witness: Option<&WitnessTable>) {
        let constraints = std::mem::take(&mut self.pending);
        for c in constraints {
            match c {
                Constraint::Equality(t1, t2) => {
                    let r1 = arena.resolve(t1);
                    let r2 = arena.resolve(t2);
                    match arena.unify(r1, r2) {
                        Ok(()) => {
                            self.record_binding(arena, r1, r2);
                        }
                        Err(_) => {
                            self.errors.push(ConstraintError {
                                constraint: Constraint::Equality(t1, t2),
                                reason: "type mismatch".into(),
                                line: 0,
                                column: 0,
                            });
                        }
                    }
                }
                Constraint::Subtype(sub, sup) => {
                    if !is_subtype(arena, sub, sup) {
                        self.errors.push(ConstraintError {
                            constraint: Constraint::Subtype(sub, sup),
                            reason: "not a subtype".into(),
                            line: 0,
                            column: 0,
                        });
                    }
                }
                Constraint::TraitBound { ty, trait_name, type_args } => {
                    // sema v2: 通过 witness table 求解 trait bound
                    if let Some(wt) = witness {
                        let resolved = arena.resolve(ty);
                        let ct = arena.get(resolved);
                        let type_id = match ct {
                            ConcreteType::Adt { .. } | ConcreteType::Generic { .. } => {
                                // 用户类型：type_id 由外部注册
                                // 此处无法访问 sema_result，跳过（由 check_module 统一处理）
                                None
                            }
                            _ => ct.builtin_type_id(),
                        };
                        if let Some(tid) = type_id {
                            if !wt.implements(&trait_name, tid) {
                                self.errors.push(ConstraintError {
                                    constraint: Constraint::TraitBound {
                                        ty,
                                        trait_name: trait_name.clone(),
                                        type_args: type_args.clone(),
                                    },
                                    reason: format!(
                                        "type does not implement trait '{}'",
                                        trait_name
                                    )
                                    .into(),
                                    line: 0,
                                    column: 0,
                                });
                            }
                        }
                        // type_id 为 None 时延迟到 check_module 处理
                    }
                    // 无 witness table 时：记录但不求解
                }
                Constraint::Narrow { .. } => {
                    // 延迟到 flow narrowing 实现（phase 3）
                    // 目前记录但不求解
                }
            }
        }
    }

    /// 记录 TypeVar 绑定到 subst。
    ///
    /// 若 t1 或 t2 解析后是 TypeVar，记录其绑定关系到 subst。
    fn record_binding(&mut self, arena: &TypeArena, t1: TypeHandle, t2: TypeHandle) {
        let r1 = arena.resolve(t1);
        let r2 = arena.resolve(t2);
        match (arena.get(r1), arena.get(r2)) {
            (ConcreteType::TypeVar(idx), other) if !matches!(other, ConcreteType::TypeVar(_)) => {
                self.subst.insert(*idx, r2);
            }
            (other, ConcreteType::TypeVar(idx)) if !matches!(other, ConcreteType::TypeVar(_)) => {
                self.subst.insert(*idx, r1);
            }
            _ => {}
        }
    }

    /// 查询 TypeVar 的求解结果。
    #[inline]
    pub fn lookup_subst(&self, var_idx: u32) -> Option<TypeHandle> {
        self.subst.get(&var_idx).copied()
    }

    /// 获取所有求解错误。
    #[inline]
    pub fn errors(&self) -> &[ConstraintError] {
        &self.errors
    }

    /// 是否有求解错误。
    #[inline]
    pub fn has_errors(&self) -> bool {
        !self.errors.is_empty()
    }

    /// 待求解约束数量。
    #[inline]
    pub fn pending_count(&self) -> usize {
        self.pending.len()
    }

    /// 清空所有状态（模块切换时调用）。
    pub fn reset(&mut self) {
        self.pending.clear();
        self.snapshots.clear();
        self.subst.clear();
        self.errors.clear();
    }
}

// =========================================================================
// sema v2: Peer Type Resolution — 统一类型统一入口
//
// 设计理念：
// 统一 literal_promotion + try_widen_unify + if 分支统一为单一 peer_type 入口。
// 给定 N 个类型，求最兼容的共同类型（join / least upper bound）。
//
// 规则（按优先级）：
// 1. 空列表 → Unknown
// 2. 单元素 → 该类型
// 3. 全相同 → 该类型
// 4. 含 Never → 过滤 Never 后递归（发散类型不贡献值）
// 5. 数值类型 → 取最宽（int→int 取宽、float 优先、int→float）
// 6. nullable 传播 → Nullable<peer(inner types)>
// 7. throw 传播 → Throw<peer(value types), peer(error types)>
// 8. ADT → 查 error_newtype 子类型关系
// 9. 无公共类型 → Unknown（记录错误）
// =========================================================================

/// 求多个类型的共同类型（join / least upper bound）。
///
/// 统一入口：替代分散的 literal_promotion / try_widen_unify / if 分支统一。
/// 返回能容纳所有输入类型的最兼容类型。
///
/// **规则**（按优先级）：
/// 1. 空列表 → `Unknown`
/// 2. 单元素 → 该类型
/// 3. 含 `Never` → 过滤后递归（发散路径不贡献值）
/// 4. 全相同（结构相等）→ 该类型
/// 5. 全为数值 → 取最宽（int→int 取位宽最大、float 优先于 int、int→float 宽化）
/// 6. 全为 nullable → `Nullable<peer(inners)>`
/// 7. 全为 throw → `Throw<peer(values), peer(errors)>`
/// 8. 含 nullable + 非 nullable → `Nullable<peer(all inners)>`
/// 9. ADT error 子类型 → 取超类型
/// 10. 无公共类型 → `Unknown`
pub fn peer_type(arena: &mut TypeArena, types: &[TypeHandle]) -> TypeHandle {
    if types.is_empty() {
        return arena.make(ConcreteType::Unknown);
    }
    if types.len() == 1 {
        return types[0];
    }

    // 过滤 Never 和 Void（发散/无值类型不贡献值）
    // Never：diverging（return/throw/break/continue）
    // Void：无有意义的值（如 if-then 无 else 且 then 为语句）
    let non_trivial: Vec<TypeHandle> = types
        .iter()
        .filter(|&&t| {
            !matches!(
                arena.get(arena.resolve(t)),
                ConcreteType::Never | ConcreteType::Void
            )
        })
        .copied()
        .collect();
    if non_trivial.is_empty() {
        // 全是 Never/Void → 返回第一个原始类型（保留 Never 优先）
        if types
            .iter()
            .any(|&t| matches!(arena.get(arena.resolve(t)), ConcreteType::Never))
        {
            return arena.make(ConcreteType::Never);
        }
        return arena.make(ConcreteType::Void);
    }
    if non_trivial.len() == 1 {
        return non_trivial[0];
    }

    // 全相同（结构相等）→ 返回第一个
    let first = non_trivial[0];
    if non_trivial[1..].iter().all(|&t| types_equal(arena, first, t)) {
        return first;
    }

    // 全为数值 → 取最宽
    let all_numeric = non_trivial.iter().all(|&t| {
        let ct = arena.get(arena.resolve(t));
        ct.is_int() || ct.is_float()
    });
    if all_numeric {
        return peer_numeric(arena, &non_trivial);
    }

    // 全为 nullable → Nullable<peer(inners)>
    let all_nullable = non_trivial.iter().all(|&t| {
        matches!(arena.get(arena.resolve(t)), ConcreteType::Nullable(_))
    });
    if all_nullable {
        let inners: Vec<TypeHandle> = non_trivial
            .iter()
            .map(|&t| match arena.get(arena.resolve(t)) {
                ConcreteType::Nullable(inner) => *inner,
                _ => unreachable!(),
            })
            .collect();
        let peer_inner = peer_type(arena, &inners);
        return arena.make(ConcreteType::Nullable(peer_inner));
    }

    // 含 nullable + 非 nullable → Nullable<peer(all inners)>
    let has_nullable = non_trivial.iter().any(|&t| {
        matches!(arena.get(arena.resolve(t)), ConcreteType::Nullable(_))
    });
    if has_nullable {
        let inners: Vec<TypeHandle> = non_trivial
            .iter()
            .map(|&t| match arena.get(arena.resolve(t)) {
                ConcreteType::Nullable(inner) => *inner,
                other => {
                    if matches!(other, ConcreteType::Null) {
                        arena.make(ConcreteType::Unknown)
                    } else {
                        t
                    }
                }
            })
            .collect();
        let peer_inner = peer_type(arena, &inners);
        return arena.make(ConcreteType::Nullable(peer_inner));
    }

    // 全为 throw → Throw<peer(values), peer(errors)>
    let all_throw = non_trivial.iter().all(|&t| {
        matches!(arena.get(arena.resolve(t)), ConcreteType::Throw { .. })
    });
    if all_throw {
        let (values, errors): (Vec<TypeHandle>, Vec<TypeHandle>) = non_trivial
            .iter()
            .map(|&t| match arena.get(arena.resolve(t)) {
                ConcreteType::Throw { value_type, error_type } => (*value_type, *error_type),
                _ => unreachable!(),
            })
            .unzip();
        let peer_val = peer_type(arena, &values);
        let peer_err = peer_type(arena, &errors);
        return arena.make(ConcreteType::Throw {
            value_type: peer_val,
            error_type: peer_err,
        });
    }

    // 不兼容 → Unknown
    arena.make(ConcreteType::Unknown)
}

/// 二元运算的 peer type resolution（内化字面量提升规则）。
///
/// 统一替代 `literal_promotion`：字面量提升规则内化为此函数的一部分，
/// 消除 literal_promotion 与 peer_type 的双轨制。
///
/// **规则**（按优先级）：
/// 1. 一侧字面量、另一侧变量 → 返回变量类型（字面量提升到变量类型）
/// 2. 两侧都是字面量 → `peer_numeric` 取最宽
/// 3. 两侧都是变量 → `peer_type` 求共同类型（数值取最宽、nullable 传播等）
pub fn peer_type_binary(
    arena: &mut TypeArena,
    left: TypeHandle,
    right: TypeHandle,
    left_is_literal: bool,
    right_is_literal: bool,
) -> TypeHandle {
    // 规则 1：字面量提升到变量类型
    if left_is_literal && !right_is_literal {
        return arena.resolve(right);
    }
    if !left_is_literal && right_is_literal {
        return arena.resolve(left);
    }

    // 规则 2 & 3：两侧都是字面量或都是变量 → peer_type
    peer_type(arena, &[left, right])
}

/// 数值类型的 peer resolution：取最宽类型。
///
/// 规则：
/// 1. 含 float → 取最宽 float（位宽最大）
/// 2. 全 int → 取最宽 int（同符号取位宽最大；跨符号取无符号位宽最大）
fn peer_numeric(arena: &mut TypeArena, types: &[TypeHandle]) -> TypeHandle {
    let resolved: Vec<&ConcreteType> = types
        .iter()
        .map(|&t| arena.get(arena.resolve(t)))
        .collect();

    // 含 float → 取最宽 float
    let has_float = resolved.iter().any(|ct| ct.is_float());
    if has_float {
        let mut widest = ConcreteType::F16;
        let mut widest_bits: u16 = 16;
        for ct in &resolved {
            if let Some(bits) = ct.float_bit_width() {
                if bits > widest_bits {
                    widest_bits = bits;
                    widest = match ct {
                        ConcreteType::F16 => ConcreteType::F16,
                        ConcreteType::F32 => ConcreteType::F32,
                        ConcreteType::F64 => ConcreteType::F64,
                        ConcreteType::F128 => ConcreteType::F128,
                        _ => unreachable!(),
                    };
                }
            }
        }
        return arena.make(widest);
    }

    // 全 int → 取最宽
    let mut widest = ConcreteType::I8;
    let mut widest_bits: u16 = 8;
    for ct in &resolved {
        if let Some(bits) = ct.int_bit_width() {
            if bits > widest_bits {
                widest_bits = bits;
                widest = (**ct).clone();
            }
        }
    }
    arena.make(widest)
}

// =========================================================================
// sema v2: Flow-Sensitive Narrowing — 通用 flow fact 系统
//
// 设计理念（原创，非照搬 Kotlin/TS）：
// - 把 Zig 版的 nullable narrowing 泛化为通用 flow fact 系统
// - 支持 NonNull / IsCheck / ConstructorMatch 三种窄化
// - DOD：flow facts 用 arena 索引，scope 用栈式管理
// - 查询：lookup_narrowed(path) -> Option<TypeHandle>
//
// 与 constraint solver 的关系：
// Narrowing 约束通过 FlowContext 管理，不直接进 solver 队列。
// FlowContext 是 path-sensitive 的，solver 是 path-insensitive 的。
// =========================================================================

/// 窄化种类：覆盖 Glue 的所有 flow-sensitive 类型精化场景。
#[derive(Debug, Clone)]
pub enum NarrowKind {
    /// 非空窄化：`if x != null` → x 从 `Nullable<T>` 窄化为 `T`
    NonNull,
    /// 类型判断窄化：`if x is Type` → x 窄化为 Type
    /// （Glue 的 `is` 表达式，类似 Kotlin 的 smart cast）
    IsCheck(TypeHandle),
    /// ADT 构造器匹配窄化：`match x { Some(v) => ... }` → x 窄化为 `Some<T>`
    /// （GADT 类型精化，构造器匹配后类型变量获得具体信息）
    ConstructorMatch {
        /// 构造器名（如 "Some"、"None"、"Ok"、"Err"）
        ctor_name: Box<str>,
        /// 绑定的子模式变量名（用于子模式类型精化）
        bound_vars: Box<[Box<str>]>,
    },
}

/// Flow fact：在某程序点对某路径的类型窄化断言。
///
/// `path` 是表达式的规范化路径（如 "x"、"obj.field"、"a.b.c"），
/// 用于在不同位置引用同一表达式。
#[derive(Debug, Clone)]
pub struct FlowFact {
    /// 表达式路径（规范化为字符串）
    pub path: Box<str>,
    /// 窄化后的类型
    pub narrowed_ty: TypeHandle,
    /// 窄化条件
    pub kind: NarrowKind,
}

/// Flow fact 表：存储当前 scope 内的所有 flow facts。
///
/// DOD：facts 用 Vec，by_path 用 HashMap 索引。
#[derive(Default)]
pub struct FlowFactTable {
    facts: Vec<FlowFact>,
    /// 按路径索引：path → fact indices
    by_path: HashMap<Box<str>, Vec<u32>>,
}

impl FlowFactTable {
    pub fn new() -> Self {
        Self::default()
    }

    /// 添加 flow fact。
    pub fn add(&mut self, fact: FlowFact) {
        let idx = self.facts.len() as u32;
        self.by_path
            .entry(fact.path.clone())
            .or_default()
            .push(idx);
        self.facts.push(fact);
    }

    /// 查询某路径的最新窄化类型。
    ///
    /// 返回该路径最后一次窄化的类型（同一路径可能有多次窄化，
    /// 取最新的——facts 是追加顺序，最后添加的最新）。
    pub fn lookup(&self, path: &str) -> Option<TypeHandle> {
        self.by_path
            .get(path)
            .and_then(|indices| indices.last())
            .and_then(|&idx| self.facts.get(idx as usize))
            .map(|f| f.narrowed_ty)
    }

    /// 查询某路径的最新 flow fact（含 kind）。
    pub fn lookup_fact(&self, path: &str) -> Option<&FlowFact> {
        self.by_path
            .get(path)
            .and_then(|indices| indices.last())
            .and_then(|&idx| self.facts.get(idx as usize))
    }

    /// 当前 scope 的 fact 数量。
    #[inline]
    pub fn len(&self) -> usize {
        self.facts.len()
    }

    /// 是否为空。
    #[inline]
    pub fn is_empty(&self) -> bool {
        self.facts.is_empty()
    }
}

/// Flow context：栈式管理 flow fact scopes。
///
/// 进入 if/match 分支时 push 新 scope，离开时 pop。
/// 查询时从栈顶向下查找（内层 scope 覆盖外层）。
pub struct FlowContext {
    scopes: Vec<FlowFactTable>,
}

impl Default for FlowContext {
    fn default() -> Self {
        Self::new()
    }
}

impl FlowContext {
    pub fn new() -> Self {
        FlowContext {
            scopes: vec![FlowFactTable::new()], // 根 scope
        }
    }

    /// 进入新 scope（if/match 分支）。
    pub fn push_scope(&mut self) {
        self.scopes.push(FlowFactTable::new());
    }

    /// 离开 scope。
    ///
    /// 不会弹出根 scope（保持至少一层）。
    pub fn pop_scope(&mut self) {
        if self.scopes.len() > 1 {
            self.scopes.pop();
        }
    }

    /// 在当前（栈顶）scope 添加 flow fact。
    pub fn add_fact(&mut self, fact: FlowFact) {
        if let Some(top) = self.scopes.last_mut() {
            top.add(fact);
        }
    }

    /// 查询某路径的窄化类型：从栈顶向下查找。
    ///
    /// 内层 scope 的窄化覆盖外层（path-sensitive）。
    pub fn lookup_narrowed(&self, path: &str) -> Option<TypeHandle> {
        for scope in self.scopes.iter().rev() {
            if let Some(ty) = scope.lookup(path) {
                return Some(ty);
            }
        }
        None
    }

    /// 查询某路径的 flow fact（含 kind）：从栈顶向下查找。
    pub fn lookup_fact(&self, path: &str) -> Option<&FlowFact> {
        for scope in self.scopes.iter().rev() {
            if let Some(fact) = scope.lookup_fact(path) {
                return Some(fact);
            }
        }
        None
    }

    /// 当前 scope 深度。
    #[inline]
    pub fn depth(&self) -> usize {
        self.scopes.len()
    }

    /// 重置到根 scope（函数切换时调用）。
    pub fn reset(&mut self) {
        self.scopes.truncate(1);
        self.scopes[0] = FlowFactTable::new();
    }
}

/// 从 `if cond { ... }` 的条件表达式提取 flow facts。
///
/// 返回 (then_facts, else_facts)：
/// - then_facts：then 分支成立的窄化
/// - else_facts：else 分支成立的窄化（条件取反）
///
/// 支持：
/// - `x != null` → then: NonNull(x), else: 无
/// - `x == null` → then: 无, else: NonNull(x)
/// - `x is Type` → then: IsCheck(x, Type), else: 无
/// （ConstructorMatch 由 match 表达式处理，不在此函数）
pub fn analyze_null_check_facts(
    arena: &TypeArena,
    ast: &AstArena<'_>,
    cond: ExprId,
    env: EnvId,
    env_arena: &EnvArena,
) -> (Vec<FlowFact>, Vec<FlowFact>) {
    let mut then_facts = Vec::new();
    let mut else_facts = Vec::new();

    // 若 `path_expr` 是 nullable 变量路径且 `null_expr` 是 null 字面量，
    // 则向 `facts` 推入 NonNull 窄化事实。
    let push_nonnull = |path_expr: ExprId, null_expr: ExprId, facts: &mut Vec<FlowFact>| {
        if let Some(path) = expr_path(ast, path_expr) {
            if matches!(ast.expr(null_expr).node, Expr::NullLit) {
                if let Some(ty) = env_arena.lookup(env, &path) {
                    if let ConcreteType::Nullable(inner) = arena.get(arena.resolve(ty)) {
                        facts.push(FlowFact {
                            path: path.into(),
                            narrowed_ty: *inner,
                            kind: NarrowKind::NonNull,
                        });
                    }
                }
            }
        }
    };

    let cond_node = &ast.expr(cond).node;
    if let Expr::Binary { op, lhs, rhs } = cond_node {
        match op {
            crate::Ast::BinaryOp::NotEq => {
                // `x != null` / `null != x` → then: NonNull(x)
                push_nonnull(*lhs, *rhs, &mut then_facts);
                push_nonnull(*rhs, *lhs, &mut then_facts);
            }
            crate::Ast::BinaryOp::Eq => {
                // `x == null` / `null == x` → else: NonNull(x)
                push_nonnull(*lhs, *rhs, &mut else_facts);
                push_nonnull(*rhs, *lhs, &mut else_facts);
            }
            _ => {}
        }
    }

    (then_facts, else_facts)
}

/// 提取表达式的规范化路径（用于 flow narrowing 标识）。
///
/// 支持：
/// - `Ident(name)` → `name`
/// - `FieldAccess(recv, field)` → `{recv_path}.{field}`
/// - 其他 → None（不可窄化）
fn expr_path(ast: &AstArena<'_>, expr: ExprId) -> Option<String> {
    match &ast.expr(expr).node {
        Expr::Ident(name) => Some((*name).to_string()),
        Expr::FieldAccess { recv, field } => {
            let recv_path = expr_path(ast, *recv)?;
            Some(format!("{}.{}", recv_path, field))
        }
        _ => None,
    }
}

/// 从模式节点提取构造器名和绑定的变量名（用于 ConstructorMatch narrowing）。
///
/// 仅处理 `Constructor { name, patterns }` 模式，提取构造器名和
/// 子模式中所有 `Variable` 绑定的变量名。
///
/// 其他模式（Wildcard/Literal/Variable/Record/Or/Guard）返回 None。
fn extract_constructor_pattern<'a>(
    pattern: &crate::Ast::Pattern<'a>,
) -> Option<(&'a str, Vec<Box<str>>)> {
    match pattern {
        crate::Ast::Pattern::Constructor { name, patterns: _ } => {
            // 子模式变量名提取需传入 ast 才能访问 PatternRef 节点，
            // 此处简化：返回空列表，实际 narrow 仍用构造器名
            Some((*name, Vec::new()))
        }
        _ => None,
    }
}

// =========================================================================
// sema v2: Witness Table — trait 实现的静态分派表
//
// 设计理念（原创，非照搬 Swift/Haskell）：
// - trait 实现编译期物化为 WitnessEntry（函数指针表）
// - 通过 ConcreteType.type_id 索引分派，O(1)
// - 替代当前 mangled name ("TypeName.method") 查找
// - 与 Glue 的 type_id/反射机制天然契合
//
// 数据结构：
// - WitnessEntry { trait_name, type_id, method_slots }
// - WitnessTable 用 Vec<WitnessEntry> + HashMap<(trait_name, type_id), idx> 索引
//
// 分派流程：
// 1. 推断接收者类型 → resolve → 取 type_id（标量直接有，ADT 查 type_def）
// 2. 构造 key = (trait_name, type_id)
// 3. 查 witness table → 取 method_slots
// 4. method_slots[method_name] → method slot index
// 5. slot index 指向 MonomorphInstance（已编译的方法体）
// =========================================================================

/// Witness table 条目：一个 trait 在一个类型上的实现。
#[derive(Debug, Clone)]
pub struct WitnessEntry {
    /// trait 名（如 "Show"、"Eq"、"Error"）
    pub trait_name: Box<str>,
    /// 实现类型的 type_id（与 ConcreteType.type_id 对应）
    pub type_id: u16,
    /// 方法槽位：method_name → method slot index
    /// slot index 指向 MonomorphInstance.instance_id
    pub method_slots: HashMap<Box<str>, u32>,
    /// 实现类型的名字（用于错误信息）
    pub type_name: Box<str>,
}

/// Witness table：所有 trait 实现的索引表。
///
/// 通过 (trait_name, type_id) 索引到 WitnessEntry，
/// 再通过 method_name 索引到 method slot。
#[derive(Default)]
pub struct WitnessTable {
    entries: Vec<WitnessEntry>,
    /// 索引：(trait_name, type_id) → entries 下标
    index: HashMap<(Box<str>, u16), u32>,
}

impl WitnessTable {
    pub fn new() -> Self {
        Self::default()
    }

    /// 注册一个 trait 实现。
    ///
    /// 若 (trait_name, type_id) 已存在，覆盖旧实现（允许重定义）。
    pub fn register(
        &mut self,
        trait_name: &str,
        type_id: u16,
        type_name: &str,
        method_slots: HashMap<Box<str>, u32>,
    ) {
        let key = (trait_name.into(), type_id);
        if let Some(&idx) = self.index.get(&key) {
            // 覆盖已有实现
            self.entries[idx as usize] = WitnessEntry {
                trait_name: trait_name.into(),
                type_id,
                method_slots,
                type_name: type_name.into(),
            };
        } else {
            let idx = self.entries.len() as u32;
            self.entries.push(WitnessEntry {
                trait_name: trait_name.into(),
                type_id,
                method_slots,
                type_name: type_name.into(),
            });
            self.index.insert(key, idx);
        }
    }

    /// 查询某类型是否实现了某 trait。
    #[inline]
    pub fn implements(&self, trait_name: &str, type_id: u16) -> bool {
        self.index.contains_key(&(trait_name.into(), type_id))
    }

    /// 查询某 trait 实现的某方法 slot。
    ///
    /// 返回 MonomorphInstance.instance_id（方法体的单态化实例）。
    pub fn resolve_method(
        &self,
        trait_name: &str,
        type_id: u16,
        method_name: &str,
    ) -> Option<u32> {
        let key = (trait_name.into(), type_id);
        let &idx = self.index.get(&key)?;
        let entry = &self.entries[idx as usize];
        entry.method_slots.get(method_name).copied()
    }

    /// 获取某 trait 实现的所有方法名。
    pub fn trait_methods(&self, trait_name: &str, type_id: u16) -> Vec<&str> {
        let key = (trait_name.into(), type_id);
        match self.index.get(&key) {
            Some(&idx) => self.entries[idx as usize]
                .method_slots
                .keys()
                .map(|k| k.as_ref())
                .collect(),
            None => Vec::new(),
        }
    }

    /// 获取所有条目（用于反射/诊断）。
    #[inline]
    pub fn entries(&self) -> &[WitnessEntry] {
        &self.entries
    }

    /// 条目数量。
    #[inline]
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// 是否为空。
    #[inline]
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

/// 从 ConcreteType 提取 type_id（用于 witness table 索引）。
///
/// 标量直接有 type_id；ADT/Record 用 type_def 在 type_defs 中的索引
/// （+22 偏移，与 TypeDesc.rs 的 type_id 编号约定一致）；TypeVar 返回 None。
pub fn type_id_of(arena: &TypeArena, ty: TypeHandle, sema_result: &SemaResult) -> Option<u16> {
    let resolved = arena.resolve(ty);
    let ct = arena.get(resolved);
    match ct {
        // 标量：直接取 builtin_type_id
        ConcreteType::I8
        | ConcreteType::I16
        | ConcreteType::I32
        | ConcreteType::I64
        | ConcreteType::I128
        | ConcreteType::U8
        | ConcreteType::U16
        | ConcreteType::U32
        | ConcreteType::U64
        | ConcreteType::U128
        | ConcreteType::Isize
        | ConcreteType::Usize
        | ConcreteType::F16
        | ConcreteType::F32
        | ConcreteType::F64
        | ConcreteType::F128
        | ConcreteType::Bool
        | ConcreteType::Str
        | ConcreteType::Char => ct.builtin_type_id(),
        // ADT：用 type_def 在 type_defs 中的索引作为 type_id（+22 偏移）
        ConcreteType::Adt { name, .. } => sema_result
            .type_def_index
            .get(name.as_ref())
            .map(|&idx| 22 + idx as u16),
        // Generic：同 ADT，用 type_def 索引
        ConcreteType::Generic { name, .. } => sema_result
            .type_def_index
            .get(name.as_ref())
            .map(|&idx| 22 + idx as u16),
        // TypeVar/Nullable/Throw/Fn/Record/Array/Trait/Ref/Never/Unknown/Null/Void
        _ => None,
    }
}

// =========================================================================
// 测试
// =========================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Ast::{PatternId, Span, TypeId};
    use crate::TypeDesc::{lookup_by_type_id, I32_DESC, I64_DESC, STR_DESC};

    // ── ConcreteType 分类谓词 ──

    #[test]
    fn scalar_predicates() {
        assert!(ConcreteType::I8.is_int());
        assert!(ConcreteType::U128.is_int());
        assert!(ConcreteType::Isize.is_int());
        assert!(!ConcreteType::F32.is_int());
        assert!(ConcreteType::F16.is_float());
        assert!(ConcreteType::F128.is_float());
        assert!(!ConcreteType::Bool.is_float());
        assert!(ConcreteType::I32.is_numeric());
        assert!(ConcreteType::F64.is_numeric());
        assert!(!ConcreteType::Bool.is_numeric());
        assert!(ConcreteType::I8.is_signed_int());
        assert!(ConcreteType::Isize.is_signed_int());
        assert!(!ConcreteType::U8.is_signed_int());
        assert_eq!(ConcreteType::I8.int_bit_width(), Some(8));
        assert_eq!(ConcreteType::U64.int_bit_width(), Some(64));
        assert_eq!(ConcreteType::I128.int_bit_width(), Some(128));
        assert_eq!(ConcreteType::F32.float_bit_width(), Some(32));
        assert_eq!(ConcreteType::Bool.int_bit_width(), None);
    }

    #[test]
    fn builtin_name_coverage() {
        assert_eq!(ConcreteType::I8.builtin_name(), Some("i8"));
        assert_eq!(ConcreteType::Void.builtin_name(), Some("void"));
        assert_eq!(ConcreteType::Null.builtin_name(), Some("Null"));
        assert_eq!(ConcreteType::Str.builtin_name(), Some("str"));
        assert_eq!(ConcreteType::Never.builtin_name(), None);
        assert_eq!(ConcreteType::Unknown.builtin_name(), None);
        // 复合类型无 builtin name
        assert_eq!(
            ConcreteType::Nullable(TypeHandle(0)).builtin_name(),
            None
        );
    }

    #[test]
    fn int_to_float_widening_matrix() {
        // i8 → f32/f64/f128 OK
        assert!(ConcreteType::int_to_float_widening(&ConcreteType::I8, &ConcreteType::F32));
        assert!(ConcreteType::int_to_float_widening(&ConcreteType::U16, &ConcreteType::F128));
        // i32 → f32 不允许（精度损失）
        assert!(!ConcreteType::int_to_float_widening(&ConcreteType::I32, &ConcreteType::F32));
        assert!(ConcreteType::int_to_float_widening(&ConcreteType::I32, &ConcreteType::F64));
        // i64 → 仅 f128
        assert!(!ConcreteType::int_to_float_widening(&ConcreteType::I64, &ConcreteType::F64));
        assert!(ConcreteType::int_to_float_widening(&ConcreteType::U64, &ConcreteType::F128));
        // i128 → 无
        assert!(!ConcreteType::int_to_float_widening(&ConcreteType::I128, &ConcreteType::F128));
        // isize 归约后判定
        let bits = isize::BITS as u16;
        let ok = if bits <= 32 {
            ConcreteType::int_to_float_widening(&ConcreteType::Isize, &ConcreteType::F64)
        } else {
            ConcreteType::int_to_float_widening(&ConcreteType::Isize, &ConcreteType::F128)
        };
        assert!(ok);
    }

    // ── TypeArena: resolve / occurs / unify ──

    #[test]
    fn fresh_type_var_unbound_resolves_to_self() {
        let mut arena = TypeArena::new();
        let v = arena.fresh_type_var();
        assert_eq!(arena.resolve(v), v);
        assert!(!arena.type_var(0).is_rigid);
    }

    #[test]
    fn unify_scalars_same_ok() {
        let mut arena = TypeArena::new();
        let a = arena.make(ConcreteType::I32);
        let b = arena.make(ConcreteType::I32);
        assert!(arena.unify(a, b).is_ok());
    }

    #[test]
    fn unify_scalars_mismatch() {
        let mut arena = TypeArena::new();
        let a = arena.make(ConcreteType::I32);
        let b = arena.make(ConcreteType::I64);
        assert_eq!(arena.unify(a, b), Err(UnifyError::TypeMismatch));
    }

    #[test]
    fn unify_type_var_binds() {
        let mut arena = TypeArena::new();
        let v = arena.fresh_type_var();
        let i = arena.make(ConcreteType::I32);
        assert!(arena.unify(v, i).is_ok());
        // resolve(v) 现在应指向 i
        assert_eq!(arena.resolve(v), i);
    }

    #[test]
    fn unify_rigid_var_rejects_binding() {
        let mut arena = TypeArena::new();
        let v = arena.fresh_rigid_var();
        let i = arena.make(ConcreteType::I32);
        // rigid var 不可与不同类型统一
        assert_eq!(arena.unify(v, i), Err(UnifyError::TypeMismatch));
        // rigid var 可与自身（同 idx）统一
        let v2 = arena.make(ConcreteType::TypeVar(0));
        assert!(arena.unify(v, v2).is_ok());
    }

    #[test]
    fn occurs_check_prevents_infinite_type() {
        let mut arena = TypeArena::new();
        let v = arena.fresh_type_var(); // idx 0
        let inner = v;
        // 构造 f: () -> v，再 unify v 与 f → occurs 失败
        let ft = arena.make(ConcreteType::Fn {
            params: Box::new([]),
            return_type: inner,
        });
        assert_eq!(arena.unify(v, ft), Err(UnifyError::OccursCheckFailed));
    }

    #[test]
    fn unify_never_promotes_to_other() {
        let mut arena = TypeArena::new();
        let n = arena.make(ConcreteType::Never);
        let i = arena.make(ConcreteType::I32);
        assert!(arena.unify(n, i).is_ok());
        // never 槽位被覆写为 I32
        assert_eq!(arena.get(n), &ConcreteType::I32);
    }

    #[test]
    fn unify_unknown_promotes_to_other() {
        let mut arena = TypeArena::new();
        let u = arena.make(ConcreteType::Unknown);
        let i = arena.make(ConcreteType::I64);
        assert!(arena.unify(u, i).is_ok());
        assert_eq!(arena.get(u), &ConcreteType::I64);
    }

    #[test]
    fn unify_structural_fn() {
        let mut arena = TypeArena::new();
        let p1 = arena.make(ConcreteType::I32);
        let r1 = arena.make(ConcreteType::Bool);
        let p2 = arena.make(ConcreteType::I32);
        let r2 = arena.make(ConcreteType::Bool);
        let f1 = arena.make(ConcreteType::Fn {
            params: Box::new([p1]),
            return_type: r1,
        });
        let f2 = arena.make(ConcreteType::Fn {
            params: Box::new([p2]),
            return_type: r2,
        });
        assert!(arena.unify(f1, f2).is_ok());
        // 参数数不匹配
        let g = arena.make(ConcreteType::Fn {
            params: Box::new([]),
            return_type: r1,
        });
        assert_eq!(arena.unify(f1, g), Err(UnifyError::TypeMismatch));
    }

    #[test]
    fn unify_structural_adt_name_mismatch() {
        let mut arena = TypeArena::new();
        let i = arena.make(ConcreteType::I32);
        let a = arena.make(ConcreteType::Adt {
            name: "Option".into(),
            type_args: Box::new([i]),
        });
        let i2 = arena.make(ConcreteType::I32);
        let b = arena.make(ConcreteType::Adt {
            name: "Result".into(),
            type_args: Box::new([i2]),
        });
        assert_eq!(arena.unify(a, b), Err(UnifyError::TypeMismatch));
    }

    #[test]
    fn unify_record_fields() {
        let mut arena = TypeArena::new();
        let i = arena.make(ConcreteType::I32);
        let b = arena.make(ConcreteType::Bool);
        let r1 = arena.make(ConcreteType::Record {
            fields: Box::new([
                FieldType { name: Some("x".into()), ty: i },
                FieldType { name: Some("y".into()), ty: b },
            ]),
            name: None,
        });
        let i2 = arena.make(ConcreteType::I32);
        let b2 = arena.make(ConcreteType::Bool);
        let r2 = arena.make(ConcreteType::Record {
            fields: Box::new([
                FieldType { name: Some("x".into()), ty: i2 },
                FieldType { name: Some("y".into()), ty: b2 },
            ]),
            name: None,
        });
        assert!(arena.unify(r1, r2).is_ok());
    }

    #[test]
    fn unify_type_var_shared_across_fn_params() {
        let mut arena = TypeArena::new();
        let v = arena.fresh_type_var();
        let i = arena.make(ConcreteType::I32);
        let void1 = arena.make(ConcreteType::Void);
        // fn(v, v) 与 fn(i32, i32) 统一 → v 绑定 i32
        let f1 = arena.make(ConcreteType::Fn {
            params: Box::new([v, v]),
            return_type: void1,
        });
        let i3 = arena.make(ConcreteType::I32);
        let void2 = arena.make(ConcreteType::Void);
        let f2 = arena.make(ConcreteType::Fn {
            params: Box::new([i, i3]),
            return_type: void2,
        });
        assert!(arena.unify(f1, f2).is_ok());
        assert_eq!(arena.resolve(v), i);
    }

    // ── from_scalar_name ──

    #[test]
    fn from_scalar_name_builtins() {
        let mut arena = TypeArena::new();
        let h = arena.from_scalar_name("i32");
        assert_eq!(arena.get(h), &ConcreteType::I32);
        let h = arena.from_scalar_name("void");
        assert_eq!(arena.get(h), &ConcreteType::Void);
        let h = arena.from_scalar_name("Null");
        assert_eq!(arena.get(h), &ConcreteType::Null);
        let h = arena.from_scalar_name("f128");
        assert_eq!(arena.get(h), &ConcreteType::F128);
        // 未知名 → Unknown
        let h = arena.from_scalar_name("nope");
        assert_eq!(arena.get(h), &ConcreteType::Unknown);
    }

    // ── type_name / display ──

    #[test]
    fn type_name_and_display() {
        let mut arena = TypeArena::new();
        let i = arena.make(ConcreteType::I32);
        assert_eq!(arena.type_name(i), Some("i32"));

        let opt = arena.make(ConcreteType::Adt {
            name: "Option".into(),
            type_args: Box::new([i]),
        });
        assert_eq!(arena.type_name(opt), Some("Option"));
        assert_eq!(format!("{}", arena.display(opt)), "Option<i32>");

        let b = arena.make(ConcreteType::Bool);
        let u = arena.make(ConcreteType::Void);
        let f = arena.make(ConcreteType::Fn {
            params: Box::new([i, b]),
            return_type: u,
        });
        assert_eq!(format!("{}", arena.display(f)), "(i32, bool) -> void");

        let v = arena.fresh_type_var();
        assert_eq!(format!("{}", arena.display(v)), "'_0");

        let arr = arena.make(ConcreteType::Array {
            element_type: i,
            size: Some(3),
        });
        assert_eq!(format!("{}", arena.display(arr)), "i32[3]");

        let nul = arena.make(ConcreteType::Nullable(i));
        assert_eq!(format!("{}", arena.display(nul)), "i32?");

        let r = arena.make(ConcreteType::Ref { inner: i, is_raw: false });
        assert_eq!(format!("{}", arena.display(r)), "&i32");
        let rp = arena.make(ConcreteType::Ref { inner: i, is_raw: true });
        assert_eq!(format!("{}", arena.display(rp)), "*i32");
    }

    // ── ConcreteEnv / EnvArena ──

    #[test]
    fn env_define_lookup_parent() {
        let mut envs = EnvArena::new();
        let root = envs.root();
        let mut arena = TypeArena::new();
        let i = arena.make(ConcreteType::I32);
        assert!(envs.define(root, "x", i));
        // 重复定义失败
        assert!(!envs.define(root, "x", i));

        let child = envs.child(root);
        // 子环境能查到父环境绑定
        assert_eq!(envs.lookup(child, "x"), Some(i));
        // 子环境定义新绑定
        let b = arena.make(ConcreteType::Bool);
        assert!(envs.define(child, "y", b));
        assert_eq!(envs.lookup(child, "y"), Some(b));
        // 父环境看不到子环境绑定
        assert_eq!(envs.lookup(root, "y"), None);
        // 未定义名字
        assert_eq!(envs.lookup(child, "z"), None);
    }

    // ── SemaResult ──

    #[test]
    fn sema_result_expr_and_error() {
        let mut sr = SemaResult::new();
        let info = ExprInfo::new(&I32_DESC, 42);
        sr.put_expr(42, info);
        assert_eq!(sr.get_expr(42).map(|i| i.expr_id), Some(42));
        assert!(sr.get_expr(7).is_none());

        sr.add_error(SemaError::new("bad expr", 10, 3));
        assert!(sr.has_error);
        assert_eq!(sr.errors.len(), 1);
        assert_eq!(sr.errors[0].line, 10);
    }

    #[test]
    fn sema_result_type_def_and_field_ids() {
        let mut sr = SemaResult::new();
        let def = TypeDefInfo {
            name: "Point".into(),
            kind: TypeDefKind::Record,
            constructors: Box::new([CtorDefInfo {
                name: "Point".into(),
                type_name: "Point".into(),
                field_names: Box::new([Some("x".into()), Some("y".into())]),
                field_type_descs: Box::new([&I32_DESC, &I32_DESC]),
                field_type_names: Box::new([Some("i32".into()), Some("i32".into())]),
                is_newtype: false,
                return_type_name: None,
                return_type_node: None,
                field_type_nodes: Box::new([]),
            }]),
            type_params: Box::new([]),
            target_type_name: None,
            target_type_desc: None,
        };
        assert!(sr.put_type_def(def));
        assert!(sr.get_type_def("Point").is_some());
        // record 字段从 0 开始
        assert_eq!(sr.lookup_field_id("Point", "x"), Some(0));
        assert_eq!(sr.lookup_field_id("Point", "y"), Some(1));
        assert_eq!(sr.lookup_field_id("Point", "z"), None);
        // 构造器查询
        assert!(sr.get_ctor_def("Point").is_some());

        // ADT: __tag=0, 字段从 1 开始
        let adt = TypeDefInfo {
            name: "Option".into(),
            kind: TypeDefKind::Adt,
            constructors: Box::new([
                CtorDefInfo {
                    name: "Some".into(),
                    type_name: "Option".into(),
                    field_names: Box::new([Some("value".into())]),
                    field_type_descs: Box::new([&I32_DESC]),
                    field_type_names: Box::new([Some("i32".into())]),
                    is_newtype: false,
                    return_type_name: None,
                    return_type_node: None,
                    field_type_nodes: Box::new([]),
                },
                CtorDefInfo {
                    name: "None".into(),
                    type_name: "Option".into(),
                    field_names: Box::new([]),
                    field_type_descs: Box::new([]),
                    field_type_names: Box::new([]),
                    is_newtype: false,
                    return_type_name: None,
                    return_type_node: None,
                    field_type_nodes: Box::new([]),
                },
            ]),
            type_params: Box::new([]),
            target_type_name: None,
            target_type_desc: None,
        };
        assert!(sr.put_type_def(adt));
        assert_eq!(sr.lookup_field_id("Option", "__tag"), Some(0));
        assert_eq!(sr.lookup_field_id("Option", "value"), Some(1));

        // 重复类型名失败
        let dup = TypeDefInfo {
            name: "Point".into(),
            kind: TypeDefKind::Alias,
            constructors: Box::new([]),
            type_params: Box::new([]),
            target_type_name: None,
            target_type_desc: None,
        };
        assert!(!sr.put_type_def(dup));
    }

    #[test]
    fn sema_result_trait_and_func_sigs() {
        let mut sr = SemaResult::new();
        let trait_def = TraitDefInfo {
            name: "Show".into(),
            methods: Box::new([TraitMethodSig {
                name: "show".into(),
                param_count: 0,
                return_type_desc: &STR_DESC,
                is_async: false,
                has_body: false,
            }]),
        };
        assert!(sr.put_trait_def(trait_def));
        assert_eq!(sr.get_trait_def("Show").map(|t| t.methods.len()), Some(1));
        assert!(!sr.put_trait_def(TraitDefInfo {
            name: "Show".into(),
            methods: Box::new([]),
        }));

        let sig = FuncSigInfo {
            name: "add".into(),
            type_params: Box::new([]),
            param_type_descs: Box::new([&I32_DESC, &I32_DESC]),
            return_type_desc: &I32_DESC,
            param_is_ref: Box::new([false, false]),
            return_is_ref: false,
            is_async: false,
            is_throwing: false,
            param_type_names: Box::new([Some("i32".into()), Some("i32".into())]),
        };
        assert!(sr.put_func_sig(sig));
        assert!(sr.get_func_sig("add").is_some());
    }

    #[test]
    fn sema_result_import_alias() {
        let mut sr = SemaResult::new();
        assert!(sr
            .put_import_alias(
                "Calendar",
                AliasTarget::Module("std.time.Calendar".into())
            ));
        assert!(!sr
            .put_import_alias(
                "Calendar",
                AliasTarget::Module("std.time.Calendar".into())
            ));
        match sr.get_import_alias("Calendar").unwrap() {
            AliasTarget::Module(m) => assert_eq!(m.as_ref(), "std.time.Calendar"),
            _ => panic!("expected module alias"),
        }
    }

    #[test]
    fn sema_result_ref_desc_creation() {
        let mut sr = SemaResult::new();
        // str → 静态描述符
        let s = sr.get_or_create_ref_desc("str");
        assert_eq!(s.type_id, 19);
        // 用户类型 → 动态注册
        let d = sr.get_or_create_ref_desc("MyType");
        assert!(d.type_id >= 22);
        assert_eq!(d.type_name, "MyType");
        // 重复查询返回同一描述符
        let d2 = sr.get_or_create_ref_desc("MyType");
        assert_eq!(d.type_id, d2.type_id);
    }

    #[test]
    fn sema_result_nullable_desc_creation() {
        let mut sr = SemaResult::new();
        let n = sr.get_or_create_nullable_desc(&I64_DESC);
        assert!(n.is_nullable());
        assert_eq!(n.size, 9); // inner 8 + flag 1
        // 重复创建返回同一描述符
        let n2 = sr.get_or_create_nullable_desc(&I64_DESC);
        assert_eq!(n.type_id, n2.type_id);
    }

    #[test]
    fn sema_result_take_pool() {
        let mut sr = SemaResult::new();
        sr.get_or_create_ref_desc("Foo");
        let pool = sr.take_type_desc_pool();
        assert!(pool.get_by_name("Foo").is_some());
        // 转移后 sr 持有空 pool
        assert!(sr.type_desc_pool.get_by_name("Foo").is_none());
    }

    #[test]
    fn sema_result_coroutine_meta() {
        let mut sr = SemaResult::new();
        sr.put_coroutine_meta(CoroutineMeta {
            func_idx: 5,
            segment_count: 3,
        });
        let m = sr.get_coroutine_meta_by_func_idx(5).unwrap();
        assert_eq!(m.segment_count, 3);
        assert!(sr.get_coroutine_meta_by_func_idx(9).is_none());
    }

    // ── builtin_types ──

    #[test]
    fn int_kind_from_name_coverage() {
        assert_eq!(int_kind_from_name("i8"), Some(IntKind::I8));
        assert_eq!(int_kind_from_name("u128"), Some(IntKind::U128));
        assert_eq!(int_kind_from_name("isize"), Some(IntKind::Isize));
        assert_eq!(int_kind_from_name("f32"), None);
        assert_eq!(int_kind_from_name("bool"), None);
        assert_eq!(int_kind_from_name("nope"), None);
    }

    #[test]
    fn float_kind_from_name_coverage() {
        assert_eq!(float_kind_from_name("f16"), Some(FloatKind::F16));
        assert_eq!(float_kind_from_name("f128"), Some(FloatKind::F128));
        assert_eq!(float_kind_from_name("i32"), None);
        assert_eq!(float_kind_from_name("nope"), None);
    }

    #[test]
    fn type_descriptor_from_builtin_name_all() {
        assert_eq!(type_descriptor_from_builtin_name("i8").unwrap().type_id, 1);
        assert_eq!(type_descriptor_from_builtin_name("i32").unwrap().type_id, 3);
        assert_eq!(type_descriptor_from_builtin_name("u64").unwrap().type_id, 9);
        assert_eq!(type_descriptor_from_builtin_name("f64").unwrap().type_id, 15);
        assert_eq!(type_descriptor_from_builtin_name("bool").unwrap().type_id, 17);
        assert_eq!(type_descriptor_from_builtin_name("char").unwrap().type_id, 18);
        assert_eq!(type_descriptor_from_builtin_name("str").unwrap().type_id, 19);
        assert_eq!(type_descriptor_from_builtin_name("null").unwrap().type_id, 20);
        assert_eq!(type_descriptor_from_builtin_name("void").unwrap().type_id, 21);
        assert!(type_descriptor_from_builtin_name("MyType").is_none());
        assert!(type_descriptor_from_builtin_name("").is_none());
    }

    #[test]
    fn generic_type_arity_table() {
        assert_eq!(generic_type_arity("Throw"), Some(2));
        assert_eq!(generic_type_arity("Channel"), Some(1));
        assert_eq!(generic_type_arity("Lazy"), Some(1));
        assert_eq!(generic_type_arity("TypeInfo"), Some(1));
        assert_eq!(generic_type_arity("Nope"), None);
        assert!(is_builtin_generic_type("Async"));
        assert!(!is_builtin_generic_type("Vec"));
    }

    #[test]
    fn builtin_type_id_method() {
        assert_eq!(ConcreteType::I8.builtin_type_id(), Some(1));
        assert_eq!(ConcreteType::U128.builtin_type_id(), Some(10));
        assert_eq!(ConcreteType::Str.builtin_type_id(), Some(19));
        assert_eq!(ConcreteType::Void.builtin_type_id(), Some(21));
        assert_eq!(ConcreteType::Never.builtin_type_id(), None);
        assert_eq!(ConcreteType::Unknown.builtin_type_id(), None);
        assert_eq!(ConcreteType::TypeVar(0).builtin_type_id(), None);
    }

    // ── type_resolver ──

    /// 测试辅助：构建 AstArena 并分配类型节点。
    /// 返回的 arena 中各 TypeId 对应：
    /// [0] Named("i32")  [1] Named("MyType")
    /// [2] Named("i32") inner  [3] RefType{inner:[2]}
    /// [4] Named("i32") arg  [5] Generic{name:"List", args:[[4]]}
    /// [6] Named("i32") inner  [7] Nullable{inner:[6]}
    /// [8] SelfType  [9] Named("T")  [10] Named("void")
    fn make_ast_with_types() -> AstArena<'static> {
        let mut ast = AstArena::new();
        ast.alloc_type(Span::new(1, 1), TypeNode::Named { name: "i32" }); // [0]
        ast.alloc_type(Span::new(1, 1), TypeNode::Named { name: "MyType" }); // [1]
        let inner_i32 = ast.alloc_type(Span::new(1, 5), TypeNode::Named { name: "i32" }); // [2]
        ast.alloc_type(Span::new(1, 1), TypeNode::RefType { inner: inner_i32 }); // [3]
        let arg_i32 = ast.alloc_type(Span::new(1, 7), TypeNode::Named { name: "i32" }); // [4]
        ast.alloc_type(
            Span::new(1, 1),
            TypeNode::Generic { name: "List", args: vec![arg_i32] },
        ); // [5]
        let inner_i32_2 = ast.alloc_type(Span::new(1, 1), TypeNode::Named { name: "i32" }); // [6]
        ast.alloc_type(Span::new(1, 1), TypeNode::Nullable { inner: inner_i32_2 }); // [7]
        ast.alloc_type(Span::new(1, 1), TypeNode::SelfType); // [8]
        ast.alloc_type(Span::new(1, 1), TypeNode::Named { name: "T" }); // [9]
        ast.alloc_type(Span::new(1, 1), TypeNode::Named { name: "void" }); // [10]
        ast
    }

    #[test]
    fn type_name_from_node_basic() {
        let ast = make_ast_with_types();
        assert_eq!(type_name_from_node(Some(TypeId(0)), &ast), Some("i32"));
        // RefType → 递归到 inner
        assert_eq!(type_name_from_node(Some(TypeId(3)), &ast), Some("i32"));
        // Generic → 返回基类名
        assert_eq!(type_name_from_node(Some(TypeId(5)), &ast), Some("List"));
        assert_eq!(type_name_from_node(None, &ast), None);
    }

    #[test]
    fn resolve_type_node_concrete_builtins() {
        let ast = make_ast_with_types();
        let mut sr = SemaResult::new();
        let td = resolve_type_node_concrete(Some(TypeId(0)), &[], &ast, &mut sr).unwrap();
        assert_eq!(td.type_id, 3); // i32
        let td = resolve_type_node_concrete(Some(TypeId(10)), &[], &ast, &mut sr).unwrap();
        assert_eq!(td.type_id, 21); // void
    }

    #[test]
    fn resolve_type_node_concrete_user_type() {
        let ast = make_ast_with_types();
        let mut sr = SemaResult::new();
        let td = resolve_type_node_concrete(Some(TypeId(1)), &[], &ast, &mut sr).unwrap();
        assert!(td.type_id >= 22);
        assert_eq!(td.type_name, "MyType");
    }

    #[test]
    fn resolve_type_node_concrete_type_args_binding() {
        let ast = make_ast_with_types();
        let mut sr = SemaResult::new();
        // type_args 绑定按 type_name 匹配参数名。
        // 在 pool 中注册名为 "i32" 的引用描述符（type_id >= 22，不同于内置标量 i32 的 type_id=3）。
        // type_args 绑定优先于内置标量查找，应返回 pool_i32 而非内置 i32。
        let pool_i32 = sr.get_or_create_ref_desc("i32");
        assert!(pool_i32.type_id >= 22);
        let td =
            resolve_type_node_concrete(Some(TypeId(0)), &[pool_i32], &ast, &mut sr).unwrap();
        assert_eq!(td.type_id, pool_i32.type_id); // type_args 绑定优先
    }

    #[test]
    fn resolve_type_node_concrete_nullable_and_ref() {
        let ast = make_ast_with_types();
        let mut sr = SemaResult::new();
        // Nullable<i32> → 递归到 i32 静态描述符
        let td = resolve_type_node_concrete(Some(TypeId(7)), &[], &ast, &mut sr).unwrap();
        assert_eq!(td.type_id, 3);
        // &i32 → "i32" 具名引用描述符（ref_chan，非标量描述符）
        let td = resolve_type_node_concrete(Some(TypeId(3)), &[], &ast, &mut sr).unwrap();
        assert!(td.type_id >= 22);
    }

    #[test]
    fn resolve_type_node_concrete_self_type() {
        let ast = make_ast_with_types();
        let mut sr = SemaResult::new();
        // Self 无绑定 → "Self" 具名描述符
        let td = resolve_type_node_concrete(Some(TypeId(8)), &[], &ast, &mut sr).unwrap();
        assert_eq!(td.type_name, "Self");
        // Self 有 type_args 绑定（type_name="Self" 的描述符）→ 返回绑定描述符
        let self_desc = sr.get_or_create_ref_desc("Self");
        let td =
            resolve_type_node_concrete(Some(TypeId(8)), &[self_desc], &ast, &mut sr).unwrap();
        assert_eq!(td.type_id, self_desc.type_id);
    }

    #[test]
    fn resolve_named_type_resolved_alias_chain() {
        let mut sr = SemaResult::new();
        // alias: MyInt → i32（仅 target_type_name，需递归）
        let alias_def = TypeDefInfo {
            name: "MyInt".into(),
            kind: TypeDefKind::Alias,
            constructors: Box::new([]),
            type_params: Box::new([]),
            target_type_name: Some("i32".into()),
            target_type_desc: None,
        };
        assert!(sr.put_type_def(alias_def));
        let td = resolve_named_type_resolved("MyInt", &[], &mut sr);
        assert_eq!(td.type_id, 3); // 递归到 i32
    }

    #[test]
    fn resolve_named_type_resolved_alias_with_desc() {
        let mut sr = SemaResult::new();
        let bool_desc = lookup_by_type_id(17).unwrap();
        // newtype: MyBool → bool（有 target_type_desc，直接返回）
        let newtype_def = TypeDefInfo {
            name: "MyBool".into(),
            kind: TypeDefKind::Newtype,
            constructors: Box::new([CtorDefInfo {
                name: "MyBool".into(),
                type_name: "MyBool".into(),
                field_names: Box::new([None]),
                field_type_descs: Box::new([bool_desc]),
                field_type_names: Box::new([Some("bool".into())]),
                is_newtype: true,
                return_type_name: None,
                return_type_node: None,
                field_type_nodes: Box::new([]),
            }]),
            type_params: Box::new([]),
            target_type_name: Some("bool".into()),
            target_type_desc: Some(bool_desc),
        };
        assert!(sr.put_type_def(newtype_def));
        let td = resolve_named_type_resolved("MyBool", &[], &mut sr);
        assert_eq!(td.type_id, 17); // bool
    }

    #[test]
    fn chan_type_from_type_name_builtins_and_user() {
        let mut sr = SemaResult::new();
        assert_eq!(chan_type_from_type_name("i32", &mut sr).type_id, 3);
        assert_eq!(chan_type_from_type_name("void", &mut sr).type_id, 21);
        assert_eq!(chan_type_from_type_name("str", &mut sr).type_id, 19);
        let td = chan_type_from_type_name("Foo", &mut sr);
        assert!(td.type_id >= 22);
        assert_eq!(td.type_name, "Foo");
        // T? → 递归去 ?
        let td = chan_type_from_type_name("i32?", &mut sr);
        assert_eq!(td.type_id, 3);
    }

    #[test]
    fn chan_type_from_type_id_lookup() {
        let mut sr = SemaResult::new();
        assert_eq!(chan_type_from_type_id(&mut sr, 3).type_id, 3);
        assert_eq!(chan_type_from_type_id(&mut sr, 19).type_id, 19);
        // type_id=0 → "unknown"
        assert_eq!(chan_type_from_type_id(&mut sr, 0).type_name, "unknown");
        // 未注册的动态 type_id → "unknown"
        assert_eq!(chan_type_from_type_id(&mut sr, 99).type_name, "unknown");
        // 注册后的动态 type_id 可查到
        let foo_td = sr.get_or_create_ref_desc("Foo");
        sr.type_descriptors.push(foo_td);
        let td = chan_type_from_type_id(&mut sr, foo_td.type_id);
        assert_eq!(td.type_name, "Foo");
    }

    #[test]
    fn from_concrete_type_scalars_and_composite() {
        let mut arena = TypeArena::new();
        let mut sr = SemaResult::new();
        let i = arena.make(ConcreteType::I32);
        assert_eq!(from_concrete_type(i, &arena, &mut sr).unwrap().type_id, 3);
        let b = arena.make(ConcreteType::Bool);
        assert_eq!(from_concrete_type(b, &arena, &mut sr).unwrap().type_id, 17);
        // ADT → 具名描述符
        let opt = arena.make(ConcreteType::Adt {
            name: "Option".into(),
            type_args: Box::new([i]),
        });
        let td = from_concrete_type(opt, &arena, &mut sr).unwrap();
        assert_eq!(td.type_name, "Option");
        // Nullable<i32> → 递归到 i32
        let nul = arena.make(ConcreteType::Nullable(i));
        assert_eq!(from_concrete_type(nul, &arena, &mut sr).unwrap().type_id, 3);
        // TypeVar → None
        let v = arena.fresh_type_var();
        assert!(from_concrete_type(v, &arena, &mut sr).is_none());
        // Never → None
        let n = arena.make(ConcreteType::Never);
        assert!(from_concrete_type(n, &arena, &mut sr).is_none());
    }

    #[test]
    fn register_builtin_type_descriptors_all_21() {
        let mut sr = SemaResult::new();
        register_builtin_type_descriptors(&mut sr);
        assert_eq!(sr.type_descriptors.len(), 21);
        for tid in 1..=21u16 {
            assert!(
                sr.type_descriptors.iter().any(|td| td.type_id == tid),
                "type_id {} not registered",
                tid
            );
        }
        // 重复注册不增加
        register_builtin_type_descriptors(&mut sr);
        assert_eq!(sr.type_descriptors.len(), 21);
    }

    // ── chan_type_from_type_node_bound (TypeBindingContext) ──

    struct MockBindingCtx {
        bindings: HashMap<String, BindingTarget>,
    }

    impl TypeBindingContext for MockBindingCtx {
        fn lookup(&self, name: &str) -> Option<BindingTarget> {
            self.bindings.get(name).copied()
        }
    }

    #[test]
    fn chan_type_from_type_node_bound_with_ctx() {
        let ast = make_ast_with_types();
        let mut sr = SemaResult::new();
        let i64_desc = lookup_by_type_id(4).unwrap();
        let ctx = MockBindingCtx {
            bindings: std::iter::once((
                "T".to_string(),
                BindingTarget { type_desc: i64_desc },
            ))
            .collect(),
        };
        let td = chan_type_from_type_node_bound(
            Some(TypeId(9)),
            &[],
            Some(&ctx),
            &ast,
            &mut sr,
        )
        .unwrap();
        assert_eq!(td.type_id, 4); // T → 绑定到 i64
    }

    #[test]
    fn chan_type_from_type_node_bound_no_ctx_fallback() {
        let ast = make_ast_with_types();
        let mut sr = SemaResult::new();
        // T 无 ctx → 创建 "T" 具名描述符
        let td =
            chan_type_from_type_node_bound(Some(TypeId(9)), &[], None, &ast, &mut sr).unwrap();
        assert_eq!(td.type_name, "T");
        // i32 无 ctx → 内置标量
        let td =
            chan_type_from_type_node_bound(Some(TypeId(0)), &[], None, &ast, &mut sr).unwrap();
        assert_eq!(td.type_id, 3);
    }

    // ── phase3a: InferContext + TypeBindingStack + SelfBindingStack ──

    #[test]
    fn type_binding_stack_basic() {
        let mut stack = TypeBindingStack::new();
        assert_eq!(stack.depth(), 0);
        assert!(stack.lookup("T").is_none());

        stack.push();
        stack.insert_top("T", TypeHandle(0));
        assert_eq!(stack.depth(), 1);
        assert_eq!(stack.lookup("T"), Some(TypeHandle(0)));

        // 内层 shadowing
        stack.push();
        stack.insert_top("T", TypeHandle(1));
        assert_eq!(stack.lookup("T"), Some(TypeHandle(1)));

        stack.pop();
        assert_eq!(stack.lookup("T"), Some(TypeHandle(0)));
        stack.pop();
        assert!(stack.lookup("T").is_none());
    }

    #[test]
    fn self_binding_stack_basic() {
        let mut stack = SelfBindingStack::new();
        assert!(stack.current().is_none());

        stack.push(TypeHandle(0));
        assert_eq!(stack.current(), Some(TypeHandle(0)));
        assert_eq!(stack.depth(), 1);

        stack.push(TypeHandle(1));
        assert_eq!(stack.current(), Some(TypeHandle(1)));

        stack.pop();
        assert_eq!(stack.current(), Some(TypeHandle(0)));
        stack.pop();
        assert!(stack.current().is_none());
    }

    #[test]
    fn infer_context_type_bindings() {
        let mut arena = TypeArena::new();
        let mut sr = SemaResult::new();
        let mut ctx = InferContext::new(&mut arena, &mut sr);

        ctx.push_type_bindings(&[("T",), ("U",)]);
        assert_eq!(ctx.type_binding_stack.depth(), 1);
        let t_var = ctx.lookup_type_binding("T").unwrap();
        let _u_var = ctx.lookup_type_binding("U").unwrap();
        // T/U 应为 rigid TypeVar
        assert!(matches!(
            ctx.arena.get(ctx.arena.resolve(t_var)),
            ConcreteType::TypeVar(_)
        ));
        ctx.pop_type_bindings();
        assert!(ctx.lookup_type_binding("T").is_none());
    }

    #[test]
    fn infer_context_self_type_binding() {
        let mut arena = TypeArena::new();
        let mut sr = SemaResult::new();
        let mut ctx = InferContext::new(&mut arena, &mut sr);

        // 无 Self 绑定时
        assert!(ctx.current_self_type().is_none());

        // 模拟进入 impl List<T> 块
        ctx.push_type_bindings(&[("T",)]);
        let t_var = ctx.lookup_type_binding("T").unwrap();
        let list_ty = ctx.arena.make(ConcreteType::Adt {
            name: "List".into(),
            type_args: Box::new([t_var]),
        });
        ctx.push_self_type(list_ty);

        let self_ty = ctx.current_self_type().unwrap();
        assert!(matches!(
            ctx.arena.get(self_ty),
            ConcreteType::Adt { name, .. } if name.as_ref() == "List"
        ));

        ctx.pop_self_type();
        ctx.pop_type_bindings();
        assert!(ctx.current_self_type().is_none());
    }

    // ── phase3b: self 参数解析 ──

    /// 构建含 self 相关 TypeNode 的 AstArena。
    /// [0] SelfType  [1] RefType<SelfType>  [2] Named("i32")
    fn make_ast_with_self_types() -> AstArena<'static> {
        let mut ast = AstArena::new();
        ast.alloc_type(Span::new(1, 1), TypeNode::SelfType); // [0]
        let self_ty = ast.alloc_type(Span::new(1, 5), TypeNode::SelfType); // [1] inner
        ast.alloc_type(Span::new(1, 1), TypeNode::RefType { inner: self_ty }); // [2]
        ast.alloc_type(Span::new(1, 1), TypeNode::Named { name: "i32" }); // [3]
        ast
    }

    #[test]
    fn infer_self_param_in_type_block() {
        let mut arena = TypeArena::new();
        let mut sr = SemaResult::new();
        let ast = make_ast_with_self_types();

        // 模拟进入 type 块：Self = Foo
        let foo_ty = arena.make(ConcreteType::Adt {
            name: "Foo".into(),
            type_args: Box::new([]),
        });
        let mut ctx = InferContext::new(&mut arena, &mut sr);
        ctx.push_self_type(foo_ty);

        // self（SelfType）→ 返回 Self = Foo
        let ty = ctx.infer_self_param(Some(TypeId(0)), &ast);
        assert_eq!(ctx.arena.get(ty), &ConcreteType::Adt { name: "Foo".into(), type_args: Box::new([]) });

        // &self（RefType<SelfType>）→ 返回 Ref<Foo>
        let ty = ctx.infer_self_param(Some(TypeId(2)), &ast);
        assert!(matches!(ctx.arena.get(ty), ConcreteType::Ref { is_raw: false, .. }));
    }

    #[test]
    fn infer_self_param_no_scope_error() {
        let mut arena = TypeArena::new();
        let mut sr = SemaResult::new();
        let ast = make_ast_with_self_types();
        let mut ctx = InferContext::new(&mut arena, &mut sr);

        // 无 Self 绑定 → 报错并返回 fresh_type_var
        let ty = ctx.infer_self_param(Some(TypeId(0)), &ast);
        assert!(matches!(
            ctx.arena.get(ctx.arena.resolve(ty)),
            ConcreteType::TypeVar(_)
        ));
        assert!(!sr.errors.is_empty());
        assert!(sr.errors[0].message.contains("requires enclosing type or trait block"));
    }

    #[test]
    fn infer_self_param_explicit_annotation_error() {
        let mut arena = TypeArena::new();
        let mut sr = SemaResult::new();
        let ast = make_ast_with_self_types();
        let foo_ty = arena.make(ConcreteType::Adt {
            name: "Foo".into(),
            type_args: Box::new([]),
        });
        let mut ctx = InferContext::new(&mut arena, &mut sr);
        ctx.push_self_type(foo_ty);

        // self: i32（显式注解）→ 报错
        let ty = ctx.infer_self_param(Some(TypeId(3)), &ast);
        assert!(matches!(
            ctx.arena.get(ctx.arena.resolve(ty)),
            ConcreteType::TypeVar(_)
        ));
        assert!(sr.errors.iter().any(|e| e.message.contains("does not allow explicit type annotation")));
    }

    #[test]
    fn check_top_level_self_param_rejects_self() {
        let mut arena = TypeArena::new();
        let mut sr = SemaResult::new();
        {
            let mut ctx = InferContext::new(&mut arena, &mut sr);
            ctx.check_top_level_self_param("self");
        }
        assert!(!sr.errors.is_empty());
        assert!(sr.errors[0].message.contains("not allowed in top-level function"));

        sr.errors.clear();
        {
            let mut ctx = InferContext::new(&mut arena, &mut sr);
            ctx.check_top_level_self_param("other");
        }
        assert!(sr.errors.is_empty());
    }

    // ── phase3c: 泛型调用推导 ──

    #[test]
    fn infer_call_type_args_basic() {
        let mut arena = TypeArena::new();
        let mut sr = SemaResult::new();
        let mut ctx = InferContext::new(&mut arena, &mut sr);

        // fn id<T>(x: T) -> T，调用 id(42)
        let i32_ty = ctx.arena.make(ConcreteType::I32);
        let t_param = ctx.arena.fresh_rigid_var(); // 形参 T 的类型（rigid var）
        let type_args = ctx.infer_call_type_args(&[t_param], &[t_param], &[i32_ty]).unwrap();
        assert_eq!(type_args.len(), 1);
        // T 应被求解为 i32
        let resolved = ctx.arena.resolve(type_args[0]);
        assert_eq!(ctx.arena.get(resolved), &ConcreteType::I32);
    }

    #[test]
    fn infer_call_type_args_non_generic() {
        let mut arena = TypeArena::new();
        let mut sr = SemaResult::new();
        let mut ctx = InferContext::new(&mut arena, &mut sr);

        // 非泛型函数 → 返回 None
        let i32_ty = ctx.arena.make(ConcreteType::I32);
        let result = ctx.infer_call_type_args(&[], &[i32_ty], &[i32_ty]);
        assert!(result.is_none());
    }

    #[test]
    fn infer_call_type_args_unsolved_keeps_var() {
        let mut arena = TypeArena::new();
        let mut sr = SemaResult::new();
        let mut ctx = InferContext::new(&mut arena, &mut sr);

        // fn first<T>(arr: [T]) -> T，调用 first([])
        // T 无法从空数组推导 → 保持未绑定 TypeVar（延迟求解）
        let t_param = ctx.arena.fresh_rigid_var();
        let arr_ty = ctx.arena.make(ConcreteType::Array {
            element_type: t_param,
            size: None,
        });
        let fresh_elem = ctx.arena.fresh_type_var();
        let empty_arr = ctx.arena.make(ConcreteType::Array {
            element_type: fresh_elem,
            size: None,
        });
        let type_args = ctx
            .infer_call_type_args(&[t_param], &[arr_ty], &[empty_arr])
            .unwrap();
        // T 仍为 TypeVar（未求解）
        let resolved = ctx.arena.resolve(type_args[0]);
        assert!(matches!(ctx.arena.get(resolved), ConcreteType::TypeVar(_)));
    }

    // ── v2 收敛: peer_type_binary（替代 literal_promotion）──

    #[test]
    fn peer_type_binary_literal_to_var() {
        let mut arena = TypeArena::new();
        let i32_ty = arena.make(ConcreteType::I32);
        let i64_ty = arena.make(ConcreteType::I64);

        // 42 + y（y: i64）→ 提升到 i64
        let result = peer_type_binary(&mut arena, i32_ty, i64_ty, true, false);
        assert_eq!(arena.get(result), &ConcreteType::I64);

        // y + 42（y: i64）→ 提升到 i64
        let result = peer_type_binary(&mut arena, i64_ty, i32_ty, false, true);
        assert_eq!(arena.get(result), &ConcreteType::I64);
    }

    #[test]
    fn peer_type_binary_both_literal_widest() {
        let mut arena = TypeArena::new();
        let i32_ty = arena.make(ConcreteType::I32);
        let i64_ty = arena.make(ConcreteType::I64);

        // 42 + 3（两侧都是字面量）→ peer_type 取最宽 i64
        let result = peer_type_binary(&mut arena, i32_ty, i64_ty, true, true);
        assert_eq!(arena.get(result), &ConcreteType::I64);
    }

    #[test]
    fn peer_type_binary_both_var_widest() {
        let mut arena = TypeArena::new();
        let i32_ty = arena.make(ConcreteType::I32);
        let i64_ty = arena.make(ConcreteType::I64);

        // a + b（两侧都是变量）→ peer_type 取最宽 i64
        // v2 语义变更：旧 literal_promotion 返回左操作数 i32，
        // 新 peer_type_binary 返回最宽 i64（更合理的 join 语义）
        let result = peer_type_binary(&mut arena, i32_ty, i64_ty, false, false);
        assert_eq!(arena.get(result), &ConcreteType::I64);
    }

    // ── phase3e: GADT 推断 ──

    /// 构建含 Option<T> 构造器的 SemaResult（用于 GADT 测试）。
    /// Option 有两个构造器：Some(T)、None，type_params = ["T"]
    fn make_sema_with_option_ctors() -> SemaResult {
        let mut sr = SemaResult::new();
        let option_def = TypeDefInfo {
            name: "Option".into(),
            kind: TypeDefKind::Adt,
            constructors: Box::new([
                CtorDefInfo {
                    name: "Some".into(),
                    type_name: "Option".into(),
                    field_names: Box::new([Some("value".into())]),
                    field_type_descs: Box::new([]),
                    field_type_names: Box::new([Some("T".into())]),
                    is_newtype: false,
                    return_type_name: None,
                    return_type_node: None,
                    field_type_nodes: Box::new([None]),
                },
                CtorDefInfo {
                    name: "None".into(),
                    type_name: "Option".into(),
                    field_names: Box::new([]),
                    field_type_descs: Box::new([]),
                    field_type_names: Box::new([]),
                    is_newtype: false,
                    return_type_name: None,
                    return_type_node: None,
                    field_type_nodes: Box::new([]),
                },
            ]),
            type_params: Box::new(["T".into()]),
            target_type_name: None,
            target_type_desc: None,
        };
        sr.put_type_def(option_def);
        sr
    }

    #[test]
    fn refine_constructor_pattern_unregistered_ctor() {
        let mut arena = TypeArena::new();
        let mut sr = make_sema_with_option_ctors();
        let ast = AstArena::new();
        let mut ctx = InferContext::new(&mut arena, &mut sr);

        let i32_ty = ctx.arena.make(ConcreteType::I32);
        let expected = ctx.arena.make(ConcreteType::Adt {
            name: "Option".into(),
            type_args: Box::new([i32_ty]),
        });

        // 未注册的构造器 → 返回 false
        let result = ctx.refine_constructor_pattern("Unknown", &[], expected, &ast);
        assert!(!result);
    }

    #[test]
    fn refine_constructor_pattern_none_ctor() {
        let mut arena = TypeArena::new();
        let mut sr = make_sema_with_option_ctors();
        let ast = AstArena::new();
        let mut ctx = InferContext::new(&mut arena, &mut sr);

        // expected = Option<i32>
        let i32_ty = ctx.arena.make(ConcreteType::I32);
        let expected = ctx.arena.make(ConcreteType::Adt {
            name: "Option".into(),
            type_args: Box::new([i32_ty]),
        });

        // None 构造器（无子模式）→ unify(Option, Option<i32>)，返回 true
        let result = ctx.refine_constructor_pattern("None", &[], expected, &ast);
        assert!(result);
    }

    #[test]
    fn refine_constructor_pattern_throw_error_newtype() {
        let mut arena = TypeArena::new();
        let mut sr = SemaResult::new();
        // 注册一个 error_newtype 构造器
        let error_def = TypeDefInfo {
            name: "MyError".into(),
            kind: TypeDefKind::ErrorNewtype,
            constructors: Box::new([CtorDefInfo {
                name: "MyError".into(),
                type_name: "MyError".into(),
                field_names: Box::new([Some("message".into())]),
                field_type_descs: Box::new([]),
                field_type_names: Box::new([Some("str".into())]),
                is_newtype: true,
                return_type_name: None,
                return_type_node: None,
                field_type_nodes: Box::new([None]),
            }]),
            type_params: Box::new([]),
            target_type_name: None,
            target_type_desc: None,
        };
        sr.put_type_def(error_def);
        let ast = AstArena::new();
        let mut ctx = InferContext::new(&mut arena, &mut sr);

        // expected = Throw<i32, MyError>
        let i32_ty = ctx.arena.make(ConcreteType::I32);
        let my_error_ty = ctx.arena.make(ConcreteType::Adt {
            name: "MyError".into(),
            type_args: Box::new([]),
        });
        let throw_ty = ctx.arena.make(ConcreteType::Throw {
            value_type: i32_ty,
            error_type: my_error_ty,
        });

        // MyError 构造器匹配 Throw 类型 → 走 error_newtype 特例，返回 true
        let pat = PatternId(0);
        let result = ctx.refine_constructor_pattern("MyError", &[pat], throw_ty, &ast);
        assert!(result);
    }

    // ── phase4a: populate ──

    /// 构建 SimpleAdd 函数声明的 AST Module 用于 populate 测试。
    /// fn add(a: i32, b: i32) -> i32 { a + b }
    fn make_add_module() -> crate::Ast::Module<'static> {
        use crate::Ast::*;
        let mut arena = AstArena::new();

        // 分配类型节点：i32, i32, i32
        let i32_ty_a = arena.alloc_type(Span::new(1, 10), TypeNode::Named { name: "i32" });
        let i32_ty_b = arena.alloc_type(Span::new(1, 18), TypeNode::Named { name: "i32" });
        let i32_ty_ret = arena.alloc_type(Span::new(1, 26), TypeNode::Named { name: "i32" });

        // 分配 body 表达式（占位：Ident "a"，实际 add 的 body 不影响 populate）
        let body = arena.alloc_expr(Span::new(1, 30), Expr::Ident("a"));

        let add_decl = Spanned {
            span: Span::new(1, 1),
            node: Decl::FunDecl {
                visibility: Visibility::Public,
                name: "add",
                type_params: Vec::new(),
                params: vec![
                    Param { name: "a", type_annotation: Some(i32_ty_a) },
                    Param { name: "b", type_annotation: Some(i32_ty_b) },
                ],
                return_type: Some(i32_ty_ret),
                bounds: Vec::new(),
                body,
                is_async: false,
                is_entry: false,
                attributes: Vec::new(),
                extern_c_body: None,
            },
        };

        Module {
            name: "test",
            source_path: None,
            arena,
            declarations: vec![add_decl],
        }
    }

    #[test]
    fn populate_fun_decl_to_func_sig() {
        let module = make_add_module();
        let mut sr = SemaResult::new();

        let ok = populate_module(&mut sr, &module);
        assert!(ok);

        // 应有 1 个 func_sig
        let sig = sr.get_func_sig("add").expect("func sig add should exist");
        assert_eq!(sig.name.as_ref(), "add");
        assert_eq!(sig.param_type_descs.len(), 2);
        assert_eq!(sig.param_type_descs[0].type_id, 3); // i32 type_id=3
        assert_eq!(sig.param_type_descs[1].type_id, 3);
        assert_eq!(sig.return_type_desc.type_id, 3);
        assert!(!sig.is_async);
        assert!(!sig.is_throwing);
        assert!(!sig.return_is_ref);
        assert_eq!(sig.type_params.len(), 0);
    }

    /// 构建 Option<T> ADT 类型声明的 AST Module。
    /// type Option<T> = Some(T) | None
    fn make_option_module() -> crate::Ast::Module<'static> {
        use crate::Ast::*;
        let mut arena = AstArena::new();

        // T 类型参数
        // 构造器 Some 的字段类型 T（Named "T"）
        let t_ty = arena.alloc_type(Span::new(1, 20), TypeNode::Named { name: "T" });

        let option_decl = Spanned {
            span: Span::new(1, 1),
            node: Decl::TypeDecl {
                visibility: Visibility::Public,
                name: "Option",
                type_params: vec![TypeParam { name: "T", kind: None, bounds: Vec::new() }],
                implemented_traits: Vec::new(),
                type_constraints: Vec::new(),
                def: TypeDef::Adt {
                    constructors: vec![
                        ConstructorDef {
                            name: "Some",
                            fields: vec![ConstructorField { name: None, ty: t_ty }],
                            return_type: None,
                        },
                        ConstructorDef {
                            name: "None",
                            fields: Vec::new(),
                            return_type: None,
                        },
                    ],
                },
                methods: Vec::new(),
            },
        };

        Module {
            name: "test",
            source_path: None,
            arena,
            declarations: vec![option_decl],
        }
    }

    #[test]
    fn populate_adt_type_decl() {
        let module = make_option_module();
        let mut sr = SemaResult::new();

        let ok = populate_module(&mut sr, &module);
        assert!(ok);

        // 应有 Option 类型定义
        let td = sr.get_type_def("Option").expect("type def Option should exist");
        assert_eq!(td.name.as_ref(), "Option");
        assert_eq!(td.kind, TypeDefKind::Adt);
        assert_eq!(td.constructors.len(), 2);
        assert_eq!(td.constructors[0].name.as_ref(), "Some");
        assert_eq!(td.constructors[1].name.as_ref(), "None");
        assert_eq!(td.type_params.len(), 1);
        assert_eq!(td.type_params[0].as_ref(), "T");

        // Some 构造器应有 1 个字段
        assert_eq!(td.constructors[0].field_names.len(), 1);
        assert!(td.constructors[0].field_names[0].is_none()); // 位置字段

        // None 构造器应有 0 个字段
        assert_eq!(td.constructors[1].field_names.len(), 0);
    }

    /// 构建 trait 声明的 AST Module。
    /// trait Show { fn show(self) -> str }
    fn make_trait_module() -> crate::Ast::Module<'static> {
        use crate::Ast::*;
        let mut arena = AstArena::new();

        let str_ty = arena.alloc_type(Span::new(1, 30), TypeNode::Named { name: "str" });
        let self_ty = arena.alloc_type(Span::new(1, 20), TypeNode::SelfType);

        let trait_decl = Spanned {
            span: Span::new(1, 1),
            node: Decl::TraitDecl {
                visibility: Visibility::Public,
                name: "Show",
                type_params: Vec::new(),
                parents: Vec::new(),
                associated_types: Vec::new(),
                methods: vec![MethodDecl {
                    name: "show",
                    type_params: Vec::new(),
                    params: vec![Param { name: "self", type_annotation: Some(self_ty) }],
                    return_type: Some(str_ty),
                    body: None,
                    is_override: false,
                    delegate: None,
                    visibility: Visibility::Public,
                    is_async: false,
                }],
            },
        };

        Module {
            name: "test",
            source_path: None,
            arena,
            declarations: vec![trait_decl],
        }
    }

    #[test]
    fn populate_trait_decl() {
        let module = make_trait_module();
        let mut sr = SemaResult::new();

        let ok = populate_module(&mut sr, &module);
        assert!(ok);

        // 应有 Show trait 定义
        let td = sr.get_trait_def("Show").expect("trait def Show should exist");
        assert_eq!(td.name.as_ref(), "Show");
        assert_eq!(td.methods.len(), 1);
        assert_eq!(td.methods[0].name.as_ref(), "show");
        assert_eq!(td.methods[0].param_count, 1);
        assert_eq!(td.methods[0].return_type_desc.type_id, 19); // str type_id=19
        assert!(!td.methods[0].has_body);
    }

    // ── phase5: subtype_check ──

    #[test]
    fn subtype_reflexive_same_type() {
        let mut arena = TypeArena::new();
        let a = arena.make(ConcreteType::I32);
        let b = arena.make(ConcreteType::I32);
        assert!(is_subtype(&arena, a, b));
        assert!(is_subtype(&arena, b, a));
    }

    #[test]
    fn subtype_unrelated_scalars_false() {
        let mut arena = TypeArena::new();
        let i = arena.make(ConcreteType::I32);
        let s = arena.make(ConcreteType::Str);
        assert!(!is_subtype(&arena, i, s));
        assert!(!is_subtype(&arena, s, i));
    }

    #[test]
    fn subtype_null_to_nullable() {
        let mut arena = TypeArena::new();
        let null = arena.make(ConcreteType::Null);
        let b = arena.make(ConcreteType::Bool);
        let nb = arena.make(ConcreteType::Nullable(b));
        // null 字面量是任意 nullable 的子类型
        assert!(is_subtype(&arena, null, nb));
        // 反向不成立
        assert!(!is_subtype(&arena, nb, null));
    }

    #[test]
    fn subtype_t_to_nullable_t() {
        let mut arena = TypeArena::new();
        let i = arena.make(ConcreteType::I32);
        let ni = arena.make(ConcreteType::Nullable(i));
        // T 是 Nullable<T> 的子类型（内层子类型关系）
        assert!(is_subtype(&arena, i, ni));
    }

    #[test]
    fn subtype_record_width_subtyping() {
        let mut arena = TypeArena::new();
        let i = arena.make(ConcreteType::I32);
        let b = arena.make(ConcreteType::Bool);
        // sub: { x: i32, y: bool }  —— 字段更多
        let wide = arena.make(ConcreteType::Record {
            fields: Box::new([
                FieldType { name: Some("x".into()), ty: i },
                FieldType { name: Some("y".into()), ty: b },
            ]),
            name: None,
        });
        // sup: { x: i32 }
        let narrow = arena.make(ConcreteType::Record {
            fields: Box::new([FieldType { name: Some("x".into()), ty: i }]),
            name: None,
        });
        assert!(is_subtype(&arena, wide, narrow));
        // 反向：缺少 y 字段，不是子类型
        assert!(!is_subtype(&arena, narrow, wide));
    }

    #[test]
    fn subtype_record_field_type_mismatch() {
        let mut arena = TypeArena::new();
        let i = arena.make(ConcreteType::I32);
        let s = arena.make(ConcreteType::Str);
        let sub = arena.make(ConcreteType::Record {
            fields: Box::new([FieldType { name: Some("x".into()), ty: s }]),
            name: None,
        });
        let sup = arena.make(ConcreteType::Record {
            fields: Box::new([FieldType { name: Some("x".into()), ty: i }]),
            name: None,
        });
        // 字段类型 str 不是 i32 的子类型
        assert!(!is_subtype(&arena, sub, sup));
    }

    #[test]
    fn subtype_record_missing_named_field() {
        let mut arena = TypeArena::new();
        let i = arena.make(ConcreteType::I32);
        let sub = arena.make(ConcreteType::Record {
            fields: Box::new([FieldType { name: Some("x".into()), ty: i }]),
            name: None,
        });
        let sup = arena.make(ConcreteType::Record {
            fields: Box::new([FieldType { name: Some("z".into()), ty: i }]),
            name: None,
        });
        // 字段名不匹配（z 缺失）
        assert!(!is_subtype(&arena, sub, sup));
    }

    #[test]
    fn subtype_adt_same_name() {
        let mut arena = TypeArena::new();
        let i = arena.make(ConcreteType::I32);
        let a1 = arena.make(ConcreteType::Adt {
            name: "Option".into(),
            type_args: Box::new([i]),
        });
        let a2 = arena.make(ConcreteType::Adt {
            name: "Option".into(),
            type_args: Box::new([]),
        });
        // 同名 ADT 视为子类型（参数由单态化保证）
        assert!(is_subtype(&arena, a1, a2));
    }

    #[test]
    fn subtype_adt_diff_name_false() {
        let mut arena = TypeArena::new();
        let opt = arena.make(ConcreteType::Adt {
            name: "Option".into(),
            type_args: Box::new([]),
        });
        let res = arena.make(ConcreteType::Adt {
            name: "Result".into(),
            type_args: Box::new([]),
        });
        assert!(!is_subtype(&arena, opt, res));
    }

    #[test]
    fn subtype_throw_both_compatible() {
        let mut arena = TypeArena::new();
        let vi = arena.make(ConcreteType::I32);
        let ei = arena.make(ConcreteType::I64);
        let vj = arena.make(ConcreteType::I32);
        let ej = arena.make(ConcreteType::I64);
        let t1 = arena.make(ConcreteType::Throw {
            value_type: vi,
            error_type: ei,
        });
        let t2 = arena.make(ConcreteType::Throw {
            value_type: vj,
            error_type: ej,
        });
        assert!(is_subtype(&arena, t1, t2));
    }

    #[test]
    fn subtype_throw_value_mismatch_false() {
        let mut arena = TypeArena::new();
        let vi = arena.make(ConcreteType::I32);
        let ei = arena.make(ConcreteType::I64);
        let vs = arena.make(ConcreteType::Str);
        let ej = arena.make(ConcreteType::I64);
        let t1 = arena.make(ConcreteType::Throw {
            value_type: vi,
            error_type: ei,
        });
        let t2 = arena.make(ConcreteType::Throw {
            value_type: vs,
            error_type: ej,
        });
        // 值类型 i32 不是 str 的子类型
        assert!(!is_subtype(&arena, t1, t2));
    }

    #[test]
    fn subtype_throw_error_mismatch_false() {
        let mut arena = TypeArena::new();
        let vi = arena.make(ConcreteType::I32);
        let ei = arena.make(ConcreteType::I64);
        let vj = arena.make(ConcreteType::I32);
        let es = arena.make(ConcreteType::Str);
        let t1 = arena.make(ConcreteType::Throw {
            value_type: vi,
            error_type: ei,
        });
        let t2 = arena.make(ConcreteType::Throw {
            value_type: vj,
            error_type: es,
        });
        // 错误类型 i64 不是 str 的子类型
        assert!(!is_subtype(&arena, t1, t2));
    }

    #[test]
    fn subtype_throw_vs_non_throw_false() {
        let mut arena = TypeArena::new();
        let vi = arena.make(ConcreteType::I32);
        let ei = arena.make(ConcreteType::I64);
        let t = arena.make(ConcreteType::Throw {
            value_type: vi,
            error_type: ei,
        });
        let i = arena.make(ConcreteType::I32);
        // Throw 不是普通类型的子类型
        assert!(!is_subtype(&arena, t, i));
    }

    #[test]
    fn can_coerce_numeric_int_widening() {
        let mut arena = TypeArena::new();
        let i8t = arena.make(ConcreteType::I8);
        let i32t = arena.make(ConcreteType::I32);
        let i64t = arena.make(ConcreteType::I64);
        // 同秩同符号 OK
        assert!(can_coerce_numeric(&arena, i8t, i8t));
        // 宽化 OK
        assert!(can_coerce_numeric(&arena, i32t, i8t));
        // 窄化拒绝
        assert!(!can_coerce_numeric(&arena, i8t, i32t));
        assert!(!can_coerce_numeric(&arena, i8t, i64t));
    }

    #[test]
    fn can_coerce_numeric_signed_to_unsigned() {
        let mut arena = TypeArena::new();
        let i32t = arena.make(ConcreteType::I32);
        let u32t = arena.make(ConcreteType::U32);
        let u64t = arena.make(ConcreteType::U64);
        // 有符号 -> 同宽无符号：需目标秩严格更大（u32 同秩拒绝）
        assert!(!can_coerce_numeric(&arena, u32t, i32t));
        // i32 -> u64：目标秩更大 OK
        assert!(can_coerce_numeric(&arena, u64t, i32t));
    }

    #[test]
    fn can_coerce_numeric_int_to_float() {
        let mut arena = TypeArena::new();
        let i32t = arena.make(ConcreteType::I32);
        let f64t = arena.make(ConcreteType::F64);
        let f32t = arena.make(ConcreteType::F32);
        // 整型 -> 浮点 允许
        assert!(can_coerce_numeric(&arena, f64t, i32t));
        assert!(can_coerce_numeric(&arena, f32t, i32t));
    }

    #[test]
    fn can_coerce_numeric_float_widening() {
        let mut arena = TypeArena::new();
        let f32t = arena.make(ConcreteType::F32);
        let f64t = arena.make(ConcreteType::F64);
        // 浮点宽化 OK
        assert!(can_coerce_numeric(&arena, f64t, f32t));
        // 浮点窄化拒绝
        assert!(!can_coerce_numeric(&arena, f32t, f64t));
    }

    #[test]
    fn int_and_float_type_rank_coverage() {
        assert_eq!(int_type_rank(&ConcreteType::I8), 1);
        assert_eq!(int_type_rank(&ConcreteType::U64), 4);
        assert_eq!(int_type_rank(&ConcreteType::I128), 5);
        assert_eq!(int_type_rank(&ConcreteType::Isize), 4);
        assert_eq!(int_type_rank(&ConcreteType::Str), 0);
        assert_eq!(float_type_rank(&ConcreteType::F16), 1);
        assert_eq!(float_type_rank(&ConcreteType::F64), 3);
        assert_eq!(float_type_rank(&ConcreteType::F128), 4);
        assert_eq!(float_type_rank(&ConcreteType::I32), 0);
    }

    #[test]
    fn is_error_subtype_err_target() {
        let mut sr = SemaResult::new();
        sr.put_type_def(TypeDefInfo {
            name: "MyErr".into(),
            kind: TypeDefKind::ErrorNewtype,
            constructors: Box::new([]),
            type_params: Box::new([]),
            target_type_name: None,
            target_type_desc: None,
        });
        // error_newtype 是 Err trait 的子类型
        assert!(is_error_subtype(&sr, "MyErr", "Err"));
        // 非 Err 目标不成立
        assert!(!is_error_subtype(&sr, "MyErr", "Show"));
        // 未注册类型不成立
        assert!(!is_error_subtype(&sr, "Nope", "Err"));
    }

    #[test]
    fn is_error_subtype_non_error_newtype() {
        let mut sr = SemaResult::new();
        sr.put_type_def(TypeDefInfo {
            name: "PlainAdt".into(),
            kind: TypeDefKind::Adt,
            constructors: Box::new([]),
            type_params: Box::new([]),
            target_type_name: None,
            target_type_desc: None,
        });
        // 普通 ADT 不是 Err 的子类型
        assert!(!is_error_subtype(&sr, "PlainAdt", "Err"));
    }

    #[test]
    fn is_throw_subtype_helper() {
        let mut arena = TypeArena::new();
        let vi = arena.make(ConcreteType::I32);
        let vj = arena.make(ConcreteType::I32);
        let ei = arena.make(ConcreteType::I64);
        let ej = arena.make(ConcreteType::I64);
        assert!(is_throw_subtype(&arena, vi, ei, vj, ej));
        let vs = arena.make(ConcreteType::Str);
        assert!(!is_throw_subtype(&arena, vi, ei, vs, ej));
    }

    #[test]
    fn is_trait_structural_subtype_coverage() {
        let mut sr = SemaResult::new();
        sr.put_trait_def(TraitDefInfo {
            name: "Sub".into(),
            methods: Box::new([
                TraitMethodSig {
                    name: "show".into(),
                    param_count: 0,
                    return_type_desc: &STR_DESC,
                    is_async: false,
                    has_body: false,
                },
                TraitMethodSig {
                    name: "len".into(),
                    param_count: 0,
                    return_type_desc: &I32_DESC,
                    is_async: false,
                    has_body: false,
                },
            ]),
        });
        sr.put_trait_def(TraitDefInfo {
            name: "Sup".into(),
            methods: Box::new([TraitMethodSig {
                name: "show".into(),
                param_count: 0,
                return_type_desc: &STR_DESC,
                is_async: false,
                has_body: false,
            }]),
        });
        // Sub 覆盖 Sup 的方法 → 子类型
        assert!(is_trait_structural_subtype(&sr, "Sub", "Sup"));
        // Sup 缺少 len → 不是 Sub 的子类型
        assert!(!is_trait_structural_subtype(&sr, "Sup", "Sub"));
        // 未注册 trait
        assert!(!is_trait_structural_subtype(&sr, "Sub", "Missing"));
    }

    // ── phase5: kind_check ──

    #[test]
    fn arity_of_builtin_generic_types() {
        let sr = SemaResult::new();
        assert_eq!(arity_of_type_name(&sr, "Throw"), 2);
        assert_eq!(arity_of_type_name(&sr, "Async"), 1);
        assert_eq!(arity_of_type_name(&sr, "Channel"), 1);
    }

    #[test]
    fn arity_of_scalar_is_zero() {
        let sr = SemaResult::new();
        assert_eq!(arity_of_type_name(&sr, "i32"), 0);
        assert_eq!(arity_of_type_name(&sr, "str"), 0);
        assert_eq!(arity_of_type_name(&sr, "bool"), 0);
        // 未注册的裸类型名 arity 为 0
        assert_eq!(arity_of_type_name(&sr, "Foo"), 0);
    }

    #[test]
    fn arity_of_user_adt_from_type_params() {
        let mut sr = SemaResult::new();
        sr.put_type_def(TypeDefInfo {
            name: "Option".into(),
            kind: TypeDefKind::Adt,
            constructors: Box::new([]),
            type_params: Box::new(["T".into()]),
            target_type_name: None,
            target_type_desc: None,
        });
        assert_eq!(arity_of_type_name(&sr, "Option"), 1);
    }

    #[test]
    fn check_type_node_named_scalar_ok() {
        let sr = SemaResult::new();
        let mut arena = AstArena::new();
        let node = arena.alloc_type(Span::new(1, 1), TypeNode::Named { name: "i32" });
        let mut errors = Vec::new();
        check_type_node(&sr, &arena, node, &[], &mut errors);
        assert!(errors.is_empty(), "bare scalar should pass kind check");
    }

    #[test]
    fn check_type_node_generic_as_concrete_error() {
        let sr = SemaResult::new();
        let mut arena = AstArena::new();
        // Throw 期望 2 个参数，作为裸 Named 使用应报 kind mismatch
        let node = arena.alloc_type(Span::new(2, 5), TypeNode::Named { name: "Throw" });
        let mut errors = Vec::new();
        check_type_node(&sr, &arena, node, &[], &mut errors);
        assert_eq!(errors.len(), 1);
        assert!(errors[0].message.contains("Throw"));
        assert!(errors[0].message.contains("kind mismatch"));
    }

    #[test]
    fn check_type_node_generic_correct_arity_ok() {
        let sr = SemaResult::new();
        let mut arena = AstArena::new();
        let i32_ty = arena.alloc_type(Span::new(1, 1), TypeNode::Named { name: "i32" });
        let err_ty = arena.alloc_type(Span::new(1, 10), TypeNode::Named { name: "str" });
        // Throw<i32, str> 参数数匹配 → 无错误
        let node = arena.alloc_type(
            Span::new(1, 1),
            TypeNode::Generic {
                name: "Throw",
                args: vec![i32_ty, err_ty],
            },
        );
        let mut errors = Vec::new();
        check_type_node(&sr, &arena, node, &[], &mut errors);
        assert!(errors.is_empty(), "correct-arity generic should pass");
    }

    #[test]
    fn check_type_node_generic_wrong_arity_error() {
        let sr = SemaResult::new();
        let mut arena = AstArena::new();
        let i32_ty = arena.alloc_type(Span::new(1, 1), TypeNode::Named { name: "i32" });
        // Throw<i32> 只给 1 个参数（期望 2）→ 报错
        let node = arena.alloc_type(
            Span::new(1, 1),
            TypeNode::Generic {
                name: "Throw",
                args: vec![i32_ty],
            },
        );
        let mut errors = Vec::new();
        check_type_node(&sr, &arena, node, &[], &mut errors);
        assert_eq!(errors.len(), 1);
        assert!(errors[0].message.contains("expects 2"));
    }

    #[test]
    fn check_type_node_type_param_allowed() {
        let sr = SemaResult::new();
        let mut arena = AstArena::new();
        // T 作为类型参数，即使未注册也不报错
        let node = arena.alloc_type(Span::new(1, 1), TypeNode::Named { name: "T" });
        let mut errors = Vec::new();
        check_type_node(&sr, &arena, node, &["T"], &mut errors);
        assert!(errors.is_empty(), "type param name should be allowed");
    }

    #[test]
    fn check_type_node_nullable_inner_recursive() {
        let sr = SemaResult::new();
        let mut arena = AstArena::new();
        // i32? → 内层 i32 合法
        let inner = arena.alloc_type(Span::new(1, 1), TypeNode::Named { name: "i32" });
        let node = arena.alloc_type(Span::new(1, 5), TypeNode::Nullable { inner });
        let mut errors = Vec::new();
        check_type_node(&sr, &arena, node, &[], &mut errors);
        assert!(errors.is_empty());
    }

    #[test]
    fn kind_arity_of_type_node_coverage() {
        let sr = SemaResult::new();
        let mut arena = AstArena::new();
        let named = arena.alloc_type(Span::new(1, 1), TypeNode::Named { name: "i32" });
        assert_eq!(kind_arity_of_type_node(&sr, &arena, named), 0);
        let throw_named = arena.alloc_type(Span::new(1, 1), TypeNode::Named { name: "Throw" });
        assert_eq!(kind_arity_of_type_node(&sr, &arena, throw_named), 2);
        let i32_ty = arena.alloc_type(Span::new(1, 1), TypeNode::Named { name: "i32" });
        let partial = arena.alloc_type(
            Span::new(1, 1),
            TypeNode::Generic {
                name: "Throw",
                args: vec![i32_ty],
            },
        );
        // Throw 已提供 1 参数，还差 1
        assert_eq!(kind_arity_of_type_node(&sr, &arena, partial), 1);
    }

    // ── phase5: module_check ──

    #[test]
    fn module_check_satisfies_all() {
        let checker = ModuleChecker::new();
        let provided = [
            MethodSig { name: "show".into(), arity: 1 },
            MethodSig { name: "len".into(), arity: 0 },
        ];
        let required = [MethodSig { name: "show".into(), arity: 1 }];
        let r = checker.structurally_satisfies(&provided, &required);
        assert!(r.ok);
        assert_eq!(r.reason, MatchReason::Ok);
    }

    #[test]
    fn module_check_missing_method() {
        let checker = ModuleChecker::new();
        let provided = [MethodSig { name: "len".into(), arity: 0 }];
        let required = [MethodSig { name: "show".into(), arity: 1 }];
        let r = checker.structurally_satisfies(&provided, &required);
        assert!(!r.ok);
        assert_eq!(r.reason, MatchReason::Missing);
        assert_eq!(r.missing_method.as_deref(), Some("show"));
    }

    #[test]
    fn module_check_arity_mismatch() {
        let checker = ModuleChecker::new();
        let provided = [MethodSig { name: "show".into(), arity: 2 }];
        let required = [MethodSig { name: "show".into(), arity: 1 }];
        let r = checker.structurally_satisfies(&provided, &required);
        assert!(!r.ok);
        assert_eq!(r.reason, MatchReason::ArityMismatch);
        assert_eq!(r.arity_expected, 1);
        assert_eq!(r.arity_got, 2);
    }

    #[test]
    fn module_check_empty_required_ok() {
        let checker = ModuleChecker::new();
        let provided: [MethodSig; 0] = [];
        let required: [MethodSig; 0] = [];
        let r = checker.structurally_satisfies(&provided, &required);
        assert!(r.ok);
    }

    #[test]
    fn module_check_multiple_required_partial_fail() {
        let checker = ModuleChecker::new();
        let provided = [
            MethodSig { name: "a".into(), arity: 0 },
            MethodSig { name: "c".into(), arity: 0 },
        ];
        let required = [
            MethodSig { name: "a".into(), arity: 0 },
            MethodSig { name: "b".into(), arity: 0 },
            MethodSig { name: "c".into(), arity: 0 },
        ];
        let r = checker.structurally_satisfies(&provided, &required);
        assert!(!r.ok);
        assert_eq!(r.reason, MatchReason::Missing);
        assert_eq!(r.missing_method.as_deref(), Some("b"));
    }

    #[test]
    fn match_result_ok_helper() {
        let r = MatchResult::ok();
        assert!(r.ok);
        assert_eq!(r.reason, MatchReason::Ok);
        assert!(r.missing_method.is_none());
    }

    // ── sema v2: ConstraintSolver 测试 ──

    #[test]
    fn solver_equality_basic() {
        let mut arena = TypeArena::new();
        let mut solver = ConstraintSolver::new();
        let v = arena.fresh_type_var();
        let i32_ty = arena.make(ConcreteType::I32);
        solver.add_equality(v, i32_ty);
        assert_eq!(solver.pending_count(), 1);
        solver.solve(&mut arena);
        assert!(!solver.has_errors());
        // TypeVar 应被绑定到 I32
        let resolved = arena.resolve(v);
        assert_eq!(arena.get(resolved), &ConcreteType::I32);
    }

    #[test]
    fn solver_snapshot_rollback() {
        let mut arena = TypeArena::new();
        let mut solver = ConstraintSolver::new();
        let v = arena.fresh_type_var();
        let i32_ty = arena.make(ConcreteType::I32);
        let i64_ty = arena.make(ConcreteType::I64);

        // 初始约束：v = i32
        solver.add_equality(v, i32_ty);
        solver.solve(&mut arena);
        assert_eq!(arena.get(arena.resolve(v)), &ConcreteType::I32);

        // snapshot
        let snap = solver.snapshot();
        // 尝试性约束：v = i64（会失败，因为 v 已绑定 i32）
        solver.add_equality(v, i64_ty);
        solver.solve(&mut arena);
        assert!(solver.has_errors());

        // rollback：撤销错误
        solver.rollback(snap);
        assert!(!solver.has_errors());
        // v 仍为 i32
        assert_eq!(arena.get(arena.resolve(v)), &ConcreteType::I32);
    }

    #[test]
    fn solver_subtype_constraint() {
        let mut arena = TypeArena::new();
        let mut solver = ConstraintSolver::new();
        let i32_ty = arena.make(ConcreteType::I32);
        let i64_ty = arena.make(ConcreteType::I64);
        // i32 <: i64 不是子类型（Glue 无隐式宽化）
        solver.add_subtype(i32_ty, i64_ty);
        solver.solve(&mut arena);
        assert!(solver.has_errors());
    }

    #[test]
    fn solver_subtype_reflexive() {
        let mut arena = TypeArena::new();
        let mut solver = ConstraintSolver::new();
        let i32_ty = arena.make(ConcreteType::I32);
        solver.add_subtype(i32_ty, i32_ty);
        solver.solve(&mut arena);
        assert!(!solver.has_errors());
    }

    // ── sema v2: Peer Type Resolution 测试 ──

    #[test]
    fn peer_type_empty() {
        let mut arena = TypeArena::new();
        let result = peer_type(&mut arena, &[]);
        assert_eq!(arena.get(result), &ConcreteType::Unknown);
    }

    #[test]
    fn peer_type_single() {
        let mut arena = TypeArena::new();
        let i32_ty = arena.make(ConcreteType::I32);
        let result = peer_type(&mut arena, &[i32_ty]);
        assert_eq!(arena.get(arena.resolve(result)), &ConcreteType::I32);
    }

    #[test]
    fn peer_type_numeric_widening_int() {
        let mut arena = TypeArena::new();
        let i32_ty = arena.make(ConcreteType::I32);
        let i64_ty = arena.make(ConcreteType::I64);
        let result = peer_type(&mut arena, &[i32_ty, i64_ty]);
        assert_eq!(arena.get(arena.resolve(result)), &ConcreteType::I64);
    }

    #[test]
    fn peer_type_numeric_float_priority() {
        let mut arena = TypeArena::new();
        let i64_ty = arena.make(ConcreteType::I64);
        let f64_ty = arena.make(ConcreteType::F64);
        let result = peer_type(&mut arena, &[i64_ty, f64_ty]);
        assert_eq!(arena.get(arena.resolve(result)), &ConcreteType::F64);
    }

    #[test]
    fn peer_type_never_filtered() {
        let mut arena = TypeArena::new();
        let i32_ty = arena.make(ConcreteType::I32);
        let never_ty = arena.make(ConcreteType::Never);
        let result = peer_type(&mut arena, &[never_ty, i32_ty]);
        assert_eq!(arena.get(arena.resolve(result)), &ConcreteType::I32);
    }

    #[test]
    fn peer_type_all_never() {
        let mut arena = TypeArena::new();
        let never1 = arena.make(ConcreteType::Never);
        let never2 = arena.make(ConcreteType::Never);
        let result = peer_type(&mut arena, &[never1, never2]);
        assert_eq!(arena.get(arena.resolve(result)), &ConcreteType::Never);
    }

    #[test]
    fn peer_type_nullable_propagation() {
        let mut arena = TypeArena::new();
        let i32_ty = arena.make(ConcreteType::I32);
        let nullable_i32 = arena.make(ConcreteType::Nullable(i32_ty));
        let result = peer_type(&mut arena, &[i32_ty, nullable_i32]);
        // 含 nullable + 非 nullable → Nullable<peer>
        let resolved = arena.get(arena.resolve(result));
        assert!(matches!(resolved, ConcreteType::Nullable(_)));
    }

    #[test]
    fn peer_type_incompatible() {
        let mut arena = TypeArena::new();
        let i32_ty = arena.make(ConcreteType::I32);
        let str_ty = arena.make(ConcreteType::Str);
        let result = peer_type(&mut arena, &[i32_ty, str_ty]);
        assert_eq!(arena.get(arena.resolve(result)), &ConcreteType::Unknown);
    }

    // ── sema v2: FlowContext 测试 ──

    #[test]
    fn flow_context_push_pop() {
        let mut ctx = FlowContext::new();
        assert_eq!(ctx.depth(), 1); // 根 scope

        ctx.push_scope();
        assert_eq!(ctx.depth(), 2);

        let ty = TypeHandle(42); // 占位
        ctx.add_fact(FlowFact {
            path: "x".into(),
            narrowed_ty: ty,
            kind: NarrowKind::NonNull,
        });
        assert_eq!(ctx.lookup_narrowed("x"), Some(ty));

        ctx.pop_scope();
        assert_eq!(ctx.depth(), 1);
        // pop 后 narrow 信息消失
        assert_eq!(ctx.lookup_narrowed("x"), None);
    }

    #[test]
    fn flow_context_inner_shadows_outer() {
        let mut ctx = FlowContext::new();
        let outer_ty = TypeHandle(1);
        let inner_ty = TypeHandle(2);

        // 外层 narrow
        ctx.add_fact(FlowFact {
            path: "x".into(),
            narrowed_ty: outer_ty,
            kind: NarrowKind::NonNull,
        });

        ctx.push_scope();
        // 内层 narrow 覆盖外层
        ctx.add_fact(FlowFact {
            path: "x".into(),
            narrowed_ty: inner_ty,
            kind: NarrowKind::NonNull,
        });
        assert_eq!(ctx.lookup_narrowed("x"), Some(inner_ty));

        ctx.pop_scope();
        // 回到外层
        assert_eq!(ctx.lookup_narrowed("x"), Some(outer_ty));
    }

    #[test]
    fn flow_context_field_path() {
        let mut ctx = FlowContext::new();
        let ty = TypeHandle(99);
        ctx.add_fact(FlowFact {
            path: "obj.field".into(),
            narrowed_ty: ty,
            kind: NarrowKind::NonNull,
        });
        assert_eq!(ctx.lookup_narrowed("obj.field"), Some(ty));
        assert_eq!(ctx.lookup_narrowed("obj"), None);
        assert_eq!(ctx.lookup_narrowed("other"), None);
    }

    #[test]
    fn flow_context_reset() {
        let mut ctx = FlowContext::new();
        ctx.push_scope();
        ctx.push_scope();
        ctx.add_fact(FlowFact {
            path: "x".into(),
            narrowed_ty: TypeHandle(1),
            kind: NarrowKind::NonNull,
        });
        ctx.reset();
        assert_eq!(ctx.depth(), 1);
        assert_eq!(ctx.lookup_narrowed("x"), None);
    }

    // ── sema v2: WitnessTable 测试 ──

    #[test]
    fn witness_table_register_and_query() {
        let mut wt = WitnessTable::new();
        let mut slots = HashMap::new();
        slots.insert("show".into(), 42u32);
        wt.register("Show", 3, "i32", slots);

        assert!(wt.implements("Show", 3));
        assert!(!wt.implements("Show", 4));
        assert!(!wt.implements("Eq", 3));

        assert_eq!(wt.resolve_method("Show", 3, "show"), Some(42));
        assert_eq!(wt.resolve_method("Show", 3, "missing"), None);
        assert_eq!(wt.resolve_method("Show", 4, "show"), None);
    }

    #[test]
    fn witness_table_trait_methods() {
        let mut wt = WitnessTable::new();
        let mut slots = HashMap::new();
        slots.insert("eq".into(), 10u32);
        slots.insert("neq".into(), 11u32);
        wt.register("Eq", 3, "i32", slots);

        let methods = wt.trait_methods("Eq", 3);
        assert_eq!(methods.len(), 2);
        assert!(methods.contains(&"eq"));
        assert!(methods.contains(&"neq"));
    }

    #[test]
    fn witness_table_overwrite() {
        let mut wt = WitnessTable::new();
        let mut slots1 = HashMap::new();
        slots1.insert("show".into(), 1u32);
        wt.register("Show", 3, "i32", slots1);

        let mut slots2 = HashMap::new();
        slots2.insert("show".into(), 99u32);
        wt.register("Show", 3, "i32", slots2);

        // 覆盖后取新值
        assert_eq!(wt.resolve_method("Show", 3, "show"), Some(99));
        assert_eq!(wt.len(), 1); // 未增加条目
    }

    #[test]
    fn witness_table_empty() {
        let wt = WitnessTable::new();
        assert!(wt.is_empty());
        assert!(!wt.implements("Show", 3));
    }

    // ── sema v2: type_id_of 测试 ──

    #[test]
    fn type_id_of_scalar() {
        let mut arena = TypeArena::new();
        let sr = SemaResult::new();
        let i32_ty = arena.make(ConcreteType::I32);
        assert_eq!(type_id_of(&arena, i32_ty, &sr), Some(3));

        let f64_ty = arena.make(ConcreteType::F64);
        assert_eq!(type_id_of(&arena, f64_ty, &sr), Some(15));

        let bool_ty = arena.make(ConcreteType::Bool);
        assert_eq!(type_id_of(&arena, bool_ty, &sr), Some(17));
    }

    #[test]
    fn type_id_of_type_var() {
        let mut arena = TypeArena::new();
        let sr = SemaResult::new();
        let v = arena.fresh_type_var();
        assert_eq!(type_id_of(&arena, v, &sr), None);
    }
}
