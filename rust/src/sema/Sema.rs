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

use crate::ast::Ast::{
    AstArena, Decl, TypeNode, TypeRef as AstTypeRef,
};
use crate::TypeDesc::{
    lookup_by_type_id, FloatKind, IntKind, RefOps, STR_DESC,
    TypeDescriptor, TypeDescriptorPool,
    FIRST_DYNAMIC_TYPE_ID, MAX_BUILTIN_TYPE_ID, type_def_index_of,
};
use rustc_hash::{FxHashMap, FxHashSet};
use std::fmt;

// =========================================================================
// TypeHandle — ConcreteType 在 TypeArena 中的索引句柄
// =========================================================================

/// `ConcreteType` 在 `TypeArena::types` 中的索引。newtype 保证类型安全，
/// 避免与普通 `u32` 或 `Ast::TypeId` 混淆。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TypeHandle(pub u32);

// =========================================================================
// SemKind — kind 系统（支持高阶类型 HKT）
// =========================================================================

/// 语义层的 kind：描述类型的"类型"。
///
/// - `Star`：普通值类型（`i32`、`Bool`、`List<i32>` 等），kind 为 `*`
/// - `Arrow`：类型构造器（`List` 本身 kind 为 `* -> *`，`Map` 为 `* -> * -> *`）
/// - `Var`：kind 变量，用于 kind 推断（当类型参数未声明 kind 时，分配 kind 变量
///   并在使用时通过 kind unification 约束）
///
/// kind 多态：类型参数可以携带 kind 变量，允许 kind 在使用时才确定。
/// 例如 `fun fmap<F>(f: (A) -> B, fa: F<A>): F<B>` 中 `F` 的 kind 为 `Var(0)`，
/// 通过 `F<A>` 的应用推断出 `Var(0) = * -> *`。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SemKind {
    /// 普通值类型
    Star,
    /// 类型构造器：`param -> result`
    Arrow { param: Box<SemKind>, result: Box<SemKind> },
    /// kind 变量：用于 kind 推断，载荷为 `TypeArena::kind_vars` 下标
    Var(u32),
}

impl SemKind {
    /// 默认 kind 为 Star
    #[inline]
    pub fn star() -> Self {
        SemKind::Star
    }

    /// 从 Ast::Kind 转换为 SemKind
    pub fn from_ast(kind: &crate::ast::Ast::Kind) -> Self {
        match kind {
            crate::ast::Ast::Kind::Star => SemKind::Star,
            crate::ast::Ast::Kind::Arrow { param, result } => SemKind::Arrow {
                param: Box::new(SemKind::from_ast(param)),
                result: Box::new(SemKind::from_ast(result)),
            },
        }
    }

    /// 计算 kind 的 arity（Star=0, * -> * =1, * -> * -> * =2）
    pub fn arity(&self) -> usize {
        match self {
            SemKind::Star => 0,
            SemKind::Arrow { result, .. } => 1 + result.arity(),
            SemKind::Var(_) => 0,
        }
    }

    /// 对 kind 进行应用：给定参数 kind 列表，返回结果 kind。
    /// `Star.apply([])` = `Star`
    /// `(* -> *).apply([Star])` = `Star`
    /// `(* -> * -> *).apply([Star, Star])` = `Star`
    /// 参数数量或 kind 不匹配时返回 None
    pub fn apply(&self, args: &[SemKind]) -> Option<SemKind> {
        if args.is_empty() {
            return Some(self.clone());
        }
        match self {
            SemKind::Star => None, // Star 不能接受参数
            SemKind::Var(_) => None, // kind 变量不能直接应用（需先通过 kind unification 约束）
            SemKind::Arrow { param, result } => {
                if args.is_empty() {
                    return Some(self.clone());
                }
                // 检查第一个参数的 kind 是否匹配
                if **param != args[0] {
                    return None;
                }
                result.apply(&args[1..])
            }
        }
    }

    /// 提取箭头 kind 的参数 kind 列表和结果 kind。
    /// `Star` → `([], Star)`
    /// `* -> *` → `([Star], Star)`
    /// `* -> * -> *` → `([Star, Star], Star)`
    pub fn decompose(&self) -> (Vec<SemKind>, &SemKind) {
        let mut params = Vec::new();
        let mut current = self;
        while let SemKind::Arrow { param, result } = current {
            params.push((**param).clone());
            current = result;
        }
        (params, current)
    }
}

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
    /// 类型变量的 kind：普通类型变量为 Star，泛型类型构造器参数为 Arrow。
    /// kind 变量（Var）用于 kind 推断——当类型参数未声明 kind 时分配。
    pub kind: SemKind,
}

impl TypeVar {
    #[inline]
    pub fn new(is_rigid: bool) -> Self {
        TypeVar {
            bound: None,
            is_rigid,
            kind: SemKind::Star,
        }
    }

    #[inline]
    pub fn new_with_kind(is_rigid: bool, kind: SemKind) -> Self {
        TypeVar {
            bound: None,
            is_rigid,
            kind,
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
    /// trait 对象类型：inline_trait 值的存在类型，携带完整方法签名表
    /// 用于 `trait { ... }` 表达式的类型推断与方法分派
    TraitObject {
        trait_name: Box<str>,
        method_sigs: Box<[TraitMethodSig]>,
    },
    /// 模块引用类型：携带模块路径和该模块专属的环境引用。
    ///
    /// `path` 是完整模块路径（如 "std.reflect.Reflect"），用于诊断和路径构建。
    /// `env` 是该模块的符号环境（函数、类型等注册于此），查找模块内符号时直接在此 env 中按裸名查找，
    /// 无需拼接 mangled name。父环境指向 root_env，使模块内可访问全局 builtins。
    ///
    /// 对于路径前缀（如 "std.reflect"），env 指向一个只包含子模块绑定的中间 env。
    ModuleRef {
        path: Box<str>,
        env: EnvId,
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
    /// 1..=MAX_BUILTIN_TYPE_ID，与 builtin_type_id 一致。
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

/// 内置标量元数据表：每行声明一个标量变体的全部属性。
/// 宏展开为 `classify_scalar`（变体→元数据）和 `from_scalar_name`（名字→变体）两个 match。
/// 新增标量只需在此追加一行，所有谓词（is_int/is_float/builtin_name 等）自动派生。
macro_rules! scalar_table {
    ($($variant:ident => $kind:ident, $signed:expr, $bits:expr, $rank:expr, $name:literal, $tid:literal),* $(,)?) => {
        impl ConcreteType {
            /// 返回内置标量的元数据；非标量（Never / TypeVar / 复合类型）返回 `None`。
            #[inline]
            pub fn classify_scalar(&self) -> Option<ScalarInfo> {
                let (kind, signed, bit_width, rank, name, type_id) = match self {
                    $( ConcreteType::$variant => (ScalarKind::$kind, $signed, $bits, $rank, $name, $tid), )*
                    _ => return None,
                };
                Some(ScalarInfo { kind, signed, bit_width, rank, name, type_id })
            }

            /// 判断名字是否为内置标量类型名（不分配，纯字符串比较）。
            #[inline]
            pub fn is_builtin_scalar_name(name: &str) -> bool {
                matches!(name, $( $name )|*)
            }
        }
        impl TypeArena {
            /// 从标量类型名反向构造 `ConcreteType`（用于内置类型）；未知名返回 `Unknown`。
            pub fn from_scalar_name(&mut self, name: &str) -> TypeHandle {
                let ct = match name {
                    $( $name => ConcreteType::$variant, )*
                    _ => return self.make(ConcreteType::Unknown),
                };
                self.make(ct)
            }
        }
    };
}

scalar_table! {
    I8    => SignedInt,   true,  8,                  1, "i8",    1,
    I16   => SignedInt,   true,  16,                 2, "i16",   2,
    I32   => SignedInt,   true,  32,                 3, "i32",   3,
    I64   => SignedInt,   true,  64,                 4, "i64",   4,
    I128  => SignedInt,   true,  128,                5, "i128",  5,
    U8    => UnsignedInt, false, 8,                  1, "u8",    6,
    U16   => UnsignedInt, false, 16,                 2, "u16",   7,
    U32   => UnsignedInt, false, 32,                 3, "u32",   8,
    U64   => UnsignedInt, false, 64,                 4, "u64",   9,
    U128  => UnsignedInt, false, 128,                5, "u128",  10,
    Isize => SignedInt,   true,  isize::BITS as u16, 4, "isize", 11,
    Usize => UnsignedInt, false, isize::BITS as u16, 4, "usize", 12,
    F16   => Float,       false, 16,                 1, "f16",   13,
    F32   => Float,       false, 32,                 2, "f32",   14,
    F64   => Float,       false, 64,                 3, "f64",   15,
    F128  => Float,       false, 128,                4, "f128",  16,
    Bool  => Bool,        false, 1,                  0, "bool",  17,
    Char  => Char,        false, 32,                 0, "char",  18,
    Str   => Str,         false, 0,                  0, "str",   19,
    Null  => Null,        false, 0,                  0, "Null",  20,
    Void  => Void,        false, 0,                  0, "void",  21,
}

impl ConcreteType {
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

/// TypeArena 状态快照：用于尝试性推断的 rollback。
///
/// `unify` 直接修改 `type_vars[].bound`，`unify_kind` 直接修改 `kind_vars`。
/// ConstraintSolver 的 snapshot/rollback 只覆盖 solver 层状态（subst/candidates/errors/pending），
/// 不覆盖 arena 层状态。本快照补充 arena 层的状态保存与恢复，确保回退时完全一致。
#[derive(Clone)]
pub struct ArenaSnapshot {
    /// 快照时 type_vars 的长度
    type_vars_len: usize,
    /// 每个 TypeVar 的 bound 快照（快照时已存在的条目）
    type_vars_bound: Vec<Option<TypeHandle>>,
    /// 快照时 kind_vars 的长度
    kind_vars_len: usize,
    /// kind_vars 的完整快照
    kind_vars: Vec<Option<SemKind>>,
}

/// Snapshot 标识：用于 rollback/commit 尝试性推断。
///
/// snapshot 时记录 pending 队列长度和 subst 快照；
/// rollback 时恢复到快照状态；commit 时丢弃快照保留求解结果。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SnapshotId(pub u32);

/// 尝试性推断的统一状态快照：同时保存 ConstraintSolver 和 TypeArena 状态。
///
/// 使用方式：
/// ```ignore
/// let snap = ctx.snapshot_type_state();
/// // ... 尝试性推断 ...
/// if success {
///     ctx.commit_type_state(snap);
/// } else {
///     ctx.rollback_type_state(snap);
/// }
/// ```
pub struct TypeStateSnapshot {
    pub solver_snap: SnapshotId,
    pub arena_snap: ArenaSnapshot,
}

/// `ConcreteType` 分配器：arena-based，管理类型槽与类型变量。
///
/// 所有 `ConcreteType` 通过 `make` 分配并返回 `TypeHandle` 索引；类型变量通过
/// `fresh_type_var` / `fresh_rigid_var` 分配。`resolve`/`occurs`/`unify` 作为方法，
/// 因为复合类型的子节点遍历需要访问 `&self` / `&mut self`。
pub struct TypeArena {
    pub types: Vec<ConcreteType>,
    pub type_vars: Vec<TypeVar>,
    /// kind 变量的绑定表：kind_vars[idx] = Some(SemKind) 表示已绑定。
    /// 用于 kind 推断——当类型参数未声明 kind 时分配 kind 变量，
    /// 在 type application 时通过 kind unification 约束。
    kind_vars: Vec<Option<SemKind>>,
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
            kind_vars: Vec::new(),
        }
    }

    /// 已分配类型数量。
    #[inline]
    pub fn len(&self) -> usize {
        self.types.len()
    }

    /// 已分配类型变量数量（用于跨模块基线快照）。
    #[inline]
    pub fn type_vars_len(&self) -> usize {
        self.type_vars.len()
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

    /// 创建新的（非 rigid）类型变量，用于局部推断。kind 默认为 Star。
    pub fn fresh_type_var(&mut self) -> TypeHandle {
        let idx = self.type_vars.len() as u32;
        self.type_vars.push(TypeVar::new(false));
        self.make(ConcreteType::TypeVar(idx))
    }

    /// 创建带指定 kind 的非 rigid 类型变量。
    pub fn fresh_type_var_with_kind(&mut self, kind: SemKind) -> TypeHandle {
        let idx = self.type_vars.len() as u32;
        self.type_vars.push(TypeVar::new_with_kind(false, kind));
        self.make(ConcreteType::TypeVar(idx))
    }

    /// 创建 rigid 类型变量（泛型参数声明，不可与不同类型统一）。kind 默认为 Star。
    pub fn fresh_rigid_var(&mut self) -> TypeHandle {
        let idx = self.type_vars.len() as u32;
        self.type_vars.push(TypeVar::new(true));
        self.make(ConcreteType::TypeVar(idx))
    }

    /// 创建带指定 kind 的 rigid 类型变量（HKT 泛型参数声明）。
    /// 例如 `fun map<F: * -> *>(...)` 中的 `F` 使用此方法。
    pub fn fresh_rigid_var_with_kind(&mut self, kind: SemKind) -> TypeHandle {
        let idx = self.type_vars.len() as u32;
        self.type_vars.push(TypeVar::new_with_kind(true, kind));
        self.make(ConcreteType::TypeVar(idx))
    }

    /// 创建 kind 变量（用于 kind 推断）。
    pub fn fresh_kind_var(&mut self) -> SemKind {
        let idx = self.kind_vars.len() as u32;
        self.kind_vars.push(None);
        SemKind::Var(idx)
    }

    /// 获取类型变量的 kind。
    #[inline]
    pub fn type_var_kind(&self, idx: u32) -> &SemKind {
        &self.type_vars[idx as usize].kind
    }

    /// 计算任意 TypeHandle 的 kind。
    ///
    /// - TypeVar → 从 TypeVar.kind 获取（可能含未绑定的 kind 变量）
    /// - 标量/Never/Unknown/Void → Star
    /// - 已应用的复合类型（Fn/Record/Adt/Generic/Trait/Throw/Nullable/Array/Ref/TraitObject/ModuleRef）→ Star
    ///   （这些都是完整的值类型，kind 为 Star）
    pub fn kind_of(&self, ty: TypeHandle) -> SemKind {
        match self.get(ty) {
            ConcreteType::TypeVar(idx) => self.type_vars[*idx as usize].kind.clone(),
            _ => SemKind::Star,
        }
    }

    /// 解析 kind 变量到其绑定值（类似 type resolve）。
    pub fn resolve_kind(&self, mut kind: SemKind) -> SemKind {
        while let SemKind::Var(idx) = &kind {
            if let Some(Some(bound)) = self.kind_vars.get(*idx as usize) {
                kind = bound.clone();
            } else {
                break;
            }
        }
        kind
    }

    /// kind 统一：尝试统一两个 kind，成功则绑定 kind 变量。
    ///
    /// 规则：
    /// - Star = Star → Ok
    /// - Arrow(p1, r1) = Arrow(p2, r2) → 递归 unify p1=p2, r1=r2
    /// - Var(idx) = k → 绑定 kind_vars[idx] = k
    /// - k = Var(idx) → 绑定 kind_vars[idx] = k
    /// - 其他 → Err（kind 不匹配）
    pub fn unify_kind(&mut self, k1: &SemKind, k2: &SemKind) -> Result<(), ()> {
        let r1 = self.resolve_kind(k1.clone());
        let r2 = self.resolve_kind(k2.clone());

        if r1 == r2 {
            return Ok(());
        }

        match (&r1, &r2) {
            (SemKind::Var(idx), _) => {
                self.kind_vars[*idx as usize] = Some(r2);
                Ok(())
            }
            (_, SemKind::Var(idx)) => {
                self.kind_vars[*idx as usize] = Some(r1);
                Ok(())
            }
            (SemKind::Arrow { param: p1, result: r1 }, SemKind::Arrow { param: p2, result: r2 }) => {
                self.unify_kind(p1, p2)?;
                self.unify_kind(r1, r2)
            }
            _ => Err(()),
        }
    }

    /// 检查类型应用（type application）的 kind 一致性。
    ///
    /// 给定类型构造器的 kind 和实际参数的 kind 列表，验证应用是否合法。
    /// 返回应用后的结果 kind，或 kind 不匹配错误。
    ///
    /// 例如：
    /// - constructor_kind = `* -> *`, arg_kinds = `[Star]` → Ok(Star)
    /// - constructor_kind = `* -> * -> *`, arg_kinds = `[Star, Star]` → Ok(Star)
    /// - constructor_kind = `Star`, arg_kinds = `[Star]` → Err（Star 不是类型构造器）
    /// - constructor_kind = `* -> *`, arg_kinds = `[Star, Star]` → Err（参数过多）
    pub fn check_kind_application(
        &mut self,
        constructor_kind: &SemKind,
        arg_kinds: &[SemKind],
    ) -> Result<SemKind, String> {
        let resolved_ck = self.resolve_kind(constructor_kind.clone());

        if arg_kinds.is_empty() {
            return Ok(resolved_ck);
        }

        match &resolved_ck {
            SemKind::Star => Err(format!(
                "kind mismatch: type of kind '*' cannot be applied to {} type argument(s)",
                arg_kinds.len()
            )),
            SemKind::Var(_) => {
                // kind 变量：通过 kind unification 推断
                // 构造期望的 kind：arg_kinds[0] -> arg_kinds[1] -> ... -> Star
                let mut expected_kind = SemKind::Star;
                for arg_kind in arg_kinds.iter().rev() {
                    expected_kind = SemKind::Arrow {
                        param: Box::new(arg_kind.clone()),
                        result: Box::new(expected_kind),
                    };
                }
                self.unify_kind(&resolved_ck, &expected_kind)
                    .map(|_| SemKind::Star)
                    .map_err(|_| {
                        format!(
                            "kind mismatch: cannot infer kind for type constructor with {} argument(s)",
                            arg_kinds.len()
                        )
                    })
            }
            SemKind::Arrow { param, result } => {
                // 检查第一个参数的 kind
                let arg_kind_resolved = self.resolve_kind(arg_kinds[0].clone());
                let param_resolved = self.resolve_kind((**param).clone());
                if param_resolved != arg_kind_resolved {
                    // 尝试 kind unification（处理 kind 变量）
                    if self.unify_kind(&param_resolved, &arg_kind_resolved).is_err() {
                        return Err(format!(
                            "kind mismatch: expected argument of kind {:?}, found {:?}",
                            param_resolved, arg_kind_resolved
                        ));
                    }
                }
                // 递归检查剩余参数
                self.check_kind_application(result, &arg_kinds[1..])
            }
        }
    }

    // ── snapshot/rollback 支持 ──────────────────────────────────

    /// 创建 arena 状态快照：保存 type_vars.bound 和 kind_vars。
    ///
    /// `unify` 直接修改 `type_vars[].bound`，`unify_kind` 直接修改 `kind_vars`。
    /// ConstraintSolver 的 snapshot/rollback 不覆盖这些 arena 层状态，
    /// 需要本方法配合使用，确保尝试性推断回退时状态完全一致。
    pub fn snapshot_arena(&self) -> ArenaSnapshot {
        ArenaSnapshot {
            type_vars_len: self.type_vars.len(),
            type_vars_bound: self.type_vars.iter().map(|tv| tv.bound).collect(),
            kind_vars_len: self.kind_vars.len(),
            kind_vars: self.kind_vars.clone(),
        }
    }

    /// 恢复 arena 状态到快照。
    ///
    /// 恢复已有 type_vars 的 bound 到快照值，恢复 kind_vars 到快照值。
    /// 快照后新增的 type_vars/kind_vars 保留（bound 默认 None，不影响正确性）。
    pub fn restore_arena(&mut self, snap: &ArenaSnapshot) {
        // 恢复 type_vars 的 bound（只恢复快照时已存在的条目）
        let tv_len = snap.type_vars_len.min(self.type_vars.len());
        for i in 0..tv_len {
            self.type_vars[i].bound = snap.type_vars_bound[i];
        }
        // 恢复 kind_vars（只恢复快照时已存在的条目）
        let kv_len = snap.kind_vars_len.min(self.kind_vars.len());
        for i in 0..kv_len {
            self.kind_vars[i] = snap.kind_vars[i].clone();
        }
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
            ConcreteType::TraitObject { .. } => false,
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
                    // b 侧是非 rigid var：把 b 绑定到 rigid a（使 fresh var 成为 T 的别名）
                    // 场景：方法体内部 T（rigid）与 NullLit 等产生的 fresh var 统一
                    if !self.type_vars[bidx as usize].is_rigid {
                        if self.occurs(bidx, a) {
                            return Err(UnifyError::OccursCheckFailed);
                        }
                        // kind 兼容性检查
                        let b_kind = self.type_vars[bidx as usize].kind.clone();
                        let a_kind = self.kind_of(a);
                        if self.unify_kind(&b_kind, &a_kind).is_err() {
                            return Err(UnifyError::TypeMismatch);
                        }
                        self.type_vars[bidx as usize].bound = Some(a);
                        return Ok(());
                    }
                }
                return Err(UnifyError::TypeMismatch);
            }
            if self.occurs(idx, b) {
                return Err(UnifyError::OccursCheckFailed);
            }
            // kind 兼容性检查：TypeVar 的 kind 必须与绑定目标的 kind 兼容
            let var_kind = self.type_vars[idx as usize].kind.clone();
            let target_kind = self.kind_of(b);
            if self.unify_kind(&var_kind, &target_kind).is_err() {
                return Err(UnifyError::TypeMismatch);
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
            // kind 兼容性检查：TypeVar 的 kind 必须与绑定目标的 kind 兼容
            let var_kind = self.type_vars[idx as usize].kind.clone();
            let target_kind = self.kind_of(a);
            if self.unify_kind(&var_kind, &target_kind).is_err() {
                return Err(UnifyError::TypeMismatch);
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
                ConcreteType::TraitObject { trait_name: na, method_sigs: ma },
                ConcreteType::TraitObject { trait_name: nb, method_sigs: mb },
            ) if na == nb && ma.len() == mb.len() => {
                for (a, b) in ma.iter().zip(mb.iter()) {
                    if a != b {
                        return Err(UnifyError::TypeMismatch);
                    }
                }
                Ok(())
            }

            // Trait 类型与 TraitObject（同名）可统一：trait 值赋值给 trait 类型变量
            (
                ConcreteType::Trait { name: na, .. },
                ConcreteType::TraitObject { trait_name: nb, .. },
            ) if na == nb => Ok(()),
            (
                ConcreteType::TraitObject { trait_name: na, .. },
                ConcreteType::Trait { name: nb, .. },
            ) if na == nb => Ok(()),

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
    // from_scalar_name 由 scalar_table! 宏生成。

    /// 提取类型名（用于 `ExprInfo.type_name`）。
    /// 标量返回静态名；adt/generic/trait 返回其名；ref/nullable 递归取 inner 名；
    /// 其余返回 `None`。递归场景需 arena 访问子节点。
    pub fn type_name(&self, ty: TypeHandle) -> Option<&str> {
        match &self.types[ty.0 as usize] {
            ConcreteType::Adt { name, .. }
            | ConcreteType::Generic { name, .. }
            | ConcreteType::Trait { name, .. } => Some(name),
            ConcreteType::TraitObject { trait_name, .. } => Some(trait_name),
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
                    ConcreteType::TraitObject { trait_name, method_sigs } => {
                        write!(f, "dyn {}", trait_name)?;
                        if method_sigs.is_empty() {
                            return Ok(());
                        }
                        f.write_str(" { ")?;
                        for (i, m) in method_sigs.iter().enumerate() {
                            if i > 0 {
                                f.write_str(", ")?;
                            }
                            write!(f, "{}(/{})", m.name, m.param_count)?;
                        }
                        f.write_str(" }")
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
    bindings: FxHashMap<String, TypeHandle>,
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
            bindings: FxHashMap::default(),
            parent: None,
        });
        id
    }

    /// 创建子环境，父环境为 `parent`。
    pub fn child(&mut self, parent: EnvId) -> EnvId {
        let id = EnvId(self.envs.len() as u32);
        self.envs.push(EnvNode {
            bindings: FxHashMap::default(),
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

    /// 在 `env` 中强制定义绑定（覆盖已存在的同名绑定）。
    ///
    /// 用于构造器注册：`register_module_aliases` 先注册模块路径别名（如 "DateTime" → ModuleRef），
    /// 随后 `predeclare_declarations` 注册构造器时需覆盖别名，使 `DateTime(...)` 解析为构造器而非 ModuleRef。
    pub fn redefine(&mut self, env: EnvId, name: &str, ty: TypeHandle) {
        let node = &mut self.envs[env.0 as usize];
        node.bindings.insert(name.to_string(), ty);
    }

    /// 自 `env` 向上查找名字（含父环境链）；未找到返回 `None`。
    pub fn lookup(&self, mut env: EnvId, name: &str) -> Option<TypeHandle> {
        loop {
            let node = &self.envs[env.0 as usize];
            if let Some(&ty) = node.bindings.get(name) {
                return Some(ty);
            }
            {
                let p = node.parent?;
                env = p
            }
        }
    }

    /// 仅在 `env` 自身查找名字（不含父环境链）；未找到返回 `None`。
    ///
    /// 用于模块限定访问（ModuleRef.field）：只搜索该模块自己的符号，
    /// 不穿透到父 env（避免 `std.io.File.println` 错误地找到全局 `println`）。
    pub fn lookup_local(&self, env: EnvId, name: &str) -> Option<TypeHandle> {
        self.envs[env.0 as usize].bindings.get(name).copied()
    }

    /// 自 `env` 向上查找名为 `name` 且满足 `pred` 的绑定（跳过不满足的同名绑定）。
    /// 用于方法调用 `recv.method(args)` → `method(recv, args)` 路径，
    /// 避免局部变量遮蔽同名自由函数。
    pub fn lookup_with_pred(
        &self,
        mut env: EnvId,
        name: &str,
        pred: impl Fn(TypeHandle) -> bool,
    ) -> Option<TypeHandle> {
        loop {
            let node = &self.envs[env.0 as usize];
            if let Some(&ty) = node.bindings.get(name) {
                if pred(ty) {
                    return Some(ty);
                }
            }
            {
                let p = node.parent?;
                env = p
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
    /// 编译期常量值（若表达式是常量）
    pub const_val: Option<ConstVal>,
    /// 表达式的 AST 句柄地址（用作 key）
    pub expr_id: u64,
    /// 表达式的类型名（adt/generic 等场景，消除 IR 侧 AST 回溯）
    pub type_name: Option<Box<str>>,
    /// 是否为 trait 对象（ConcreteType::TraitObject）：IR 层据此走 vtable 动态分派，
    /// 而非按字符串值匹配 trait 名。适用于任何 trait（Iterator/Stream/Iterable 等）。
    pub is_trait_object: bool,
    /// 是否为 `&T` / `*T` 引用类型（运行时保持引用语义不深拷贝）
    pub is_ref_type: bool,
    /// 区分 `&T`(false) 与 `*T`(true)；仅 `is_ref_type=true` 时有效
    pub is_raw_ref: bool,
}

impl ExprInfo {
    /// 以给定 `type_desc` 构造最小 `ExprInfo`（其余字段为默认值）。
    pub fn new(type_desc: &'static TypeDescriptor, expr_id: u64) -> Self {
        ExprInfo {
            type_desc,
            const_val: None,
            expr_id,
            type_name: None,
            is_trait_object: false,
            is_ref_type: false,
            is_raw_ref: false,
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
}

/// 构造器定义信息（压平后的 sema AdtInfo 构造器）。
#[derive(Debug, Clone)]
pub struct CtorDefInfo {
    pub name: Box<str>,
    pub type_name: Box<str>,
    pub field_names: Box<[Option<Box<str>>]>,
    pub field_type_descs: Box<[&'static TypeDescriptor]>,
    pub is_newtype: bool,
    /// GADT 构造器返回类型名（仅 GADT 有效）
    pub return_type_name: Option<Box<str>>,
    /// GADT 构造器返回类型 TypeNode（消除 IR 侧 AST 回退）
    pub return_type_node: Option<AstTypeRef>,
    /// 字段类型的自包含表示（不依赖 AST 引用），用于跨模块完整还原字段类型
    /// （包括数组、Nullable、Ref 等复合类型）。
    /// 长度与 `field_names` 一致。
    pub field_type_reprs: Box<[TypeRepr]>,
}

/// 类型方法的签名信息，按 method_idx（在 type 块 methods 数组中的位置）索引。
///
/// 自包含的类型表示（不依赖 AST 引用），用于跨模块传递方法返回类型信息。
/// 在 build_method_sig_info 阶段从 AST TypeNode 转换，在 lookup_method_type 中
/// 通过 type_repr_to_handle 还原为 TypeHandle。
#[derive(Debug, Clone)]
pub enum TypeRepr {
    Named(Box<str>),
    SelfType,
    Generic(Box<str>, Box<[TypeRepr]>),
    Nullable(Box<TypeRepr>),
    Ref(Box<TypeRepr>),
    RawPtr(Box<TypeRepr>),
    Function(Box<[TypeRepr]>, Box<TypeRepr>),
    Array(Box<TypeRepr>, Option<u64>),
}

/// 内置 intrinsic 方法的降级策略。
///
/// 存储在 `MethodSigInfo.intrinsic` 中，IR 层通过 (type_id, method_idx) 查到
/// 方法签名后，根据此字段选择节点 kind 和 compute_fn，消除按方法名查表的特判。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IntrinsicKind {
    /// 单节点一元运算（无参数）：len/close/bytes/cancel → compute_fn(idx)
    UnOp(u32),
    /// 挂起等待事件源（无参数）：await → Await 节点（无条件降级）
    Await,
    /// Channel 接收（无参数）：recv → Await 节点（仅 Channel/Receiver 类型）
    ChannelAwait,
    /// 二元运算（recv + 1 参数）：send(value) → compute_fn(idx)
    BinOp(u32),
}

/// 替代旧的 func_sigs mangled name（"TypeName.method"）注册方式，
/// 使方法分派通过 (type_id, method_idx) 结构化键驱动。
#[derive(Debug, Clone)]
pub struct MethodSigInfo {
    pub name: Box<str>,
    pub param_is_ref: Box<[bool]>,
    pub return_is_ref: bool,
    pub is_async: bool,
    pub is_throwing: bool,
    /// 参数类型的自包含表示（不依赖 AST 引用），用于跨模块完整还原参数类型
    /// （包括数组、Nullable、Ref 等复合类型）。
    pub param_type_reprs: Box<[TypeRepr]>,
    /// 返回类型的自包含表示（不依赖 AST 引用），用于跨模块完整解析嵌套泛型类型
    /// （如 Async<Throw<T, E>>）。
    pub return_type_repr: Option<TypeRepr>,
    /// intrinsic 降级策略：None 表示普通方法（有方法体或 trait 方法），
    /// Some 表示内置 intrinsic 方法（无方法体，IR 层直接降级为 compute_fn 节点）。
    pub intrinsic: Option<IntrinsicKind>,
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
    /// 类型块内方法签名表，按 method_idx 索引（AST 声明顺序）。
    /// 空切片表示该类型无方法（alias / 无方法的 record/adt）。
    pub methods: Box<[MethodSigInfo]>,
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

impl PartialEq for TraitMethodSig {
    /// 相等性比较：name + param_count + is_async + has_body。
    /// 忽略 return_type_desc（&'static TypeDescriptor 不实现 PartialEq）。
    fn eq(&self, other: &Self) -> bool {
        self.name == other.name
            && self.param_count == other.param_count
            && self.is_async == other.is_async
            && self.has_body == other.has_body
    }
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
    pub return_type_desc: &'static TypeDescriptor,
    /// 每个参数是否为 `&T` 引用语义
    pub param_is_ref: Box<[bool]>,
    pub return_is_ref: bool,
    pub is_async: bool,
    pub is_throwing: bool,
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
    pub expr_types: FxHashMap<u64, ExprInfo>,
    /// 字段访问元信息（key = AST field_access Expr 句柄地址）
    pub field_accesses: FxHashMap<u64, FieldAccessInfo>,
}

/// trait 默认方法单态化实例。
///
/// 每个实现 trait 但未显式覆写该方法的类型，对应一个特化实例。
/// 由 `Monomorph::collect_trait_default_instances` 在 Sema 后阶段收集，
/// 供 IR 层（IrBuilder）预注册并编译特化子图。
///
/// 键语义：`(type_id, trait_idx, method_idx)` 与 `Ir.trait_default_subgraphs` 的键一致。
#[derive(Debug, Clone)]
pub struct TraitDefaultInstance {
    /// 实现类型的 type_id（与 ConcreteType.type_id 对应）
    pub type_id: u16,
    /// 实现类型名（如 "Lt"、"Ordering"）
    pub type_name: Box<str>,
    /// trait 在 `trait_defs` 中的索引
    pub trait_idx: u16,
    /// trait 名（如 "Greet"、"Show"）
    pub trait_name: Box<str>,
    /// 方法在 trait methods 中的索引（有 body 的默认方法）
    pub method_idx: u16,
}

/// 协程元数据（async 函数状态机变换产物）。
///
/// Sema 输出的最小元数据：func_idx 定位函数，segment_count 描述状态段数。
/// 完整的状态机变换（段/帧/defer/catch/loop 表）由 IR 层基于此元数据构建，
/// 不在 Sema 层维护，保持 Sema 与 IR 的职责分离。
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
/// 所有字段均为自有数据（`Box<str>` / `Vec` / `FxHashMap`），无需额外 arena 所有权。
pub struct SemaResult {
    /// 表达式 → 类型信息（决定通道宽度），key = AST 表达式句柄地址
    pub expr_types: FxHashMap<u64, ExprInfo>,
    /// 编译期错误
    pub errors: Vec<SemaError>,
    /// 是否有错误
    pub has_error: bool,
    /// 类型定义表（替代 IRBuilder 的 type_table + ctor_table）
    pub type_defs: Vec<TypeDefInfo>,
    /// 类型名 → type_defs 索引
    pub type_def_index: FxHashMap<String, u16>,
    /// Trait 定义表
    pub trait_defs: Vec<TraitDefInfo>,
    /// Trait 名 → trait_defs 索引
    pub trait_def_index: FxHashMap<String, u16>,
    /// 函数签名表
    pub func_sigs: Vec<FuncSigInfo>,
    /// 函数名 → func_sigs 索引
    pub func_sig_index: FxHashMap<String, u16>,
    /// 协程元数据表
    pub coroutine_metas: Vec<CoroutineMeta>,
    /// 构造器名 → (type_def_index << 16 | ctor_index)
    pub ctor_def_index: FxHashMap<String, u32>,
    /// import 别名表：短名 → 别名目标
    pub import_aliases: FxHashMap<String, AliasTarget>,
    /// 单态化实例表
    pub monomorph_instances: Vec<MonomorphInstance>,
    /// 单态化实例名 → monomorph_instances 索引
    pub monomorph_index: FxHashMap<String, u32>,
    /// trait 默认方法单态化实例表（Sema 后阶段由 Monomorph 模块收集）
    pub trait_default_instances: Vec<TraitDefaultInstance>,
    /// 全局 TypeDescriptor 表
    pub type_descriptors: Vec<&'static TypeDescriptor>,
    /// 动态类型描述符池（用户类型 / nullable 描述符）
    pub type_desc_pool: TypeDescriptorPool,
    /// 调用点 → 实例映射
    pub call_instantiations: FxHashMap<u64, u32>,
    /// 字段访问元信息（全局，key = AST field_access Expr 句柄地址）
    pub field_accesses: FxHashMap<u64, FieldAccessInfo>,
    /// 方法分派元信息（key = AST call Expr 句柄地址）
    pub method_dispatches: FxHashMap<u64, DispatchInfo>,
    /// reflect 已解析元信息
    pub reflect_metas: FxHashMap<u64, ReflectMeta>,
    /// 已解析类型描述符（key = AST Expr 句柄地址）
    pub resolved_type_descs: FxHashMap<u64, &'static TypeDescriptor>,
    /// 字段 ID 映射（key = "type_name\x00field_name" → field_id）
    /// ADT/newtype/error_newtype: `__tag=0`，字段从 1 开始
    /// Record: 字段按声明顺序 0..N-1
    pub field_id_map: FxHashMap<String, u16>,
    /// witness table（trait 实现的静态分派表）。
    ///
    /// sema 检查期间由 InferContext 维护并跨模块累积，check 完成后
    /// 镜像到此字段供 IR 层（IrBuilder）访问 trait 方法分派信息。
    pub witness_table: WitnessTable,
}

impl Default for SemaResult {
    fn default() -> Self {
        Self::new()
    }
}


/// 生成 "表 + 索引 + put/get" 三件套的标准注册函数。
/// `$put`/`$get` 为方法名，`$field` 为表字段名，`$index` 为索引字段名，`$ty` 为元素类型。
macro_rules! define_table_registry {
    ($put:ident, $get:ident, $field:ident, $index:ident, $ty:ty) => {
        /// 添加元素并注册索引；重复名返回 `false`。
        pub fn $put(&mut self, def: $ty) -> bool {
            if self.$index.contains_key(def.name.as_ref()) {
                return false;
            }
            let idx: u16 = self.$field.len() as u16;
            self.$index.insert(def.name.to_string(), idx);
            self.$field.push(def);
            true
        }
        /// 按名查询元素。
        pub fn $get(&self, name: &str) -> Option<&$ty> {
            let idx = *self.$index.get(name)?;
            self.$field.get(idx as usize)
        }
    };
}

impl SemaResult {
    pub fn new() -> Self {
        SemaResult {
            expr_types: FxHashMap::default(),
            errors: Vec::new(),
            has_error: false,
            type_defs: Vec::new(),
            type_def_index: FxHashMap::default(),
            trait_defs: Vec::new(),
            trait_def_index: FxHashMap::default(),
            func_sigs: Vec::new(),
            func_sig_index: FxHashMap::default(),
            coroutine_metas: Vec::new(),
            ctor_def_index: FxHashMap::default(),
            import_aliases: FxHashMap::default(),
            monomorph_instances: Vec::new(),
            monomorph_index: FxHashMap::default(),
            trait_default_instances: Vec::new(),
            type_descriptors: Vec::new(),
            type_desc_pool: TypeDescriptorPool::new(),
            call_instantiations: FxHashMap::default(),
            field_accesses: FxHashMap::default(),
            method_dispatches: FxHashMap::default(),
            reflect_metas: FxHashMap::default(),
            resolved_type_descs: FxHashMap::default(),
            field_id_map: FxHashMap::default(),
            witness_table: WitnessTable::new(),
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

    /// 获取或创建瘦引用描述符（8B，用于 `*T` 及非引用的具名描述符）。
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
    /// 职责分层：nullable 的数据部分（inner 类型值）读写复用 inner 的 ops，
    /// null 标志位的读写由 engine 层直接位操作处理（不通过 TypeOps）。
    /// size = inner.size + 1（含 null 标志位），这是设计决策而非临时占位。
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
    /// `field_id_map`。
    ///
    /// 类型名冲突时返回 `false`（同名类型不能重复定义）。
    /// 构造器名冲突时跳过该构造器（不注册到 `ctor_def_index`），但继续注册
    /// 其余构造器和类型定义本身，返回 `true`。
    /// 这处理类型名与构造器名共享命名空间的场景（如 `File` 既是 newtype
    /// 类型名又是 `FileKind` ADT 变体名），确保非冲突变体（如 `Directory`）
    /// 能被正常注册。
    pub fn put_type_def(&mut self, def: TypeDefInfo) -> bool {
        // u16 索引溢出检查（与 TypeDesc.rs 的 register 对齐）
        assert!(
            self.type_defs.len() < u16::MAX as usize,
            "type_def index overflow: too many type definitions"
        );
        let idx: u16 = self.type_defs.len() as u16;
        // 类型名冲突：拒绝（同名类型不能重复定义）
        if self.type_def_index.contains_key(def.name.as_ref()) {
            return false;
        }
        // 构造器名冲突：跳过该构造器，继续注册其余构造器
        self.populate_field_ids(&def);
        for (ci, ctor) in def.constructors.iter().enumerate() {
            if self.ctor_def_index.contains_key(ctor.name.as_ref()) {
                continue;
            }
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
            TypeDefKind::Newtype => {
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

    /// 构造 `field_id_map` 的 key：`"type_name\x00field_name"`。
    fn make_field_key(type_name: &str, field_name: &str) -> String {
        format!("{}\0{}", type_name, field_name)
    }

    /// 构造 `field_id_map` 的 key 并插入（已存在则覆盖）。
    fn put_field_id(&mut self, type_name: &str, field_name: &str, field_id: u16) {
        let key = Self::make_field_key(type_name, field_name);
        self.field_id_map.insert(key, field_id);
    }

    /// 查询 field_id（找不到返回 `None`）。
    /// key = "type_name\x00field_name"
    pub fn lookup_field_id(&self, type_name: &str, field_name: &str) -> Option<u16> {
        let key = Self::make_field_key(type_name, field_name);
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
    define_table_registry!(put_trait_def, get_trait_def, trait_defs, trait_def_index, TraitDefInfo);

    // ── 函数签名 ──
    define_table_registry!(put_func_sig, get_func_sig, func_sigs, func_sig_index, FuncSigInfo);

    // ── 方法签名（ConcreteType 驱动） ──

    /// 按类型名和方法名查找 method_idx（在 TypeDefInfo.methods 中的位置）。
    ///
    /// IR 层用 (type_id, method_idx) 查 method_subgraphs 获取子图。
    /// 返回 None 表示该类型无此方法（可能是 trait 默认方法，需查 witness_table）。
    pub fn lookup_method_idx(&self, type_name: &str, method_name: &str) -> Option<u16> {
        let &type_idx = self.type_def_index.get(type_name)?;
        let type_def = &self.type_defs[type_idx as usize];
        type_def
            .methods
            .iter()
            .position(|m| m.name.as_ref() == method_name)
            .map(|i| i as u16)
    }

    /// 按 type_id 和 method_idx 获取方法签名。
    pub fn get_method_sig(&self, type_id: u16, method_idx: u16) -> Option<&MethodSigInfo> {
        if type_id < FIRST_DYNAMIC_TYPE_ID {
            return None;
        }
        let type_idx = type_def_index_of(type_id) as usize;
        let type_def = self.type_defs.get(type_idx)?;
        type_def.methods.get(method_idx as usize)
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

/// 内置类型声明宏：一处声明，生成两个产物。
///
/// - **产物 1**：`BUILTIN_GENERIC_TYPES` 静态 arity 表（仅 `generic` 组）。
///   kind_check（step 7）在 `register_builtin_method_sigs`（step 8）之前执行，
///   故 arity 表必须为静态常量。
/// - **产物 2**：`register_builtin_method_sigs` 函数体（`generic` + `nongeneric` 组）。
///   运行时注册合成 `TypeDefInfo`（含方法签名表），使内置类型方法查找走与
///   用户自定义类型统一的 `(type_id, method_idx)` 路径。
///
/// `generic` 组的类型使用 `TypeNode::Generic { name, .. }` AST 节点，需在
/// `BUILTIN_GENERIC_TYPES` 中有条目以供 kind_check 查询 arity。
/// `nongeneric` 组有专用 `ConcreteType`/`TypeNode` 变体（如 Array/Nullable/Str），
/// 不需要 arity 表条目。
///
/// 声明语法：
/// ```ignore
/// define_builtin_types! {
///     generic {
///         "TypeName" : ["T", "E"] = [ sig(...), sig(...), ... ],
///         ...
///     }
///     nongeneric {
///         "TypeName" : ["T"] = [ sig(...), ... ],
///         ...
///     }
/// }
/// ```
macro_rules! define_builtin_types {
    (
        generic { $($gname:literal : [$($gp:literal),*] = [$($gmethod:expr),* $(,)?]),* $(,)? }
        nongeneric { $($nname:literal : [$($np:literal),*] = [$($nmethod:expr),* $(,)?]),* $(,)? }
    ) => {
        /// 内置泛型类型构造器表（由 `define_builtin_types!` 宏从 `generic` 组派生）。
        pub const BUILTIN_GENERIC_TYPES: &[BuiltinGenericEntry] = &[
            $( BuiltinGenericEntry {
                name: $gname,
                arity: <[&'static str]>::len(&[$($gp),*]) as u8,
            } ),*
        ];

        /// 为内置类型注册合成 TypeDefInfo（含方法签名表），使内置类型的方法查找走与
        /// 用户自定义类型统一的 (type_id, method_idx) 路径，消除 lookup_builtin_method
        /// 的 match 分支特判。
        ///
        /// 方法签名中：
        /// - param_type_reprs[0] = SelfType（self 参数，与用户 type 块一致）
        /// - 泛型参数用 Named("T")/Named("E")，由 type_binding_stack 解析
        /// - 标量返回类型用 Named("usize")/Named("bool")/Named("void")/Named("str")
        /// - build_fn_type_from_sig 通过 type_repr_to_handle 还原完整 ConcreteType::Fn
        pub fn register_builtin_method_sigs(sema_result: &mut SemaResult) {
            /// 构建单条内置方法签名。type_desc 字段用 VOID_DESC 占位（不影响类型检查，
            /// build_fn_type_from_sig 只读 param_type_reprs / return_type_repr）。
            /// intrinsic 参数标注降级策略，None 表示普通方法（有方法体或 trait 方法）。
            fn sig(
                name: &str,
                param_reprs: Vec<TypeRepr>,
                return_repr: Option<TypeRepr>,
                intrinsic: Option<IntrinsicKind>,
            ) -> MethodSigInfo {
                let n = param_reprs.len();
                MethodSigInfo {
                    name: name.into(),
                    param_is_ref: vec![false; n].into_boxed_slice(),
                    return_is_ref: false,
                    is_async: false,
                    is_throwing: false,
                    param_type_reprs: param_reprs.into_boxed_slice(),
                    return_type_repr: return_repr,
                    intrinsic,
                }
            }

            /// 为一个内置类型注册合成 TypeDefInfo。
            fn register(
                sema_result: &mut SemaResult,
                type_name: &str,
                type_params: &[&str],
                methods: Vec<MethodSigInfo>,
            ) {
                if sema_result.type_def_index.contains_key(type_name) {
                    return; // 已注册（如用户 stdlib 已声明同名 type 块）
                }
                let def = TypeDefInfo {
                    name: type_name.into(),
                    kind: TypeDefKind::Alias,
                    constructors: Box::new([]),
                    type_params: type_params.iter().map(|t| (*t).into()).collect(),
                    target_type_name: None,
                    target_type_desc: None,
                    methods: methods.into_boxed_slice(),
                };
                sema_result.put_type_def(def);
            }

            // ── generic 组：进入 BUILTIN_GENERIC_TYPES + 方法注册 ──
            $(
                register(sema_result, $gname, &[$($gp),*], vec![$($gmethod),*]);
            )*
            // ── nongeneric 组：仅方法注册（有专用 ConcreteType 变体）──
            $(
                register(sema_result, $nname, &[$($np),*], vec![$($nmethod),*]);
            )*
        }
    };
}

define_builtin_types! {
    generic {
        "Throw" : ["T", "E"] = [
            sig("is_ok", vec![TypeRepr::SelfType], Some(TypeRepr::Named("bool".into())), None),
        ],
        "Channel" : ["T"] = [
            sig("send", vec![TypeRepr::SelfType, TypeRepr::Named("T".into())], Some(TypeRepr::Named("void".into())), Some(IntrinsicKind::BinOp(284))),
            sig("recv", vec![TypeRepr::SelfType], Some(TypeRepr::Named("T".into())), Some(IntrinsicKind::ChannelAwait)),
            sig("close", vec![TypeRepr::SelfType], Some(TypeRepr::Named("void".into())), Some(IntrinsicKind::UnOp(285))),
        ],
        "Atomic" : ["T"] = [
            sig("swap", vec![TypeRepr::SelfType, TypeRepr::Named("T".into())], Some(TypeRepr::Named("T".into())), None),
            sig("cas", vec![TypeRepr::SelfType, TypeRepr::Named("T".into()), TypeRepr::Named("T".into())], Some(TypeRepr::Named("bool".into())), None),
            sig("load", vec![TypeRepr::SelfType], Some(TypeRepr::Named("T".into())), None),
            sig("store", vec![TypeRepr::SelfType, TypeRepr::Named("T".into())], Some(TypeRepr::Named("void".into())), None),
        ],
        "Async" : ["T"] = [
            sig("status", vec![TypeRepr::SelfType], Some(TypeRepr::Named("str".into())), None),
            sig("await", vec![TypeRepr::SelfType], Some(TypeRepr::Named("T".into())), Some(IntrinsicKind::Await)),
            sig("cancel", vec![TypeRepr::SelfType], Some(TypeRepr::Named("void".into())), Some(IntrinsicKind::UnOp(42))),
        ],
        "Sender" : ["T"] = [
            sig("send", vec![TypeRepr::SelfType, TypeRepr::Named("T".into())], Some(TypeRepr::Named("void".into())), Some(IntrinsicKind::BinOp(284))),
            sig("close", vec![TypeRepr::SelfType], Some(TypeRepr::Named("void".into())), Some(IntrinsicKind::UnOp(285))),
        ],
        "Receiver" : ["T"] = [
            sig("recv", vec![TypeRepr::SelfType], Some(TypeRepr::Named("T".into())), Some(IntrinsicKind::ChannelAwait)),
            sig("close", vec![TypeRepr::SelfType], Some(TypeRepr::Named("void".into())), Some(IntrinsicKind::UnOp(285))),
        ],
        "Lazy" : ["T"] = [],
    }
    nongeneric {
        "array" : ["T"] = [
            sig("len", vec![TypeRepr::SelfType], Some(TypeRepr::Named("usize".into())), Some(IntrinsicKind::UnOp(35))),
            sig("is_empty", vec![TypeRepr::SelfType], Some(TypeRepr::Named("bool".into())), None),
        ],
        "str" : [] = [
            sig("len", vec![TypeRepr::SelfType], Some(TypeRepr::Named("usize".into())), Some(IntrinsicKind::UnOp(35))),
            sig("is_empty", vec![TypeRepr::SelfType], Some(TypeRepr::Named("bool".into())), None),
            sig("bytes", vec![TypeRepr::SelfType], Some(TypeRepr::Array(Box::new(TypeRepr::Named("u8".into())), None)), Some(IntrinsicKind::UnOp(287))),
        ],
        "nullable" : ["T"] = [
            sig("is_null", vec![TypeRepr::SelfType], Some(TypeRepr::Named("bool".into())), None),
        ],
    }
}

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
///
/// `visiting` 用于循环 alias 检测：若 name 已在集合中，说明出现循环 alias 链，
/// 返回 get_or_create_ref_desc(name) 而非继续递归（避免无限递归栈溢出）。
fn resolve_named_type_resolved(
    name: &str,
    type_args: &[&'static TypeDescriptor],
    sema_result: &mut SemaResult,
    visiting: &mut FxHashSet<String>,
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
    // 循环 alias 检测：name 已在 visiting 中说明出现循环，停止递归
    if visiting.contains(name) {
        return sema_result.get_or_create_ref_desc(name);
    }
    visiting.insert(name.to_string());
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
        visiting.remove(name);
        return inner_td;
    }
    if let Some(ttn) = target_name {
        // target_type_name 已知：递归解析到最终具体类型
        // resolve_named_type_resolved 总是返回描述符（永不失败），无需 fallback
        let result = resolve_named_type_resolved(&ttn, type_args, sema_result, visiting);
        visiting.remove(name);
        return result;
    }
    // 4. 其他用户自定义类型 → 创建具名描述符
    visiting.remove(name);
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
    let mut visiting: FxHashSet<String> = FxHashSet::default();
    Some(match tn {
        TypeNode::Named { name } => resolve_named_type_resolved(name, type_args, sema_result, &mut visiting),
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
/// type_id=0 → "unknown" 具名描述符；1..=MAX_BUILTIN_TYPE_ID → 静态表；
/// FIRST_DYNAMIC_TYPE_ID+ → type_descriptors 全局表或 pool。
/// 未找到 → 创建 "unknown" 具名描述符（无回退到 ref_descriptor）。
pub fn chan_type_from_type_id(
    sema_result: &mut SemaResult,
    type_id: u16,
) -> &'static TypeDescriptor {
    if type_id == 0 {
        return sema_result.get_or_create_ref_desc("unknown");
    }
    // 标量描述符 (type_id 1..=MAX_BUILTIN_TYPE_ID)：静态表 + str/null/void
    if type_id <= MAX_BUILTIN_TYPE_ID {
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
        ConcreteType::TraitObject { trait_name, .. } => {
            sema_result.get_or_create_ref_desc(trait_name)
        }
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
    // 内置标量 (type_id 1..=MAX_BUILTIN_TYPE_ID)
    for type_id in 1..=MAX_BUILTIN_TYPE_ID {
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
    bindings: FxHashMap<Box<str>, TypeHandle>,
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

use crate::ast::Ast::{
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
    decl: &'a crate::ast::Ast::Spanned<Decl<'a>>,
    ast: &AstArena<'a>,
) -> bool {
    match &decl.node {
        Decl::FunDecl { name, type_params, params, return_type, is_async, .. } => {
            ast_fun_decl_to_func_sig(sema_result, name, type_params, params, *return_type, *is_async, ast)
        }
        Decl::TypeDecl { name, type_params, def, methods, .. } => {
            ast_type_decl_to_type_def(sema_result, name, type_params, def, ast);
            // 注册 type 块内方法到 TypeDefInfo.methods（按 method_idx 索引）
            for method in methods.iter() {
                ast_method_to_func_sig(sema_result, name, method, ast);
            }
            true
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
    module: &'a crate::ast::Ast::Module<'a>,
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

/// 将模块文件路径转换为逻辑模块路径。
///
/// `std/io/Path.glue` → `std.io.Path`
/// `stdlib/std/io/Path.glue` → `std.io.Path`（去掉 stdlib/ 前缀）
/// `builtin/error/Err.glue` → `builtin.error.Err`
/// 无 .glue 后缀或为空返回 None。
pub fn module_logical_path(name: &str) -> Option<String> {
    let path = name.strip_suffix(".glue")?;
    // 去掉 stdlib/ 前缀（如果存在）
    let path = path.strip_prefix("stdlib/").unwrap_or(path);
    if path.is_empty() {
        return None;
    }
    Some(path.replace('/', "."))
}

/// 计算模块感知的表达式 key：组合模块名哈希 + ExprId。
///
/// ExprId 是模块特定的（每个模块的 AST arena 独立编号），
/// 直接用 ExprId 作为全局 key 会导致跨模块冲突。
/// 此函数将模块名与 ExprId 组合为全局唯一的 u64 key。
pub fn module_expr_key(module_name: &str, expr_id: u64) -> u64 {
    use rustc_hash::FxHasher;
    use std::hash::Hasher;
    let mut hasher = FxHasher::default();
    hasher.write(module_name.as_bytes());
    hasher.write_u64(expr_id);
    hasher.finish()
}

/// fun_decl → FuncSigInfo，注册到 sema_result.func_sigs。
///
/// 顶层函数以裸名注册。type 块内方法用 `ast_method_to_func_sig` 注册为 mangled 名 `TypeName.method`。
fn ast_fun_decl_to_func_sig<'a>(
    sema_result: &mut SemaResult,
    name: &'a str,
    type_params: &[crate::ast::Ast::TypeParam<'a>],
    params: &[crate::ast::Ast::Param<'a>],
    return_type: Option<AstTypeRef>,
    is_async: bool,
    ast: &AstArena<'a>,
) -> bool {
    let name: Box<str> = name.into();
    ast_fun_decl_to_func_sig_inner(sema_result, name, type_params, params, return_type, is_async, ast)
}

/// 从 AST MethodDecl 构造 MethodSigInfo（不注册到 func_sigs）。
///
/// 复用 `resolve_param_type` / `resolve_type_node_to_desc` 进行类型解析，
/// 产出按 method_idx 索引的方法签名，存入 TypeDefInfo.methods。
fn build_method_sig_info<'a>(
    sema_result: &mut SemaResult,
    method: &crate::ast::Ast::MethodDecl<'a>,
    ast: &AstArena<'a>,
) -> MethodSigInfo {
    let mut param_is_ref: Vec<bool> = Vec::with_capacity(method.params.len());
    let mut param_type_reprs: Vec<TypeRepr> = Vec::with_capacity(method.params.len());

    for param in &method.params {
        let (_, is_ref, _, repr) = resolve_param_type(param, ast, sema_result);
        param_is_ref.push(is_ref);
        param_type_reprs.push(repr);
    }

    let (_, return_type_repr, is_throwing) = match method.return_type {
        Some(rt) => {
            let desc = resolve_type_node_to_desc(rt, ast, sema_result);
            let repr = type_node_to_repr(&ast.ty(rt).node, ast);
            (desc, Some(repr), is_throw_type(&ast.ty(rt).node))
        }
        None => (sema_result.get_or_create_ref_desc("void"), None, false),
    };

    let return_is_ref = match method.return_type {
        Some(rt) => matches!(ast.ty(rt).node, TypeNode::RefType { .. }),
        None => false,
    };

    MethodSigInfo {
        name: method.name.into(),
        param_is_ref: param_is_ref.into_boxed_slice(),
        return_is_ref,
        is_async: method.is_async,
        is_throwing,
        param_type_reprs: param_type_reprs.into_boxed_slice(),
        return_type_repr,
        intrinsic: None,
    }
}

/// type 块内方法 → MethodSigInfo，存入 TypeDefInfo.methods（按 method_idx 索引）。
///
/// method_idx = 方法在 type 块 methods 数组中的位置（AST 声明顺序）。
/// IR 阶段通过 (type_id, method_idx) 查 method_subgraphs 获取子图。
fn ast_method_to_func_sig<'a>(
    sema_result: &mut SemaResult,
    type_name: &str,
    method: &crate::ast::Ast::MethodDecl<'a>,
    ast: &AstArena<'a>,
) -> bool {
    let sig = build_method_sig_info(sema_result, method, ast);
    if let Some(&type_idx) = sema_result.type_def_index.get(type_name) {
        let type_def = &mut sema_result.type_defs[type_idx as usize];
        let mut methods_vec: Vec<MethodSigInfo> = type_def.methods.to_vec();
        methods_vec.push(sig);
        type_def.methods = methods_vec.into_boxed_slice();
        true
    } else {
        false
    }
}

fn ast_fun_decl_to_func_sig_inner<'a>(
    sema_result: &mut SemaResult,
    name: Box<str>,
    type_params: &[crate::ast::Ast::TypeParam<'a>],
    params: &[crate::ast::Ast::Param<'a>],
    return_type: Option<AstTypeRef>,
    is_async: bool,
    ast: &AstArena<'a>,
) -> bool {

    // type_params：取每个 TypeParam 的 name
    let type_params: Box<[Box<str>]> = type_params.iter().map(|tp| tp.name.into()).collect();

    // param_is_ref：解析每个参数是否为引用类型
    let mut param_is_ref: Vec<bool> = Vec::with_capacity(params.len());

    for param in params {
        let (_, is_ref, _, _) = resolve_param_type(param, ast, sema_result);
        param_is_ref.push(is_ref);
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
        return_type_desc,
        param_is_ref: param_is_ref.into_boxed_slice(),
        return_is_ref,
        is_async,
        is_throwing,
    };

    sema_result.put_func_sig(sig)
}

/// trait_decl → TraitDefInfo，注册到 sema_result.trait_defs。
pub(crate) fn ast_trait_decl_to_trait_def<'a>(
    sema_result: &mut SemaResult,
    name: &'a str,
    methods: &[crate::ast::Ast::MethodDecl<'a>],
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
pub(crate) fn ast_type_decl_to_type_def<'a>(
    sema_result: &mut SemaResult,
    name: &'a str,
    type_params: &[crate::ast::Ast::TypeParam<'a>],
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
            let target_name = type_name_from_node(Some(*target), ast);
            (
                TypeDefKind::Alias,
                Vec::new(),
                target_name.map(|n| n.into()),
                Some(target_desc),
            )
        }
        AstTypeDef::Newtype { name: nt_name, inner } => {
            let target_desc = resolve_type_node_to_desc(*inner, ast, sema_result);
            let target_name = type_name_from_node(Some(*inner), ast);
            let target_repr = type_node_to_repr(&ast.ty(*inner).node, ast);
            let ctor = CtorDefInfo {
                name: (*nt_name).into(),
                type_name: name.clone(),
                field_names: Box::new([Some("_0".into())]),
                field_type_descs: Box::new([target_desc]),
                is_newtype: true,
                return_type_name: None,
                return_type_node: None,
                field_type_reprs: Box::new([target_repr]),
            };
            (
                TypeDefKind::Newtype,
                vec![ctor],
                target_name.map(|n| n.into()),
                Some(target_desc),
            )
        }
    };

    let type_def = TypeDefInfo {
        name,
        kind,
        constructors: constructors.into_boxed_slice(),
        type_params,
        target_type_name,
        target_type_desc,
        methods: Box::new([]),
    };

    sema_result.put_type_def(type_def)
}

// ── 辅助函数 ──

/// 解析参数类型：返回 (TypeDescriptor, is_ref, type_name, type_repr)
fn resolve_param_type<'a>(
    param: &crate::ast::Ast::Param<'a>,
    ast: &AstArena<'a>,
    sema_result: &mut SemaResult,
) -> (&'static TypeDescriptor, bool, Option<Box<str>>, TypeRepr) {
    match param.type_annotation {
        Some(tr) => {
            let node = &ast.ty(tr).node;
            let is_ref = matches!(node, TypeNode::RefType { .. });
            let desc = resolve_type_node_to_desc(tr, ast, sema_result);
            let name = type_name_from_node(Some(tr), ast).map(|n| n.into());
            let repr = type_node_to_repr(node, ast);
            (desc, is_ref, name, repr)
        }
        None => (
            sema_result.get_or_create_ref_desc("param"),
            false,
            None,
            TypeRepr::Named("unknown".into()),
        ),
    }
}

/// 将 TypeNode 解析为 TypeDescriptor（委托 Sema::resolve_type_node_concrete）。
pub(crate) fn resolve_type_node_to_desc<'a>(
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

/// 将 AST TypeNode 递归转换为自包含的 TypeRepr（不依赖 AstArena 引用）。
/// 用于在 sema 阶段将方法返回类型信息序列化存储，供后续跨模块 lookup_method_type 使用。
fn type_node_to_repr<'a>(tn: &TypeNode<'a>, ast: &AstArena<'a>) -> TypeRepr {
    match tn {
        TypeNode::Named { name } => TypeRepr::Named((*name).into()),
        TypeNode::SelfType => TypeRepr::SelfType,
        TypeNode::Generic { name, args } => {
            let repr_args: Vec<TypeRepr> = args
                .iter()
                .map(|&a| type_node_to_repr(&ast.ty(a).node, ast))
                .collect();
            TypeRepr::Generic((*name).into(), repr_args.into_boxed_slice())
        }
        TypeNode::Nullable { inner } => {
            TypeRepr::Nullable(Box::new(type_node_to_repr(&ast.ty(*inner).node, ast)))
        }
        TypeNode::RefType { inner } => {
            TypeRepr::Ref(Box::new(type_node_to_repr(&ast.ty(*inner).node, ast)))
        }
        TypeNode::RawPtr { inner } => {
            TypeRepr::RawPtr(Box::new(type_node_to_repr(&ast.ty(*inner).node, ast)))
        }
        TypeNode::Function {
            params,
            return_type,
        } => {
            let p: Vec<TypeRepr> = params
                .iter()
                .map(|&a| type_node_to_repr(&ast.ty(a).node, ast))
                .collect();
            let r = type_node_to_repr(&ast.ty(*return_type).node, ast);
            TypeRepr::Function(p.into_boxed_slice(), Box::new(r))
        }
        TypeNode::Record { .. } => TypeRepr::Named("record".into()),
        TypeNode::Array {
            element_type,
            size,
        } => TypeRepr::Array(
            Box::new(type_node_to_repr(&ast.ty(*element_type).node, ast)),
            *size,
        ),
        TypeNode::KindAnnotated { inner, .. } => {
            type_node_to_repr(&ast.ty(*inner).node, ast)
        }
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
    let mut field_type_reprs: Vec<TypeRepr> = Vec::with_capacity(c.fields.len());

    for f in &c.fields {
        field_names.push(f.name.map(|n| n.into()));
        let desc = resolve_type_node_to_desc(f.ty, ast, sema_result);
        field_type_descs.push(desc);
        field_type_reprs.push(type_node_to_repr(&ast.ty(f.ty).node, ast));
    }

    CtorDefInfo {
        name: c.name.into(),
        type_name: type_name.into(),
        field_names: field_names.into_boxed_slice(),
        field_type_descs: field_type_descs.into_boxed_slice(),
        is_newtype: false,
        return_type_name: None,
        return_type_node: c.return_type,
        field_type_reprs: field_type_reprs.into_boxed_slice(),
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
    let mut field_type_reprs: Vec<TypeRepr> = Vec::with_capacity(fields.len());

    for f in fields {
        field_names.push(Some(f.name.into()));
        let desc = resolve_type_node_to_desc(f.ty, ast, sema_result);
        field_type_descs.push(desc);
        field_type_reprs.push(type_node_to_repr(&ast.ty(f.ty).node, ast));
    }

    CtorDefInfo {
        name: type_name.into(), // record 构造器名 = 类型名
        type_name: type_name.into(),
        field_names: field_names.into_boxed_slice(),
        field_type_descs: field_type_descs.into_boxed_slice(),
        is_newtype: false,
        return_type_name: None,
        return_type_node: None,
        field_type_reprs: field_type_reprs.into_boxed_slice(),
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
// - WitnessTable 用 Vec<WitnessEntry> + FxHashMap<(trait_name, type_id), idx> 索引
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
    /// 方法槽位：method_name → method_idx（在 TypeDefInfo.methods 中的位置）
    pub method_slots: FxHashMap<Box<str>, u16>,
    /// 实现类型的名字（用于错误信息）
    pub type_name: Box<str>,
}

/// Witness table：所有 trait 实现的索引表。
///
/// 通过 (trait_name, type_id) 索引到 WitnessEntry，
/// 再通过 method_name 索引到 method slot。
#[derive(Default, Clone)]
pub struct WitnessTable {
    entries: Vec<WitnessEntry>,
    /// 索引：(trait_name, type_id) → entries 下标
    index: FxHashMap<(Box<str>, u16), u32>,
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
        method_slots: FxHashMap<Box<str>, u16>,
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

    /// 查询某 trait 实现的某方法的 method_idx。
    ///
    /// 返回方法在 TypeDefInfo.methods 中的位置索引。
    /// IR 层用 (type_id, method_idx) 查 method_subgraphs 获取子图。
    pub fn resolve_method(
        &self,
        trait_name: &str,
        type_id: u16,
        method_name: &str,
    ) -> Option<u16> {
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
