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
    lookup_by_type_id, FloatKind, IntKind, RefOps, STR_DESC,
    TypeDescriptor, TypeDescriptorPool,
    BOOL_DESC, CHAR_DESC, F64_DESC, I32_DESC, NULL_DESC, VOID_DESC,
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
    pub fn from_ast(kind: &crate::Ast::Kind) -> Self {
        match kind {
            crate::Ast::Kind::Star => SemKind::Star,
            crate::Ast::Kind::Arrow { param, result } => SemKind::Arrow {
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
    solver_snap: SnapshotId,
    arena_snap: ArenaSnapshot,
}

/// `ConcreteType` 分配器：arena-based，管理类型槽与类型变量。
///
/// 所有 `ConcreteType` 通过 `make` 分配并返回 `TypeHandle` 索引；类型变量通过
/// `fresh_type_var` / `fresh_rigid_var` 分配。`resolve`/`occurs`/`unify` 作为方法，
/// 因为复合类型的子节点遍历需要访问 `&self` / `&mut self`。
pub struct TypeArena {
    types: Vec<ConcreteType>,
    type_vars: Vec<TypeVar>,
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
    /// Nullable 内部类型描述符（`type_desc.is_nullable()` 时有效）
    pub inner_type_desc: Option<&'static TypeDescriptor>,
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
            is_trait_object: false,
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
    /// 字段类型的自包含表示（不依赖 AST 引用），用于跨模块完整还原字段类型
    /// （包括数组、Nullable、Ref 等复合类型，克服 field_type_names 仅存顶层名的限制）。
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

/// 替代旧的 func_sigs mangled name（"TypeName.method"）注册方式，
/// 使方法分派通过 (type_id, method_idx) 结构化键驱动。
#[derive(Debug, Clone)]
pub struct MethodSigInfo {
    pub name: Box<str>,
    pub param_type_descs: Box<[&'static TypeDescriptor]>,
    pub return_type_desc: &'static TypeDescriptor,
    pub param_is_ref: Box<[bool]>,
    pub return_is_ref: bool,
    pub is_async: bool,
    pub is_throwing: bool,
    pub param_type_names: Box<[Option<Box<str>>]>,
    /// 参数类型的自包含表示（不依赖 AST 引用），用于跨模块完整还原参数类型
    /// （包括数组、Nullable、Ref 等复合类型，克服 type_name 仅存顶层名的限制）。
    pub param_type_reprs: Box<[TypeRepr]>,
    /// 返回类型的自包含表示（不依赖 AST 引用），用于跨模块完整解析嵌套泛型类型
    /// （如 Async<Throw<T, E>>）。type_name/type_desc 仅存顶层名，无法还原泛型参数。
    pub return_type_repr: Option<TypeRepr>,
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
    pub param_type_descs: Box<[&'static TypeDescriptor]>,
    pub return_type_desc: &'static TypeDescriptor,
    /// 每个参数是否为 `&T` 引用语义
    pub param_is_ref: Box<[bool]>,
    pub return_is_ref: bool,
    pub is_async: bool,
    pub is_throwing: bool,
    /// 参数类型名（消除 IR 侧 findFuncParamsAst AST 回退）
    pub param_type_names: Box<[Option<Box<str>>]>,
    /// 参数类型的自包含表示（与 MethodSigInfo.param_type_reprs 对齐）
    pub param_type_reprs: Box<[TypeRepr]>,
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
        if type_id < 22 {
            return None;
        }
        let type_idx = (type_id - 22) as usize;
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
    /// 模块路径 → 模块专属 EnvId 的映射。
    ///
    /// 每个模块（含路径前缀）在注册时创建一个专属 env（parent 指向 root_env 或父路径 env），
    /// 模块的函数/类型注册于此 env。ModuleRef 查找时直接在对应 env 中按裸名查找，无需 mangled name。
    ///
    /// 层级结构示例：
    ///   "std"            → env_std (parent=root_env)，绑定 "io"→ModuleRef("std.io", env_std_io)
    ///   "std.io"         → env_std_io (parent=env_std)，绑定 "File"→ModuleRef("std.io.File", env_std_io_file)
    ///   "std.io.File"    → env_std_io_file (parent=env_std_io)，绑定 "open"→Fn(...)
    ///
    /// 这使得 `std.io.File.open(...)` 的查找完全通过 env 链结构化进行：
    ///   std → env_std.lookup("io") → ModuleRef("std.io", env_std_io)
    ///       → env_std_io.lookup("File") → ModuleRef("std.io.File", env_std_io_file)
    ///       → Call: env_std_io_file.lookup("open") → Fn(...)
    pub module_envs: FxHashMap<String, EnvId>,
    /// 当前正在检查的模块的逻辑路径（如 "Math.Geometry"），用于注册 mangled 名
    /// 在 check_module_with_env 开始时设置，供 infer_stmt 等不接收 module 参数的方法使用
    pub current_module_logical_path: Option<String>,
    /// 当前正在检查的模块的专属 EnvId。
    /// 在 check_module_with_env 开始时从 module_envs 中查找，predeclare_declarations 时用于注册符号。
    pub current_module_env: Option<EnvId>,
    /// 当前正在检查的模块的文件名（如 "Math/Geometry.glue"），用于 expr_types 复合 key
    /// 避免不同模块的 ExprId 在全局 expr_types 中冲突
    pub current_module_name: String,
    /// 诊断追踪表：记录每个表达式推断结果的 (TypeHandle, Span)，用于反向定位未解析 TypeVar 的代码位置。
    /// 仅在 GLUE_SEMA_TRACE 启用时填充，避免正常编译的内存开销。
    pub type_trace: Vec<(TypeHandle, crate::Ast::Span)>,
}

/// 检查类型是否引用了任何未解析的 TypeVar（在 unresolved_set 中）。
/// 用于诊断阶段反向定位未解析 TypeVar 的表达式位置。
fn type_contains_any_unresolved(
    ty: TypeHandle,
    arena: &TypeArena,
    unresolved_set: &FxHashSet<u32>,
) -> bool {
    let resolved = arena.resolve(ty);
    match arena.get(resolved) {
        ConcreteType::TypeVar(idx) => unresolved_set.contains(idx),
        ConcreteType::Fn { params, return_type } => {
            params.iter().any(|&p| type_contains_any_unresolved(p, arena, unresolved_set))
                || type_contains_any_unresolved(*return_type, arena, unresolved_set)
        }
        ConcreteType::Record { fields, .. } => fields
            .iter()
            .any(|f| type_contains_any_unresolved(f.ty, arena, unresolved_set)),
        ConcreteType::Adt { type_args, .. } => type_args
            .iter()
            .any(|&a| type_contains_any_unresolved(a, arena, unresolved_set)),
        ConcreteType::Nullable(inner) => {
            type_contains_any_unresolved(*inner, arena, unresolved_set)
        }
        ConcreteType::Ref { inner, .. } => {
            type_contains_any_unresolved(*inner, arena, unresolved_set)
        }
        ConcreteType::Generic { args, .. } => args
            .iter()
            .any(|&a| type_contains_any_unresolved(a, arena, unresolved_set)),
        ConcreteType::Array { element_type, .. } => {
            type_contains_any_unresolved(*element_type, arena, unresolved_set)
        }
        ConcreteType::Throw { value_type, error_type } => {
            type_contains_any_unresolved(*value_type, arena, unresolved_set)
                || type_contains_any_unresolved(*error_type, arena, unresolved_set)
        }
        ConcreteType::Trait { type_args, .. } => type_args
            .iter()
            .any(|&a| type_contains_any_unresolved(a, arena, unresolved_set)),
        _ => false,
    }
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
            module_envs: FxHashMap::default(),
            current_module_logical_path: None,
            current_module_env: None,
            current_module_name: String::new(),
            type_trace: Vec::new(),
        }
    }

    // ── 尝试性推断的统一 snapshot/rollback ──

    /// 尝试性推断的状态快照：同时保存 solver 和 arena 状态。
    ///
    /// ConstraintSolver 的 snapshot 只保存 subst/candidates/errors/pending，
    /// 但 `unify` 直接修改 `type_vars[].bound`，`unify_kind` 直接修改 `kind_vars`。
    /// 本快照补充 arena 层状态，确保回退时完全一致。
    pub fn snapshot_type_state(&mut self) -> TypeStateSnapshot {
        TypeStateSnapshot {
            solver_snap: self.solver.snapshot(),
            arena_snap: self.arena.snapshot_arena(),
        }
    }

    /// Rollback 到快照状态：同时回退 solver 和 arena。
    pub fn rollback_type_state(&mut self, snap: TypeStateSnapshot) {
        self.solver.rollback(snap.solver_snap);
        self.arena.restore_arena(&snap.arena_snap);
    }

    /// Commit 快照：保留求解结果，丢弃快照。
    pub fn commit_type_state(&mut self, snap: TypeStateSnapshot) {
        self.solver.commit(snap.solver_snap);
        // arena 状态保留（commit 确认结果）
    }

    // ── 类型绑定栈操作 ──

    /// 进入泛型作用域：为每个类型参数分配 rigid var 并压栈。
    /// 未声明 kind 的参数默认 Star，声明的 kind 用于 HKT 检查。
    pub fn push_type_bindings(&mut self, type_params: &[(&str, Option<SemKind>)]) {
        self.type_binding_stack.push();
        for &(name, ref kind_opt) in type_params {
            let var = match kind_opt {
                Some(kind) => self.arena.fresh_rigid_var_with_kind(kind.clone()),
                None => self.arena.fresh_rigid_var(),
            };
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

    /// 进入 trait 默认方法：Self 绑定到 fresh_rigid_var（待 impl 时 unify 求解）。
    /// 用 rigid var 表示 Self 是模板参数，诊断时自动排除（非 rigid 的未绑定 TypeVar 才报错）。
    pub fn push_self_type_var(&mut self) -> TypeHandle {
        let var = self.arena.fresh_rigid_var();
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

    /// 带位置信息的错误添加（用于有 AST span 上下文的调用点）。
    pub fn add_error_at(&mut self, message: &str, line: u32, column: u32) {
        self.sema_result.add_error(SemaError::new(message, line, column));
    }

    // ── self 参数解析（phase3b）──

    /// 判断参数的 type_annotation 是否为 SelfType（或 RefType<SelfType>）。
    ///
    /// 解析器对 type/trait 块内方法的 `self`/`&self` 自动填充 SelfType 注解，
    /// Sema 通过此类型节点判断是否为 self 参数，而非依赖参数名。
    fn is_self_param(&self, type_annotation: Option<AstTypeRef>, ast: &AstArena<'_>) -> bool {
        match type_annotation {
            Some(ta) => match &ast.ty(ta).node {
                crate::Ast::TypeNode::SelfType => true,
                crate::Ast::TypeNode::RefType { inner } => {
                    matches!(ast.ty(*inner).node, crate::Ast::TypeNode::SelfType)
                }
                _ => false,
            },
            None => false,
        }
    }

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
                // 从 type_annotation 获取 span（若有），否则无位置信息
                let (line, column) = type_annotation
                    .map(|ta| {
                        let s = ast.ty(ta).span;
                        (s.line, s.column)
                    })
                    .unwrap_or((0, 0));
                self.add_error_at(
                    "self parameter requires enclosing type or trait block",
                    line,
                    column,
                );
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
                let span = ast.ty(ta).span;
                match tn {
                    // `self`（解析器自动填 SelfType）→ 返回 scope 类型
                    TypeNode::SelfType => self_ty,
                    // `&self`（解析器自动填 RefType<SelfType>）→ 返回 Ref<scope类型>
                    TypeNode::RefType { inner } => {
                        if matches!(ast.ty(*inner).node, TypeNode::SelfType) {

                            self.arena.make(ConcreteType::Ref {
                                inner: self_ty,
                                is_raw: false,
                            })
                        } else {
                            // `&self: &Foo` 用户显式写引用注解 → 报错
                            self.add_error_at(
                                "self parameter does not allow explicit type annotation",
                                span.line,
                                span.column,
                            );
                            self.arena.fresh_type_var()
                        }
                    }
                    // `self: Foo` 用户显式写注解 → 报错
                    _ => {
                        self.add_error_at(
                            "self parameter does not allow explicit type annotation",
                            span.line,
                            span.column,
                        );
                        self.arena.fresh_type_var()
                    }
                }
            }
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
        let mut subst: FxHashMap<u32, TypeHandle> = FxHashMap::default();
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
            // unify 成功立即绑定，失败注册约束供不动点迭代重试
            self.unify_or_constrain(param_ty, arg_ty);
        }

        // 3. resolve 所有 TypeVar（未绑定的保持 TypeVar）
        let mut result: Vec<TypeHandle> = Vec::with_capacity(type_args.len());
        for &ta in type_args.iter() {
            result.push(self.arena.resolve(ta));
        }

        Some(result)
    }

    /// 递归收集类型中的所有 TypeVar idx，填入 subst（值为占位 TypeHandle(0)，仅用 key）。
    fn collect_type_vars(&self, ty: TypeHandle, subst: &mut FxHashMap<u32, TypeHandle>) {
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
            ConcreteType::TraitObject { .. } => {}
            _ => {}
        }
    }

    /// 实例化函数类型：为签名中所有未绑定 TypeVar 创建 fresh 非刚性副本。
    ///
    /// 多态内置函数（Ok/i8 等用 rigid var 注册的泛型函数）每次调用时必须实例化，
    /// 否则不同调用的类型约束会相互冲突（第一次调用永久绑定后，后续调用无法 unify）。
    /// 非多态函数（签名无 TypeVar）原样返回。
    fn instantiate_fn_type(&mut self, fn_ty: TypeHandle) -> TypeHandle {
    let resolved = self.arena.resolve(fn_ty);
    // 收集函数签名中所有未绑定 TypeVar idx（collect_type_vars 跟随 resolve，
    // 已绑定的 TypeVar 不会被收集）
    let mut subst: FxHashMap<u32, TypeHandle> = FxHashMap::default();
    if let ConcreteType::Fn { params, return_type } = self.arena.get(resolved) {
        for &p in params.iter() {
            self.collect_type_vars(p, &mut subst);
        }
        self.collect_type_vars(*return_type, &mut subst);
    } else {
        return resolved;
    }
    if subst.is_empty() {
        return resolved;
    }
    // 为每个 idx 创建 fresh non-rigid var（collect_type_vars 借用已释放，可安全可变借用）
    let indices: Vec<u32> = subst.keys().copied().collect();
    for idx in indices {
        let fresh = self.arena.fresh_type_var();
        subst.insert(idx, fresh);
    }
    self.substitute_type(resolved, &subst)
}

    /// 类型替换：将类型中的指定 TypeVar（按 idx）替换为绑定表中的类型。
    ///
    /// 递归遍历复合类型，替换匹配的 TypeVar。用于将形参的 rigid var 替换为
    /// 调用点的 fresh 非刚性 var，使其可被 unify 绑定。
    fn substitute_type(&mut self, ty: TypeHandle, subst: &FxHashMap<u32, TypeHandle>) -> TypeHandle {
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
            ConcreteType::TraitObject { trait_name, method_sigs } => {
                self.arena.make(ConcreteType::TraitObject {
                    trait_name,
                    method_sigs,
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
    /// **Throw 错误分支**：当 expected_ty 是 Throw 类型且构造器是 error_newtype
    /// ADT 构造器时，`is_throw_error_branch` 标志为真，构造器返回类型与子模式
    /// 统一绑定到 error_type。该标志贯穿返回类型解析与子模式绑定两个步骤，
    /// 无独立早退分支，与常规 GADT 路径走同一控制流。
    pub fn refine_constructor_pattern(
        &mut self,
        ctor_name: &str,
        sub_patterns: &[PatternRef],
        expected_ty: TypeHandle,
        ast: &AstArena<'_>,
        env: EnvId,
    ) -> bool {
        // 使用 field_type_reprs（自包含 TypeRepr）替代 field_type_nodes（AST 引用），
        // 避免跨模块使用时 AST arena 不匹配导致 TypeRef 索引指向错误类型节点。
        // return_type_node 仍用 AstTypeRef（GADT 场景少且通常同模块）。
        type CtorInfoSnapshot = (Box<str>, bool, Option<AstTypeRef>, Box<[TypeRepr]>);
        let resolved_expected = self.arena.resolve(expected_ty);

        // 先克隆构造器信息，避免 &CtorDefInfo 借用阻塞后续 &mut self 调用
        let ctor_info: Option<CtorInfoSnapshot> =
            self.find_ctor_def(ctor_name).map(|c| {
                (
                    c.type_name.clone(),
                    c.is_newtype,
                    c.return_type_node,
                    c.field_type_reprs.clone(),
                )
            });

        let (type_name, is_newtype, return_type_node, field_type_reprs) = match ctor_info {
            Some(info) => info,
            None => return false,
        };

        // 判定是否为 Throw 错误分支构造器：
        // expected 是 Throw 类型且构造器是 error_newtype ADT 构造器时，
        // 构造器作为 Throw 错误分支，返回类型与子模式均绑定到 error_type。
        let expected_ct = self.arena.get(resolved_expected).clone();
        let error_type = match &expected_ct {
            ConcreteType::Throw { error_type, .. } => Some(*error_type),
            _ => None,
        };
        let is_throw_error_branch = error_type.is_some() && is_newtype;

        // 解析构造器返回类型（统一路径，无早退）：
        // - Throw 错误分支 → error_type
        // - GADT 构造器    → return_type_node
        // - 普通 ADT      → type_name 对应的 Adt
        let ctor_return_ty = if is_throw_error_branch {
            error_type.expect("is_throw_error_branch implies error_type is Some")
        } else if let Some(rtn) = return_type_node {
            self.resolve_type_node_to_handle(rtn, ast)
        } else {
            self.arena.make(ConcreteType::Adt {
                name: type_name,
                type_args: Box::new([]),
            })
        };

        // unify 构造器返回类型与期望类型，实现 GADT 类型精化
        // 失败时注册约束供不动点迭代重试
        self.unify_or_constrain(ctor_return_ty, expected_ty);

        // 对子模式按构造器字段类型递归推断并绑定变量（统一路径，无早退）：
        // - Throw 错误分支 → error_type
        // - 常规          → 构造器字段类型
        for (i, &sub_pat) in sub_patterns.iter().enumerate() {
            let sub_ty = if is_throw_error_branch {
                error_type.expect("is_throw_error_branch implies error_type is Some")
            } else if i < field_type_reprs.len() {
                self.type_repr_to_handle(&field_type_reprs[i])
            } else {
                self.arena.fresh_type_var()
            };
            self.infer_pattern(sub_pat, ast, sub_ty, env);
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
    type_params: &[crate::Ast::TypeParam<'a>],
    params: &[crate::Ast::Param<'a>],
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
    method: &crate::Ast::MethodDecl<'a>,
    ast: &AstArena<'a>,
) -> MethodSigInfo {
    let mut param_type_descs: Vec<&'static TypeDescriptor> = Vec::with_capacity(method.params.len());
    let mut param_is_ref: Vec<bool> = Vec::with_capacity(method.params.len());
    let mut param_type_names: Vec<Option<Box<str>>> = Vec::with_capacity(method.params.len());
    let mut param_type_reprs: Vec<TypeRepr> = Vec::with_capacity(method.params.len());

    for param in &method.params {
        let (desc, is_ref, name, repr) = resolve_param_type(param, ast, sema_result);
        param_type_descs.push(desc);
        param_is_ref.push(is_ref);
        param_type_names.push(name);
        param_type_reprs.push(repr);
    }

    let (return_type_desc, return_type_repr, is_throwing) = match method.return_type {
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
        param_type_descs: param_type_descs.into_boxed_slice(),
        return_type_desc,
        param_is_ref: param_is_ref.into_boxed_slice(),
        return_is_ref,
        is_async: method.is_async,
        is_throwing,
        param_type_names: param_type_names.into_boxed_slice(),
        param_type_reprs: param_type_reprs.into_boxed_slice(),
        return_type_repr,
    }
}

/// type 块内方法 → MethodSigInfo，存入 TypeDefInfo.methods（按 method_idx 索引）。
///
/// method_idx = 方法在 type 块 methods 数组中的位置（AST 声明顺序）。
/// IR 阶段通过 (type_id, method_idx) 查 method_subgraphs 获取子图。
fn ast_method_to_func_sig<'a>(
    sema_result: &mut SemaResult,
    type_name: &str,
    method: &crate::Ast::MethodDecl<'a>,
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
    type_params: &[crate::Ast::TypeParam<'a>],
    params: &[crate::Ast::Param<'a>],
    return_type: Option<AstTypeRef>,
    is_async: bool,
    ast: &AstArena<'a>,
) -> bool {

    // type_params：取每个 TypeParam 的 name
    let type_params: Box<[Box<str>]> = type_params.iter().map(|tp| tp.name.into()).collect();

    // param_type_descs：解析每个参数的类型注解
    let mut param_type_descs: Vec<&'static TypeDescriptor> = Vec::with_capacity(params.len());
    let mut param_is_ref: Vec<bool> = Vec::with_capacity(params.len());
    let mut param_type_names: Vec<Option<Box<str>>> = Vec::with_capacity(params.len());
    let mut param_type_reprs: Vec<TypeRepr> = Vec::with_capacity(params.len());

    for param in params {
        let (desc, is_ref, name, repr) = resolve_param_type(param, ast, sema_result);
        param_type_descs.push(desc);
        param_is_ref.push(is_ref);
        param_type_names.push(name);
        param_type_reprs.push(repr);
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
        param_type_reprs: param_type_reprs.into_boxed_slice(),
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
            let target_repr = type_node_to_repr(&ast.ty(*inner).node, ast);
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
    param: &crate::Ast::Param<'a>,
    ast: &AstArena<'a>,
    sema_result: &mut SemaResult,
) -> (&'static TypeDescriptor, bool, Option<Box<str>>, TypeRepr) {
    match param.type_annotation {
        Some(tr) => {
            let node = &ast.ty(tr).node;
            let is_ref = matches!(node, TypeNode::RefType { .. });
            let desc = resolve_type_node_to_desc(tr, ast, sema_result);
            let name = type_name_from_type_node(node).map(|n| n.into());
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
    let mut field_type_names: Vec<Option<Box<str>>> = Vec::with_capacity(c.fields.len());
    let mut field_type_nodes: Vec<Option<AstTypeRef>> = Vec::with_capacity(c.fields.len());
    let mut field_type_reprs: Vec<TypeRepr> = Vec::with_capacity(c.fields.len());

    for f in &c.fields {
        field_names.push(f.name.map(|n| n.into()));
        let desc = resolve_type_node_to_desc(f.ty, ast, sema_result);
        field_type_descs.push(desc);
        field_type_names.push(type_name_from_type_node(&ast.ty(f.ty).node).map(|n| n.into()));
        field_type_nodes.push(Some(f.ty));
        field_type_reprs.push(type_node_to_repr(&ast.ty(f.ty).node, ast));
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
    let mut field_type_names: Vec<Option<Box<str>>> = Vec::with_capacity(fields.len());
    let mut field_type_nodes: Vec<Option<AstTypeRef>> = Vec::with_capacity(fields.len());
    let mut field_type_reprs: Vec<TypeRepr> = Vec::with_capacity(fields.len());

    for f in fields {
        field_names.push(Some(f.name.into()));
        let desc = resolve_type_node_to_desc(f.ty, ast, sema_result);
        field_type_descs.push(desc);
        field_type_names.push(type_name_from_type_node(&ast.ty(f.ty).node).map(|n| n.into()));
        field_type_nodes.push(Some(f.ty));
        field_type_reprs.push(type_node_to_repr(&ast.ty(f.ty).node, ast));
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
        field_type_reprs: field_type_reprs.into_boxed_slice(),
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
    func_decls: FxHashMap<&'a str, &'a Spanned<Decl<'a>>>,
    /// 循环检测：正在实例化的 cache_key → instance_id（前向引用支持）
    in_progress: FxHashMap<String, u32>,
    /// 当前模块名（用于 expr_types 复合 key）
    module_name: &'a str,
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

    let mut name_to_td: FxHashMap<&str, &'static TypeDescriptor> = FxHashMap::default();

    let is_type_param = |name: &str| sig.type_params.iter().any(|tp| tp.as_ref() == name);

    let param_count = fd.params.len().min(arguments.len());

    // Pass 1: 匹配 .named 类型注解（如 `init: A` → 实参类型）
    for (i, arg) in arguments.iter().enumerate().take(param_count) {
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
        let arg_key = module_expr_key(ctx.module_name, arg.0 as u64);
        if let Some(info) = sema_result.get_expr(arg_key) {
            name_to_td.insert(pname, td_from_expr_info(info));
        }
    }

    // Pass 2: 匹配 .function 类型注解（如 `f: (A, T) -> A`）against lambda 实参
    for (i, arg) in arguments.iter().enumerate().take(param_count) {
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
        let lambda = match &ctx.ast.expr(*arg).node {
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
            let key = module_expr_key(ctx.module_name, body_expr.0 as u64);
            sema_result
                .get_expr(key)
                .map(td_from_expr_info)
        }
        LambdaBody::Block(block_expr) => {
            if let Expr::Block { trailing: Some(trailing), .. } = &ctx.ast.expr(*block_expr).node {
                let key = module_expr_key(ctx.module_name, trailing.0 as u64);
                return sema_result
                    .get_expr(key)
                    .map(td_from_expr_info);
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
    func_decls: &FxHashMap<&'a str, &'a Spanned<Decl<'a>>>,
    in_progress: &mut FxHashMap<String, u32>,
    sema_result: &mut SemaResult,
    module_name: &'a str,
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
        expr_types: FxHashMap::default(),
        field_accesses: FxHashMap::default(),
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
        module_name,
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
#[allow(clippy::too_many_arguments)]
fn process_call<'a>(
    callee: ExprId,
    arguments: &[ExprId],
    type_args_hint: Option<&[AstTypeRef]>,
    call_expr: ExprId,
    ast: &'a AstArena<'a>,
    func_decls: &FxHashMap<&'a str, &'a Spanned<Decl<'a>>>,
    in_progress: &mut FxHashMap<String, u32>,
    sema_result: &mut SemaResult,
    module_name: &'a str,
) {
    // 仅处理直接标识符调用：foo(args) 或 foo<T>(args)
    let func_name = match &ast.expr(callee).node {
        Expr::Ident(name) => *name,
        _ => return,
    };

    // 查函数签名：跳过未注册函数与非泛型函数
    let sig_owned: Option<FuncSigInfo> = sema_result
        .get_func_sig(func_name).cloned();
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
        in_progress: FxHashMap::default(),
        module_name: "",
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
        module_name,
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
#[allow(clippy::too_many_arguments)]
fn process_method_call<'a>(
    method: &str,
    arguments: &[ExprId],
    type_args_hint: Option<&[AstTypeRef]>,
    call_expr: ExprId,
    ast: &'a AstArena<'a>,
    func_decls: &FxHashMap<&'a str, &'a Spanned<Decl<'a>>>,
    in_progress: &mut FxHashMap<String, u32>,
    sema_result: &mut SemaResult,
    module_name: &'a str,
) {
    // 直接以方法名查 func_sig（覆盖同名顶层函数的罕见场景）
    let sig_owned: Option<FuncSigInfo> = sema_result.get_func_sig(method).cloned();
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
        in_progress: FxHashMap::default(),
        module_name,
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
        module_name,
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
    let node = &ctx.ast.stmt(stmt).node;
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
        Stmt::LocalDecl { decl } => match decl.as_ref() {
            crate::Ast::Decl::FunDecl { body, .. } => {
                walk_expr(*body, ctx, sema_result);
            }
            crate::Ast::Decl::TypeDecl { methods, .. }
            | crate::Ast::Decl::TraitDecl { methods, .. } => {
                for m in methods.iter() {
                    if let Some(body) = m.body {
                        walk_expr(body, ctx, sema_result);
                    }
                }
            }
            _ => {}
        },
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
                ctx.module_name,
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
                ctx.module_name,
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
                ctx.module_name,
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
        func_decls: FxHashMap::default(),
        in_progress: FxHashMap::default(),
        module_name: module.name,
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
                        expr_types: FxHashMap::default(),
                        field_accesses: FxHashMap::default(),
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
    bindings: Vec<FxHashMap<&'a str, &'static TypeDescriptor>>,
    /// 类型参数名 → type_args 索引（快速查找）
    type_param_map: FxHashMap<&'a str, u16>,
    func_decls: &'a FxHashMap<&'a str, &'a Spanned<Decl<'a>>>,
    in_progress: &'a mut FxHashMap<String, u32>,
    /// 当前模块名（用于 expr_types 复合 key）
    module_name: &'a str,
}

impl<'a, 'b> ResolveCtx<'a, 'b> {
    fn push_scope(&mut self) {
        self.bindings.push(FxHashMap::default());
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
    func_decls: &'a FxHashMap<&'a str, &'a Spanned<Decl<'a>>>,
    in_progress: &mut FxHashMap<String, u32>,
    sema_result: &mut SemaResult,
    type_args: &[&'static TypeDescriptor],
    module_name: &'a str,
) {
    let mut type_param_map: FxHashMap<&'a str, u16> = FxHashMap::default();
    for (i, tp) in fd.type_params.iter().enumerate() {
        type_param_map.insert(tp.name, i as u16);
    }

    let bindings: Vec<FxHashMap<&'a str, &'static TypeDescriptor>> = vec![FxHashMap::default()];

    let mut rctx = ResolveCtx {
        instance,
        sema_result,
        ast,
        type_args,
        bindings,
        type_param_map,
        func_decls,
        in_progress,
        module_name,
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
        .get_func_sig(func_name).cloned();
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
        ctx.module_name,
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
        ctx.module_name,
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
#[allow(clippy::too_many_arguments)]
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
    module_name: &str,
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

    let mut name_to_td: FxHashMap<&str, &'static TypeDescriptor> = FxHashMap::default();

    let is_type_param = |name: &str| sig.type_params.iter().any(|tp| tp.as_ref() == name);

    let param_count = fd.params.len().min(arguments.len());

    // Pass 1: .named 类型注解
    for (i, arg) in arguments.iter().enumerate().take(param_count) {
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
        let arg_key = module_expr_key(module_name, arg.0 as u64);
        if let Some(info) = sema_result.get_expr(arg_key) {
            name_to_td.insert(pname, td_from_expr_info(info));
        }
    }

    // Pass 2: .function 类型注解 → lambda 实参的参数类型注解
    for (i, arg) in arguments.iter().enumerate().take(param_count) {
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
        let (lambda_params, lambda_rt) = match &ast.expr(*arg).node {
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
            let stmts: Vec<StmtId> = stmts.to_vec();
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
            let span = ast.stmt(stmt).span;
            resolve_expr(*iterable, ctx);
            ctx.push_scope();
            let iter_td = resolve_expr_type(*iterable, ctx)
                .unwrap_or_else(|| ctx.sema_result.get_or_create_ref_desc("unknown"));
            // 检查 iterable 类型 implement Iterator
            // 已知迭代器类型：Iterator(trait 值)/ArrayIter/RangeIterator/StringIterator
            // 已知非迭代器类型：array/str/基元类型 → 报错提示用 .iter()
            // 其他类型（用户自定义）放行（witness_table 在 InferContext 中，此路径不可访问）
            let iter_type_name = iter_td.type_name;
            const NON_ITERATOR_TYPES: &[&str] = &[
                "array", "str", "i32", "i64", "f32", "f64", "bool",
                "u8", "u16", "u32", "u64", "f128", "void", "null",
            ];
            if NON_ITERATOR_TYPES.contains(&iter_type_name) {
                ctx.sema_result.add_error(SemaError::new(
                    &format!(
                        "类型 '{}' 未实现 Iterator，For 循环要求迭代器类型。数组请用 arr.iter()，字符串请用 str_iter(s)",
                        iter_type_name
                    ),
                    span.line,
                    span.column,
                ));
            }
            ctx.define_var(name, iter_td);
            resolve_expr(*body, ctx);
            ctx.pop_scope();
        }
        Stmt::While { condition, body } => {
            resolve_expr(*condition, ctx);
            resolve_expr(*body, ctx);
        }
        Stmt::Loop { body } => resolve_expr(*body, ctx),
        Stmt::LocalDecl { decl } => match decl.as_ref() {
            crate::Ast::Decl::FunDecl { body, .. } => {
                resolve_expr(*body, ctx);
            }
            crate::Ast::Decl::TypeDecl { methods, .. }
            | crate::Ast::Decl::TraitDecl { methods, .. } => {
                for m in methods.iter() {
                    if let Some(body) = m.body {
                        resolve_expr(body, ctx);
                    }
                }
            }
            _ => {}
        },
    }
}

/// 解析 match pattern 中的变量绑定
fn resolve_pattern<'a, 'b>(pattern: PatternRef, ctx: &mut ResolveCtx<'a, 'b>) {
    let ast = ctx.ast;
    let node = &ast.pattern(pattern).node;
    match node {
        Pattern::Variable { name } => {
            // 无参 ADT 构造器不应注册为变量绑定
            if !ctx.sema_result.ctor_def_index.contains_key(*name) {
                let td = ctx.sema_result.get_or_create_ref_desc("pattern_var");
                ctx.define_var(name, td);
            }
        }
        Pattern::Constructor { patterns, .. } => {
            let patterns: Vec<PatternRef> = patterns.to_vec();
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
            let key = module_expr_key(ctx.module_name, expr.0 as u64);
            ctx.sema_result
                .get_expr(key)
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
            let key = module_expr_key(ctx.module_name, expr.0 as u64);
            match ctx
                .sema_result
                .get_expr(key)
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
        _ => {
            let key = module_expr_key(ctx.module_name, expr.0 as u64);
            ctx
                .sema_result
                .get_expr(key)
                .map(td_from_expr_info)
        }
    }
}

/// 提取 callee 为 Ident 时的函数名（供 `process_call_in_body` 使用）。
fn callee_name<'a>(ast: &AstArena<'a>, callee: ExprId) -> &'a str {
    match &ast.expr(callee).node {
        Expr::Ident(name) => name,
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
        (
            ConcreteType::TraitObject { trait_name: na, method_sigs: ma },
            ConcreteType::TraitObject { trait_name: nb, method_sigs: mb },
        ) => {
            na == nb
                && ma.len() == mb.len()
                && ma.iter().zip(mb.iter()).all(|(a, b)| {
                    a.name == b.name && a.param_count == b.param_count
                })
        }
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

/// ADT 同名子类型：直接比较类型名。
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
/// record → ADT 同名 → throw。`trait 结构化` 子类型需
/// `sema_result`，由调用方通过 `is_trait_structural_subtype` 判定。
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
/// 全部未命中返回 `false`。`trait 结构化` 子类型需
/// `sema_result`，由调用方通过 `is_trait_structural_subtype` 判定。
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
    match_record_fields(arena, sup_fields, sub_fields, is_subtype)
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
    type_param_names.contains(&name)
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

/// 内置 cast 函数注册表：(函数名, 是否 try 变体)。
/// 新增 cast 变体只需追加一行，无需新增函数名特判分支。
const CAST_BUILTINS: &[(&str, bool)] = &[
    ("__cast_to", false),
    ("__cast_try_to", true),
];

impl<'a> InferContext<'a> {
    // ── 类型解析（typeFromAst）──

    /// 将 AST TypeNode 解析为 TypeHandle（便捷版，无类型参数映射）。
    pub fn type_from_ast(&mut self, type_ref: AstTypeRef, ast: &AstArena<'_>) -> TypeHandle {
        let empty = FxHashMap::default();
        self.type_from_ast_with_params(type_ref, ast, &empty)
    }

    /// 按名称解析为 TypeHandle（别名穿透 + 循环检测）。
    ///
    /// 这是 Named 类型解析的核心：type_param_map → type_binding → 内置标量 →
    /// trait → type_defs 中的 Alias 递归展开 → 用户自定义 Adt。
    /// `visiting` 用于 alias 循环检测（A→B→A），出现循环时返回 Adt(name) 终止。
    fn resolve_name_to_type(
        &mut self,
        name: &str,
        type_param_map: &FxHashMap<String, TypeHandle>,
        visiting: &mut FxHashSet<String>,
    ) -> TypeHandle {
        // 1. 类型参数映射
        if let Some(ty) = type_param_map.get(name) {
            return *ty;
        }
        // 2. 类型绑定栈（泛型作用域）
        if let Some(ty) = self.lookup_type_binding(name) {
            return ty;
        }
        // 3. 内置标量
        match name {
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
                name: name.into(),
                type_args: Box::new([]),
            });
        }
        // 循环 alias 检测
        if visiting.contains(name) {
            return self.arena.make(ConcreteType::Adt {
                name: name.into(),
                type_args: Box::new([]),
            });
        }
        visiting.insert(name.to_string());
        // 5. 别名穿透：type Name = str → 解析 str
        let alias_target: Option<String> = self
            .sema_result
            .get_type_def(name)
            .filter(|td| td.kind == TypeDefKind::Alias)
            .and_then(|td| td.target_type_name.as_deref().map(String::from));
        if let Some(target_name) = alias_target {
            let result = self.resolve_name_to_type(&target_name, type_param_map, visiting);
            visiting.remove(name);
            return result;
        }
        visiting.remove(name);
        // 6. 用户自定义类型 → Adt
        self.arena.make(ConcreteType::Adt {
            name: name.into(),
            type_args: Box::new([]),
        })
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
        type_param_map: &FxHashMap<String, TypeHandle>,
    ) -> TypeHandle {
        let tn = &ast.ty(type_ref).node;
        match tn {
            TypeNode::Named { name } => {
                // 委托 resolve_name_to_type：内置标量 → trait → 别名穿透 → Adt
                let mut visiting = FxHashSet::default();
                self.resolve_name_to_type(name, type_param_map, &mut visiting)
            }
            TypeNode::SelfType => match self.current_self_type() {
                Some(ty) => ty,
                None => {
                    let span = ast.ty(type_ref).span;
                    self.add_error_at("Self type can only be used within type or trait methods", span.line, span.column);
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

                // 类型参数映射中的高阶类型（HKT）：F<T> 其中 F 是类型参数
                if let Some(&param_handle) = type_param_map.get(*name) {
                    // kind 检查：验证 F 的 kind 与参数数量和 kind 一致
                    let constructor_kind = self.arena.kind_of(param_handle);
                    // 如果 constructor_kind 不是 Star（即 F 是类型构造器），
                    // 或 args 非空（即 F<T> 应用），执行 kind 检查
                    if !matches!(constructor_kind, SemKind::Star) || !args_box.is_empty() {
                        let arg_kinds: Vec<SemKind> = args_box
                            .iter()
                            .map(|&a| self.arena.kind_of(a))
                            .collect();
                        if let Err(kind_err) = self.arena.check_kind_application(&constructor_kind, &arg_kinds) {
                            // 错误恢复：记录错误但继续构造类型
                            let span = ast.ty(type_ref).span;
                            self.add_error_at(&kind_err, span.line, span.column);
                        }
                    }
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
        let mut subst: FxHashMap<u32, TypeHandle> = FxHashMap::default();
        for idx in free_vars.iter() {
            let fresh = self.arena.fresh_type_var();
            subst.insert(*idx, fresh);
        }
        // 3. 应用替换
        self.apply_type_subst(ty, &subst)
    }

    /// 递归收集类型中的未绑定 TypeVar idx（去重）。
    ///
    /// 注意：Fn 类型不收集内部 TypeVar。函数类型是"类型方案"（type scheme），
    /// 其自由变量的实例化由调用点的 `instantiate_fn_type` 统一处理。
    /// 若 freshen_type 也实例化 Fn 内部变量，会与 instantiate_fn_type 产生重复实例化，
    /// 导致第一组 fresh 副本成为孤儿（未被任何 unify 引用），最终被报告为未解析 TypeVar。
    fn collect_free_vars(&self, ty: TypeHandle, free_vars: &mut Vec<u32>) {
        let resolved = self.arena.resolve(ty);
        match self.arena.get(resolved) {
            ConcreteType::TypeVar(idx) => {
                // rigid var 代表泛型参数声明（如 type ArrayIter<T> 中的 T），
                // 在当前作用域是固定的，不应被 freshen 实例化。
                // 仅收集非 rigid 的未绑定 TypeVar（局部推断变量）。
                if !self.arena.type_var(*idx).is_rigid && !free_vars.contains(idx) {
                    free_vars.push(*idx);
                }
            }
            // Fn 类型跳过：实例化由 instantiate_fn_type 在调用点处理
            ConcreteType::Fn { .. } => {}
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
            ConcreteType::TraitObject { .. } => {}
            _ => {}
        }
    }

    /// 用替换表替换类型中的 TypeVar（按 idx）。无副作用，返回新类型。
    /// 委托给已有的 `substitute_type` 实现。
    pub fn apply_type_subst(
        &mut self,
        ty: TypeHandle,
        subst: &FxHashMap<u32, TypeHandle>,
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
        // async 函数 body 直接返回内层值（非 Async 包装）：
        // 声明 Async<X>，body 推断为 Y → 递归统一 X 与 Y
        if let ConcreteType::Generic { name: dn, args: da } = &declared_ct {
            if dn.as_ref() == "Async" && da.len() == 1 {
                return self.unify_return_type(da[0], r_inferred);
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

    /// 立即 unify 两个类型，失败时注册为 Equality 约束供不动点迭代重试。
    ///
    /// 替代 `let _ = self.arena.unify(t1, t2)` 模式：
    /// - unify 成功 → 立即绑定（保持推断时序优势）
    /// - unify 失败 → 注册 Equality 约束到 solver，由不动点迭代重试
    ///   （其他约束可能先绑定相关 TypeVar，使后续 unify 成功）
    #[inline]
    pub fn unify_or_constrain(&mut self, t1: TypeHandle, t2: TypeHandle) {
        if self.arena.unify(t1, t2).is_err() {
            self.solver.add_equality(t1, t2);
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
        if self.arena.unify(r1, r2).is_ok() { return Ok(r1) }

        let c1 = self.arena.get(r1).clone();
        let c2 = self.arena.get(r2).clone();

        // async 穿透：Async<X> 与 Y（非 Async）→ 递归统一 X 与 Y
        // 场景：async 函数体中 Ok(void) 返回 Throw<void, '_E>，
        // expected 为 Async<Throw<void, IOError>>，需穿透 Async 层求解 '_E
        if let ConcreteType::Generic { name, args } = &c1 {
            if name.as_ref() == "Async" && args.len() == 1 {
                return self.try_widen_unify(args[0], r2);
            }
        }
        if let ConcreteType::Generic { name, args } = &c2 {
            if name.as_ref() == "Async" && args.len() == 1 {
                return self.try_widen_unify(r1, args[0]);
            }
        }

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
    ///
    /// `expected_return` 为外层函数的返回类型（可能是 `Async<Throw<V, E>>` 或 `Throw<V, E>`），
    /// 用于统一 error_type，使 throw 传播类型正确。
    ///
    /// - nullable：展开为内层类型
    /// - throw：展开为值类型，并将 error_type 与外层函数的 error_type 统一
    /// - TypeVar：延迟到 solver 求解，返回 fresh_type_var 避免级联误报
    /// - 其它类型：报错并返回原类型
    pub fn check_propagate(
        &mut self,
        resolved_inner: TypeHandle,
        inner_ty: TypeHandle,
        expected_return: Option<TypeHandle>,
        line: u32,
        column: u32,
    ) -> TypeHandle {
        let ct = self.arena.get(resolved_inner).clone();
        match ct {
            ConcreteType::Nullable(inner) => inner,
            ConcreteType::Throw { value_type, error_type } => {
                // 将 error_type 与外层函数的 error_type 统一（当外层是 throwing 函数时）
                // Glue 允许在非 throwing 函数中使用 `?`（失败时 panic/退出），此时不传播 error_type
                if let Some(er) = expected_return {
                    let er_resolved = self.arena.resolve(er);
                    let er_ct = self.arena.get(er_resolved).clone();
                    // async 函数：expected_return 可能是 Async<Throw<V', E'>>
                    let outer_throw = match er_ct {
                        ConcreteType::Generic { name, args }
                            if name.as_ref() == "Async" && args.len() == 1 =>
                        {
                            self.arena.get(self.arena.resolve(args[0])).clone()
                        }
                        other => other,
                    };
                    if let ConcreteType::Throw { error_type: outer_err, .. } = outer_throw {
                        self.unify_or_constrain(error_type, outer_err);
                    }
                    // 非 Throw 外层（如 void）或 TypeVar：静默跳过，不报错
                }
                value_type
            }
            ConcreteType::TypeVar(_) => {
                // operand 类型尚未确定，延迟到 solver 求解后再判定
                // 返回 fresh_type_var 避免下游方法查找级联误报
                self.arena.fresh_type_var()
            }
            _ => {
                self.add_error_at(
                    "propagation operator '?' cannot be used on a non-nullable, non-throw expression",
                    line,
                    column,
                );
                inner_ty
            }
        }
    }

    /// 检查 throw 语句的表达式类型。
    /// Glue 无 try-catch，throw 是通用抛出机制，接受任意 ADT/Record/Throw/TypeVar。
    pub fn check_throw_stmt(&mut self, thrown_ty: TypeHandle, _line: u32, _column: u32) {
        let resolved = self.arena.resolve(thrown_ty);
        let ct = self.arena.get(resolved).clone();
        match &ct {
            ConcreteType::TypeVar(_) => return,   // 延迟到统一阶段
            ConcreteType::Throw { .. } => return, // throw Error("...") 返回 Throw，合法
            ConcreteType::Adt { .. } | ConcreteType::Generic { .. } => return, // 错误类型（普通 ADT）
            _ => return, // 保守放行，throw 是通用机制
        }
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
            ConcreteType::TraitObject { trait_name, .. } => {
                self.sema_result.get_or_create_ref_desc(trait_name)
            }
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
        let is_trait_object = matches!(ct, ConcreteType::TraitObject { .. });
        let info = ExprInfo {
            type_desc,
            inner_type_desc,
            const_val: None,
            expr_id: expr.0 as u64,
            type_name: type_name.map(|s| s.into_boxed_str()),
            is_trait_object,
            is_ref_type: is_ref,
            is_raw_ref,
            type_args: None,
            fn_sig: None,
        };
        let key = module_expr_key(&self.current_module_name, expr.0 as u64);
        self.sema_result.put_expr(key, info);
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
        // 诊断追踪：仅在 GLUE_SEMA_TRACE 启用时记录 (TypeHandle, Span)
        if std::env::var("GLUE_SEMA_TRACE").is_ok() {
            let span = ast.expr(expr).span;
            self.type_trace.push((ty, span));
        }
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
                // null 字面量类型为 Nullable<T>，T 通过 expected 约束求解。
                // try_widen_unify 处理所有 expected 类型（Nullable<T> 统一 inner，
                // 其他类型尝试 widen 或报错），无需对 expected 做类型特判。
                let tv = self.arena.fresh_type_var();
                let ty = self.arena.make(ConcreteType::Nullable(tv));
                if let Some(exp) = expected {
                    let _ = self.try_widen_unify(exp, ty);
                }
                ty
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
                let span = ast.expr(expr).span;
                self.add_error_at(&format!("undefined variable '{}'", name), span.line, span.column);
                self.arena.fresh_type_var()
            }

            // ── 赋值 ──
            Expr::Assign { target, value } => {
                let val_ty = self.infer_expr(*value, ast, env, None);
                let target_ty = self.infer_expr(*target, ast, env, None);
                self.unify_or_constrain(target_ty, val_ty);
                self.make_builtin(ConcreteType::Void)
            }
            Expr::CompoundAssign { target, value, .. } => {
                let val_ty = self.infer_expr(*value, ast, env, None);
                let target_ty = self.infer_expr(*target, ast, env, None);
                self.unify_or_constrain(target_ty, val_ty);
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
                        self.unify_or_constrain(left_ty, right_ty);
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
                            self.unify_or_constrain(left_ty, right_ty);
                        }
                        self.make_builtin(ConcreteType::Bool)
                    }
                    BinaryOp::And | BinaryOp::Or => {
                        let bool_ty = self.make_builtin(ConcreteType::Bool);
                        self.unify_or_constrain(left_ty, bool_ty);
                        self.unify_or_constrain(right_ty, bool_ty);
                        bool_ty
                    }
                    BinaryOp::BitAnd | BinaryOp::BitOr | BinaryOp::BitXor
                    | BinaryOp::Shl | BinaryOp::Shr => {
                        self.unify_or_constrain(left_ty, right_ty);
                        left_ty
                    }
                    BinaryOp::ConcatList => {
                        let elem_ty = self.arena.fresh_type_var();
                        let arr_ty = self.arena.make(ConcreteType::Array {
                            element_type: elem_ty,
                            size: None,
                        });
                        self.unify_or_constrain(left_ty, arr_ty);
                        let right_elem = self.arena.fresh_type_var();
                        let arr_ty = self.arena.make(ConcreteType::Array {
                            element_type: right_elem,
                            size: None,
                        });
                        self.unify_or_constrain(right_ty, arr_ty);
                        let res_elem = self.arena.fresh_type_var();
                        self.arena.make(ConcreteType::Array {
                            element_type: res_elem,
                            size: None,
                        })
                    }
                    BinaryOp::Range | BinaryOp::RangeInclusive => {
                        // Range 表达式 a..b / a..=b 返回 RangeIterator 类型
                        // （Range 本身是迭代器，For 循环通过 RangeIterator.next 静态分派）
                        let i64_ty = self.make_builtin(ConcreteType::I64);
                        let _ = self.try_widen_unify(i64_ty, left_ty);
                        let i64_ty = self.make_builtin(ConcreteType::I64);
                        let _ = self.try_widen_unify(i64_ty, right_ty);
                        self.arena.make(ConcreteType::Generic {
                            name: "RangeIterator".into(),
                            args: Box::new([]),
                        })
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
            Expr::Call { callee, args, type_args } => {
                // cast 调用解析：__cast_to<T>(x) / __cast_try_to<T>(x)
                // parser 将 cast(x).to(T) 降级为 __cast_to<T>(x) 普通 Call，
                // sema 推断源类型 S，返回 T（或 Throw<T, CastError> for try_to）
                // 通过 CAST_BUILTINS 注册表查表，避免函数名特判分支
                if let Expr::Ident(name) = &ast.expr(*callee).node {
                    if let Some(is_try) = CAST_BUILTINS
                        .iter()
                        .find_map(|(n, t)| (*n == *name).then_some(*t))
                    {
                        // 推断源表达式类型
                        let _ = self.infer_expr(args[0], ast, env, None);
                        // 从 type_args 取目标类型 T
                        let target_ty = match type_args {
                            Some(ta) if !ta.is_empty() => self.type_from_ast(ta[0], ast),
                            _ => self.arena.fresh_type_var(),
                        };
                        if is_try {
                            let err_ty = self.arena.make(ConcreteType::Adt {
                                name: "CastError".into(),
                                type_args: Box::new([]),
                            });
                            return self.arena.make(ConcreteType::Throw {
                                value_type: target_ty,
                                error_type: err_ty,
                            });
                        }
                        return target_ty;
                    }
                }

                let callee_ty = self.infer_expr(*callee, ast, env, None);
                let resolved_callee = self.arena.resolve(callee_ty);

                // ModuleRef 调用：callee 是模块路径引用（如 "std.reflect.Reflect.format"），
                // 直接在 ModuleRef 携带的模块 env 中按末段裸名查找函数签名（不穿透父 env）
                if let ConcreteType::ModuleRef { path, env: module_env } =
                    self.arena.get(resolved_callee).clone()
                {
                    // 末段即函数名（如 "std.reflect.Reflect.format" → "format"）
                    if let Some(func_name) = path.rsplit('.').next() {
                        if let Some(fn_ty) = self.env.lookup_local(module_env, func_name) {
                            // 实例化多态函数类型，避免不同调用的类型约束冲突
                            let inst_fn = self.instantiate_fn_type(fn_ty);
                            if let ConcreteType::Fn { params, return_type } =
                                self.arena.get(inst_fn).clone()
                            {
                                if params.len() == args.len() {
                                    for (&param_ty, &arg) in params.iter().zip(args.iter()) {
                                        let arg_ty = self.infer_expr(arg, ast, env, Some(param_ty));
                                        let _ = self.try_widen_unify(param_ty, arg_ty);
                                    }
                                    return return_type;
                                }
                            }
                        }
                    }
                }

                // 实例化多态函数类型（将 rigid var / 未绑定 TypeVar 替换为 fresh non-rigid var），
                // 使每次调用拥有独立的类型变量，避免不同调用的类型约束相互冲突
                let inst_callee = self.instantiate_fn_type(resolved_callee);
                let callee_ct = self.arena.get(inst_callee).clone();
                if let ConcreteType::Fn { params, return_type } = &callee_ct {
                    if params.len() == args.len() {
                        for (&param_ty, &arg) in params.iter().zip(args.iter()) {
                            let arg_ty = self.infer_expr(arg, ast, env, Some(param_ty));
                            let _ = self.try_widen_unify(param_ty, arg_ty);
                        }
                    }
                    // 始终返回声明的返回类型，避免参数不匹配导致级联类型丢失
                    // 若有 expected 类型，unify 返回类型与 expected，求解返回类型中的未决 TypeVar
                    // （如 Ok(void) 返回 Throw<void, '_E>，expected=Throw<void, IOError> 可求解 E=IOError）
                    if let Some(exp) = expected {
                        let _ = self.try_widen_unify(*return_type, exp);
                    }
                    return *return_type;
                }
                // 兜底：推断所有参数，unify callee 与 (args -> ret)
                let ret_ty = self.arena.fresh_type_var();
                let arg_types: Vec<TypeHandle> = args
                    .iter()
                    .map(|&a| self.infer_expr(a, ast, env, None))
                    .collect();
                let expected_fn = self.arena.make(ConcreteType::Fn {
                    params: arg_types.into_boxed_slice(),
                    return_type: ret_ty,
                });
                self.unify_or_constrain(callee_ty, expected_fn);
                ret_ty
            }

            // ── 方法调用 ──
            Expr::MethodCall { recv, method, args, .. }
            | Expr::SafeMethodCall { recv, method, args, .. } => {
                let recv_ty = self.infer_expr(*recv, ast, env, None);

                // 路径 0a：ModuleRef recv → 模块路径函数调用
                // 当 recv 是 ModuleRef（如 std.net.UdpSocket）时，method 是模块中的顶层函数，
                // 直接在 ModuleRef 携带的模块 env 中按 method 裸名查找（不穿透父 env）。
                let recv_resolved_0a = self.arena.resolve(recv_ty);
                if let ConcreteType::ModuleRef { env: module_env, .. } =
                    self.arena.get(recv_resolved_0a).clone()
                {
                    if let Some(fn_ty) = self.env.lookup_local(module_env, method) {
                        let inst_fn = self.instantiate_fn_type(fn_ty);
                        if let ConcreteType::Fn { params, return_type } =
                            self.arena.get(inst_fn).clone()
                        {
                            let n = params.len().min(args.len());
                            for i in 0..n {
                                let arg_ty = self.infer_expr(args[i], ast, env, Some(params[i]));
                                let _ = self.try_widen_unify(params[i], arg_ty);
                            }
                            return return_type;
                        }
                    }
                }

                // 路径 1（优先）：类型感知的方法查找
                // 通过 lookup_method_type 按接收者类型查 witness_table / func_sigs / 内置方法，
                // 确保同名方法（如 Instant.add_duration 与 DateTime.add_duration）分派到正确签名。
                let method_fn_ty = self.lookup_method_type(recv_ty, method);
                if let Some(fn_ty) = method_fn_ty {
                    let inst_fn = self.instantiate_fn_type(fn_ty);
                    if let ConcreteType::Fn { params, return_type } =
                        self.arena.get(inst_fn).clone()
                    {
                        // 第一个参数是 self，跳过
                        let n = params.len().min(args.len() + 1);
                        for i in 1..n {
                            let arg_ty = self.infer_expr(args[i - 1], ast, env, Some(params[i]));
                            let _ = self.try_widen_unify(params[i], arg_ty);
                        }
                        return return_type;
                    }
                }

                // 路径 0（回退）：env 中查找方法名为 Fn 类型的绑定（free function with self 参数）
                // 使用 lookup_with_pred 跳过同名的非函数绑定（如局部变量遮蔽自由函数）。
                // Glue 中 `recv.method(args)` 是 `method(recv, args)` 的语法糖
                if let Some(fn_ty) = self.env.lookup_with_pred(env, method, |ty| {
                    let r = self.arena.resolve(ty);
                    matches!(self.arena.get(r), ConcreteType::Fn { .. })
                }) {
                    let inst_fn = self.instantiate_fn_type(fn_ty);
                    if let ConcreteType::Fn { params, return_type } =
                        self.arena.get(inst_fn).clone()
                    {
                        // 第一个参数是 self，跳过
                        let n = params.len().min(args.len() + 1);
                        for i in 1..n {
                            let arg_ty = self.infer_expr(args[i - 1], ast, env, Some(params[i]));
                            let _ = self.try_widen_unify(params[i], arg_ty);
                        }
                        return return_type;
                    }
                }

                // 兜底：推断参数，返回 fresh var
                // 对已确定类型的接收者（非 TypeVar/Unknown/Never）报"方法不存在"，
                // 帮助用户定位问题；对 TypeVar 接收者静默返回 fresh var（推断未决，延迟到 solver）
                let span = ast.expr(expr).span;
                let recv_resolved = self.arena.resolve(recv_ty);
                match self.arena.get(recv_resolved) {
                    ConcreteType::TypeVar(_) | ConcreteType::Unknown | ConcreteType::Never => {
                        // 接收者类型未决，静默返回 fresh var
                    }
                    ConcreteType::Void => {
                        // void 接收者：IR 层处理（void 方法调用）
                    }
                    ct => {
                        // 接收者类型已确定但方法查找失败：报错
                        let recv_name = self.arena.type_name(recv_resolved)
                            .map(|s| s.to_string())
                            .unwrap_or_else(|| format!("{:?}", ct));
                        self.add_error_at(
                            &format!("no method '{}' on type '{}'", method, recv_name),
                            span.line,
                            span.column,
                        );
                    }
                }
                for &a in args.iter() {
                    let _ = self.infer_expr(a, ast, env, None);
                }
                self.arena.fresh_type_var()
            }

            // ── 字段访问 ──
            Expr::FieldAccess { recv, field } => {
                let recv_ty = self.infer_expr(*recv, ast, env, None);
                let span = ast.expr(expr).span;
                self.lookup_field_type(recv_ty, field, span.line, span.column)
            }
            Expr::SafeAccess { recv, field } => {
                let recv_ty = self.infer_expr(*recv, ast, env, None);
                let inner = self.unwrap_ref(recv_ty);
                let span = ast.expr(expr).span;
                self.lookup_field_type(inner, field, span.line, span.column)
            }

            // ── 索引/切片 ──
            Expr::Index { recv, index } => {
                let recv_ty = self.infer_expr(*recv, ast, env, None);
                let _ = self.infer_expr(*index, ast, env, None);
                let resolved = self.arena.resolve(recv_ty);
                match self.arena.get(resolved).clone() {
                    ConcreteType::Array { element_type, .. } => element_type,
                    // Str 索引返回 Char（stdlib 中 normalized[0] == '/' 等用法）
                    ConcreteType::Str => self.arena.make(ConcreteType::Char),
                    // Unknown/TypeVar/Generic/Adt 等不报错：
                    // sema v2 对部分变量类型推断不精确（如 u8[] 可能被 unify 为 Unknown），
                    // 在 sema 类型推断完善前保守放行避免级联误报
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
                let span = ast.expr(expr).span;
                self.check_propagate(resolved, inner_ty, self.expected_return, span.line, span.column)
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
                // 从 expected 提取元素类型，使字面量元素能按注解提升
                // （例如 `val data: u8[] = [72, 101]` 中 72 应提升为 u8 而非默认 i32）
                let expected_elem = expected.and_then(|exp| {
                    let r = self.arena.resolve(exp);
                    match self.arena.get(r).clone() {
                        ConcreteType::Array { element_type, .. } => Some(element_type),
                        _ => None,
                    }
                });
                if elements.is_empty() {
                    let elem_ty = expected_elem.unwrap_or_else(|| self.arena.fresh_type_var());
                    return self.arena.make(ConcreteType::Array {
                        element_type: elem_ty,
                        size: None,
                    });
                }
                let first_ty = self.infer_expr(elements[0], ast, env, expected_elem);
                for &e in elements.iter().skip(1) {
                    let elem_ty = self.infer_expr(e, ast, env, expected_elem);
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
                        let mut all_fields: Vec<FieldType> = base_fields.to_vec();
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
                        let span = ast.expr(expr).span;
                        self.add_error_at("record extend requires record type", span.line, span.column);
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
                self.unify_or_constrain(cond_ty, bool_ty);

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
                    self.infer_expr(*te, ast, child_env, expected)
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
                    // 将 match 的 expected 类型传播给 arm body，
                    // 使 NullLit 等依赖 expected 约束的表达式能正确推导
                    let body_ty = self.infer_expr(arm.body, ast, child_env, expected);
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

            // ── select 表达式：Go 风格 channel 多路复用 ──
            //
            // 遍历所有 arms：
            //   receive 分支：创建子 env，从 channel_expr 推断 Channel<T>，
            //                 提取元素类型 T 给 binding（若有），推断 body 类型
            //   timeout 分支：直接推断 body 类型
            // 用 peer_type join 所有 body 类型（与 Match 一致，比 Zig 侧只取首个更健壮）
            Expr::Select(arms) => {
                let mut arm_tys: Vec<TypeHandle> = Vec::new();
                for arm in arms.iter() {
                    let child_env = self.env.child(env);
                    self.flow_ctx.push_scope();
                    match arm {
                        crate::Ast::SelectArm::Receive { channel_expr, binding, body } => {
                            // 推断 channel 表达式类型，提取元素类型给 binding
                            let chan_ty = self.infer_expr(*channel_expr, ast, child_env, None);
                            let resolved = self.arena.resolve(chan_ty);
                            let elem_ty = match &self.arena.types[resolved.0 as usize] {
                                // Nullable(Channel<T>) → 取 Channel 的 T
                                ConcreteType::Nullable(inner) => {
                                    let inner_resolved = self.arena.resolve(*inner);
                                    match &self.arena.types[inner_resolved.0 as usize] {
                                        ConcreteType::Generic { name, args } if name.as_ref() == "Channel" && args.len() == 1 => args[0],
                                        _ => chan_ty,
                                    }
                                }
                                // Channel<T> → 取 T
                                ConcreteType::Generic { name, args } if name.as_ref() == "Channel" && args.len() == 1 => args[0],
                                _ => chan_ty,
                            };
                            if let Some(name) = binding {
                                let _ = self.env.define(child_env, name, elem_ty);
                            }
                            let body_ty = self.infer_expr(*body, ast, child_env, None);
                            arm_tys.push(body_ty);
                        }
                        crate::Ast::SelectArm::Timeout { body, .. } => {
                            let body_ty = self.infer_expr(*body, ast, child_env, None);
                            arm_tys.push(body_ty);
                        }
                    }
                    self.flow_ctx.pop_scope();
                }
                if arm_tys.is_empty() {
                    self.make_builtin(ConcreteType::Void)
                } else {
                    peer_type(self.arena, &arm_tys)
                }
            }

            // ── inline_trait 值：构造 TraitObject 类型 ──
            //
            // 从 expected type（val_decl 的类型注解）获取 trait 名，
            // 验证方法完备性，产出 TraitObject { trait_name, method_sigs }。
            // 若无 expected type，报错并返回 fresh_type_var（不允许无注解的 inline_trait）。
            Expr::InlineTrait(methods) => {
                // 从 expected type 获取 trait 名
                let trait_name: Option<Box<str>> = if let Some(exp) = expected {
                    let resolved = self.arena.resolve(exp);
                    match &self.arena.types[resolved.0 as usize] {
                        ConcreteType::Trait { name, .. } => Some(name.clone()),
                        ConcreteType::TraitObject { trait_name, .. } => Some(trait_name.clone()),
                        _ => None,
                    }
                } else {
                    None
                };

                // 收集 inline_trait 的方法签名
                let method_sigs: Vec<TraitMethodSig> = methods
                    .iter()
                    .map(|m| {
                        let return_type_desc = match m.return_type {
                            Some(rt) => resolve_type_node_to_desc(rt, ast, self.sema_result),
                            None => self.sema_result.get_or_create_ref_desc("void"),
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

                if let Some(tname) = trait_name {
                    // 验证方法完备性：trait_def 的 required methods（无 body）必须全部出现在 inline_trait 中
                    let missing: Vec<String> = if let Some(trait_def) = self.sema_result.get_trait_def(&tname) {
                        trait_def
                            .methods
                            .iter()
                            .filter(|req| !req.has_body)
                            .filter(|req| {
                                !method_sigs
                                    .iter()
                                    .any(|m| m.name == req.name && m.param_count == req.param_count)
                            })
                            .map(|req| {
                                format!(
                                    "inline_trait 缺少 trait {} 的必需方法 {} (参数个数 {})",
                                    tname, req.name, req.param_count
                                )
                            })
                            .collect()
                    } else {
                        Vec::new()
                    };
                    let span = ast.expr(expr).span;
                    for msg in missing {
                        self.sema_result.errors.push(SemaError::new(&msg, span.line, span.column));
                    }

                    // 类型检查各方法体：为参数绑定类型（有注解则用注解，无注解则 fresh_type_var），
                    // 设置 expected_return，调用 infer_expr 填充 body 内各子表达式的 expr_types。
                    // 这是 IR 编译期类型查询（如 str + str → concat）的数据来源。
                    for m in methods.iter() {
                        if let Some(body) = m.body {
                            let method_env = self.env.child(env);
                            for param in m.params.iter() {
                                let param_ty = match param.type_annotation {
                                    Some(ta) => self.type_from_ast(ta, ast),
                                    None => self.arena.fresh_type_var(),
                                };
                                self.env.define(method_env, param.name, param_ty);
                            }
                            let prev_return = self.expected_return;
                            self.expected_return =
                                m.return_type.map(|rt| self.type_from_ast(rt, ast));
                            let _ = self.infer_expr(body, ast, method_env, self.expected_return);
                            self.expected_return = prev_return;
                        }
                    }

                    self.arena.make(ConcreteType::TraitObject {
                        trait_name: tname,
                        method_sigs: method_sigs.into_boxed_slice(),
                    })
                } else {
                    let span = ast.expr(expr).span;
                    self.sema_result.errors.push(SemaError::new(
                        "inline_trait 无法推断 trait 名：需要显式类型注解",
                        span.line,
                        span.column,
                    ));
                    self.arena.fresh_type_var()
                }
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

    /// 从类型名字字符串构造 TypeHandle（用于从 FuncSigInfo/TraitMethodSig 还原函数签名）。
    /// 标量名走 from_scalar_name；"str" 特殊处理；内置泛型构造为 Generic（类型参数用 fresh 填充）；
    /// 用户类型名构造 Adt；None 返回 fresh_type_var（无注解参数）。
    fn type_handle_from_name(&mut self, name: Option<&str>) -> TypeHandle {
        match name {
            None => self.arena.fresh_type_var(),
            Some(n) => match n {
                "i8" | "i16" | "i32" | "i64" | "i128" | "u8" | "u16" | "u32" | "u64" | "u128"
                | "isize" | "usize" | "f16" | "f32" | "f64" | "f128" | "bool" | "char"
                | "Null" | "void" => self.arena.from_scalar_name(n),
                "str" => self.arena.make(ConcreteType::Str),
                // Throw 有专用 ConcreteType 变体，不能走 Generic 路径
                // （check_propagate 等类型检查依赖 ConcreteType::Throw 模式匹配）
                "Throw" => {
                    let value_type = self.arena.fresh_type_var();
                    let error_type = self.arena.fresh_type_var();
                    self.arena
                        .make(ConcreteType::Throw { value_type, error_type })
                }
                _ => {
                    if let Some(arity) = generic_type_arity(n) {
                        let args: Vec<TypeHandle> =
                            (0..arity).map(|_| self.arena.fresh_type_var()).collect();
                        self.arena.make(ConcreteType::Generic {
                            name: n.into(),
                            args: args.into_boxed_slice(),
                        })
                    } else {
                        self.arena.make(ConcreteType::Adt {
                            name: n.into(),
                            type_args: Box::new([]),
                        })
                    }
                }
            },
        }
    }

    /// 从 MethodSigInfo 的 owned 数据构造 ConcreteType::Fn 类型。
    /// 参数和返回类型均通过 type_repr_to_handle 从 TypeRepr 完整解析，
    /// 正确处理嵌套泛型（如 Async<Throw<T, E>>）、数组、Nullable 等复合类型，
    /// 克服 type_name 仅存顶层名的限制。
    fn build_fn_type_from_sig(
        &mut self,
        param_type_reprs: Vec<TypeRepr>,
        return_type_repr: Option<TypeRepr>,
        _recv_ty: TypeHandle,
    ) -> TypeHandle {
        // SelfType 由 type_repr_to_handle 通过 current_self_type() 解析，
        // 调用方（lookup_method_type）已 push recv_ty 作为 self_type。
        let params: Vec<TypeHandle> = param_type_reprs
            .iter()
            .map(|repr| self.type_repr_to_handle(repr))
            .collect();
        let return_type = match return_type_repr {
            Some(repr) => self.type_repr_to_handle(&repr),
            None => self.arena.fresh_type_var(),
        };
        self.arena.make(ConcreteType::Fn {
            params: params.into_boxed_slice(),
            return_type,
        })
    }

    /// 从自包含的 TypeRepr 构造 TypeHandle（不依赖 AstArena 引用）。
    /// 与 type_from_ast_with_params 逻辑镜像，但读取 TypeRepr 而非 AST TypeNode。
    /// 用于跨模块方法返回类型还原（MethodSigInfo.return_type_repr）。
    fn type_repr_to_handle(&mut self, repr: &TypeRepr) -> TypeHandle {
        match repr {
            TypeRepr::Named(name) => {
                let empty_map: FxHashMap<String, TypeHandle> = FxHashMap::default();
                let mut visiting = FxHashSet::default();
                self.resolve_name_to_type(name.as_ref(), &empty_map, &mut visiting)
            }
            TypeRepr::SelfType => match self.current_self_type() {
                Some(ty) => ty,
                None => self.arena.fresh_type_var(),
            },
            TypeRepr::Generic(name, args) => {
                let new_args: Vec<TypeHandle> =
                    args.iter().map(|a| self.type_repr_to_handle(a)).collect();
                let args_box: Box<[TypeHandle]> = new_args.into_boxed_slice();

                // Throw 特殊处理
                if name.as_ref() == "Throw" && args_box.len() == 2 {
                    return self.arena.make(ConcreteType::Throw {
                        value_type: args_box[0],
                        error_type: args_box[1],
                    });
                }
                // 内置泛型类型（Atomic/Async/Channel 等）
                if is_builtin_generic_type(name) {
                    return self.arena.make(ConcreteType::Generic {
                        name: name.clone(),
                        args: args_box,
                    });
                }
                // trait 定义 → Trait 类型
                if self.sema_result.get_trait_def(name).is_some() {
                    return self.arena.make(ConcreteType::Trait {
                        name: name.clone(),
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
                        name: name.clone(),
                        type_args: args_box,
                    });
                }
                // 兜底：构造 Generic
                self.arena.make(ConcreteType::Generic {
                    name: name.clone(),
                    args: args_box,
                })
            }
            TypeRepr::Nullable(inner) => {
                let inner_ty = self.type_repr_to_handle(inner);
                self.arena.make(ConcreteType::Nullable(inner_ty))
            }
            TypeRepr::Ref(inner) => {
                let inner_ty = self.type_repr_to_handle(inner);
                self.arena.make(ConcreteType::Ref {
                    inner: inner_ty,
                    is_raw: false,
                })
            }
            TypeRepr::RawPtr(inner) => {
                let inner_ty = self.type_repr_to_handle(inner);
                self.arena.make(ConcreteType::Ref {
                    inner: inner_ty,
                    is_raw: true,
                })
            }
            TypeRepr::Function(params, return_type) => {
                let p: Vec<TypeHandle> =
                    params.iter().map(|a| self.type_repr_to_handle(a)).collect();
                let r = self.type_repr_to_handle(return_type);
                self.arena.make(ConcreteType::Fn {
                    params: p.into_boxed_slice(),
                    return_type: r,
                })
            }
            TypeRepr::Array(elem, _) => {
                let elem_ty = self.type_repr_to_handle(elem);
                self.arena.make(ConcreteType::Array {
                    element_type: elem_ty,
                    size: None,
                })
            }
        }
    }

    /// 查找内置类型的内置方法（Array/Str/Channel/Map/Nullable/Throw）。
    /// 返回方法的 Fn 类型（不含 self 参数，self 已由接收者确定）。
    /// 仅对内置类型生效；用户自定义类型走 witness_table/func_sigs 路径。
    fn lookup_builtin_method(
        &mut self,
        resolved: TypeHandle,
        method: &str,
    ) -> Option<TypeHandle> {
        let ct = self.arena.get(resolved).clone();
        let usize_ty = self.arena.make(ConcreteType::Usize);
        let bool_ty = self.arena.make(ConcreteType::Bool);
        let void_ty = self.arena.make(ConcreteType::Void);
        match &ct {
            ConcreteType::Array { element_type, .. } => {
                let elem = *element_type;
                match method {
                    "len" | "is_empty" => Some(self.arena.make(ConcreteType::Fn {
                        params: Box::new([]),
                        return_type: usize_ty,
                    })),
                    "push" => Some(self.arena.make(ConcreteType::Fn {
                        params: Box::new([elem]),
                        return_type: void_ty,
                    })),
                    "pop" => Some(self.arena.make(ConcreteType::Fn {
                        params: Box::new([]),
                        return_type: elem,
                    })),
                    _ => None,
                }
            }
            ConcreteType::Str => match method {
                "len" | "is_empty" => Some(self.arena.make(ConcreteType::Fn {
                    params: Box::new([]),
                    return_type: usize_ty,
                })),
                _ => None,
            },
            ConcreteType::Nullable(inner) => {
                let inner_ty = *inner;
                match method {
                    "is_null" => Some(self.arena.make(ConcreteType::Fn {
                        params: Box::new([]),
                        return_type: bool_ty,
                    })),
                    "unwrap" => Some(self.arena.make(ConcreteType::Fn {
                        params: Box::new([]),
                        return_type: inner_ty,
                    })),
                    _ => None,
                }
            }
            ConcreteType::Throw { value_type, .. } => {
                let val = *value_type;
                match method {
                    "is_ok" => Some(self.arena.make(ConcreteType::Fn {
                        params: Box::new([]),
                        return_type: bool_ty,
                    })),
                    "unwrap" => Some(self.arena.make(ConcreteType::Fn {
                        params: Box::new([]),
                        return_type: val,
                    })),
                    "unwrap_or" => Some(self.arena.make(ConcreteType::Fn {
                        params: Box::new([val]),
                        return_type: val,
                    })),
                    _ => None,
                }
            }
            ConcreteType::Generic { name, args } => match name.as_ref() {
                "Channel" if args.len() == 1 => {
                    let elem = args[0];
                    match method {
                        "send" => Some(self.arena.make(ConcreteType::Fn {
                            params: Box::new([elem]),
                            return_type: void_ty,
                        })),
                        "recv" => Some(self.arena.make(ConcreteType::Fn {
                            params: Box::new([]),
                            return_type: elem,
                        })),
                        "close" => Some(self.arena.make(ConcreteType::Fn {
                            params: Box::new([]),
                            return_type: void_ty,
                        })),
                        _ => None,
                    }
                }
                "Map" if args.len() == 2 => {
                    let k = args[0];
                    let v = args[1];
                    match method {
                        "len" | "is_empty" => Some(self.arena.make(ConcreteType::Fn {
                            params: Box::new([]),
                            return_type: usize_ty,
                        })),
                        "get" => Some(self.arena.make(ConcreteType::Fn {
                            params: Box::new([k]),
                            return_type: v,
                        })),
                        "set" => Some(self.arena.make(ConcreteType::Fn {
                            params: Box::new([k, v]),
                            return_type: void_ty,
                        })),
                        _ => None,
                    }
                }
                _ => None,
            },
            _ => None,
        }
    }

    /// 查找对象类型的方法签名（返回函数类型，第一个参数为 self）。
    fn lookup_method_type(
        &mut self,
        recv_ty: TypeHandle,
        method: &str,
    ) -> Option<TypeHandle> {
        let resolved = self.arena.resolve(recv_ty);

        // ── 接收者规范化 ──
        // 包装类型（Nullable/Ref）递归转发到 inner 类型的方法查找，
        // 使 s?.len() / (&arr).len() 等调用自动解包到正确的方法表。
        // Nullable 优先于 builtin（is_null/unwrap 是 Nullable 自有方法，不转发）。
        match self.arena.get(resolved).clone() {
            ConcreteType::Nullable(inner) => {
                // Nullable 自有方法（is_null/unwrap）由 lookup_builtin_method 处理，
                // 其他方法递归转发到 inner 类型。
                if method != "is_null" && method != "unwrap" && method != "unwrap_or" {
                    return self.lookup_method_type(inner, method);
                }
            }
            ConcreteType::Ref { inner, .. } => {
                // Ref 自动解引用：&T 的方法查找转发到 T
                return self.lookup_method_type(inner, method);
            }
            _ => {}
        }

        // 将 recv_ty 作为 Self 类型压栈，使 build_fn_type_from_sig 中
        // type_repr_to_handle(SelfType) 能正确解析为接收者类型，
        // 无需对第一个参数做位置特判。
        self.push_self_type(resolved);

        // 泛型类型参数绑定：将类型定义的类型参数名（如 "T"）绑定到接收者
        // 类型中的具体类型参数，使方法签名中的 T（如 `pub fun next(&self): T?`）
        // 能通过 type_binding_stack 解析为接收者中对应的类型参数，
        // 而非生成孤立的 fresh_type_var。
        //
        // 仅对 Adt（用户自定义泛型类型）处理：内置泛型（Generic）的方法
        // 由 lookup_builtin_method 处理，不走 witness_table 签名路径。
        let mut pushed_bindings = false;
        if let ConcreteType::Adt { name, type_args } = self.arena.get(resolved).clone() {
            if let Some(def) = self.sema_result.get_type_def(name.as_ref()) {
                if !def.type_params.is_empty() && type_args.len() == def.type_params.len() {
                    // push 绑定框架，逐个将类型参数名绑定到接收者对应位置的类型参数
                    self.type_binding_stack.push();
                    for (pname, &arg) in def.type_params.iter().zip(type_args.iter()) {
                        self.type_binding_stack.insert_top(pname.as_ref(), arg);
                    }
                    pushed_bindings = true;
                }
            }
        }

        let result = self.lookup_method_type_inner(resolved, method);
        if pushed_bindings {
            self.pop_type_bindings();
        }
        self.pop_self_type();
        result
    }

    fn lookup_method_type_inner(
        &mut self,
        resolved: TypeHandle,
        method: &str,
    ) -> Option<TypeHandle> {
        match self.arena.get(resolved).clone() {
            ConcreteType::Trait { name, .. } => {
                // trait 类型（如 l: Logger）直接查 trait_def.methods 还原方法签名，
                // 参数用 fresh_type_var（trait 方法的精确参数类型由实现类型决定）
                if let Some(td) = self.sema_result.get_trait_def(name.as_ref()) {
                    if let Some(sig) = td.methods.iter().find(|m| m.name.as_ref() == method) {
                        let params: Vec<TypeHandle> = (0..sig.param_count)
                            .map(|_| self.arena.fresh_type_var())
                            .collect();
                        let return_type =
                            self.type_handle_from_name(Some(sig.return_type_desc.type_name));
                        return Some(self.arena.make(ConcreteType::Fn {
                            params: params.into_boxed_slice(),
                            return_type,
                        }));
                    }
                }
            }
            _ => {}
        }

        // 内置方法：Async<T>.await() -> T
        if method == "await" {
            if let ConcreteType::Generic { name, args } = self.arena.get(resolved).clone() {
                if name.as_ref() == "Async" && args.len() == 1 {
                    let inner = args[0];
                    return Some(self.arena.make(ConcreteType::Fn {
                        params: Box::new([]),
                        return_type: inner,
                    }));
                }
            }
        }

        // 内置类型方法：Array/Str/Channel/Map/Nullable/Throw 的通用方法
        // 优先于 witness_table/func_sigs（内置类型无用户自定义方法）
        if let Some(fn_ty) = self.lookup_builtin_method(resolved, method) {
            return Some(fn_ty);
        }

        let type_name = self.arena.type_name(resolved).map(|s| s.to_string());

        // v2 收敛：路径 1 — 查 witness_table（trait 方法分派，type_id 索引）
        if let Some(ref name) = type_name {
            let type_id = self
                .sema_result
                .type_def_index
                .get(name.as_str())
                .map(|&idx| 22 + idx);
            if let Some(tid) = type_id {
                for entry in self.witness_table.entries().iter() {
                    if entry.type_id == tid && entry.method_slots.contains_key(method) {
                        // 从 TypeDefInfo.methods 获取签名（按 method_name 查找）
                        // 提取 owned 数据以释放 sema_result 借用
                        let sig_data: Option<(Vec<TypeRepr>, Option<TypeRepr>)> =
                            if let Some(&type_idx) = self.sema_result.type_def_index.get(name.as_str()) {
                                self.sema_result.type_defs[type_idx as usize]
                                    .methods
                                    .iter()
                                    .find(|m| m.name.as_ref() == method)
                                    .map(|sig| (sig.param_type_reprs.to_vec(), sig.return_type_repr.clone()))
                            } else {
                                None
                            };
                        if let Some((param_type_reprs, return_type_repr)) = sig_data {
                            return Some(self.build_fn_type_from_sig(param_type_reprs, return_type_repr, resolved));
                        }
                        // witness 命中但 TypeDefInfo.methods 未命中（trait 默认方法）
                        // 从 trait_def 获取方法签名
                        let trait_sig_data: Option<(u8, &'static str)> =
                            self.sema_result
                                .get_trait_def(entry.trait_name.as_ref())
                                .and_then(|td| {
                                    td.methods
                                        .iter()
                                        .find(|m| m.name.as_ref() == method)
                                        .map(|m| (m.param_count, m.return_type_desc.type_name))
                                });
                        if let Some((param_count, return_name)) = trait_sig_data {
                            let params: Vec<TypeHandle> = (0..param_count)
                                .map(|_| self.arena.fresh_type_var())
                                .collect();
                            let return_type = self.type_handle_from_name(Some(return_name));
                            return Some(self.arena.make(ConcreteType::Fn {
                                params: params.into_boxed_slice(),
                                return_type,
                            }));
                        }
                        return None;
                    }
                }
            }
        }

        // v2: 路径 1.5 — TraitObject 接收者，从 method_sigs 还原真实签名
        // 先提取 sig 数据（param_count + return_name）到 owned 变量，
        // 释放 arena.types 借用后再构造 Fn 类型
        let trait_sig_data: Option<(u8, &'static str)> =
            if let ConcreteType::TraitObject { method_sigs, .. } =
                &self.arena.types[resolved.0 as usize]
            {
                method_sigs
                    .iter()
                    .find(|m| m.name.as_ref() == method)
                    .map(|sig| (sig.param_count, sig.return_type_desc.type_name))
            } else {
                None
            };
        if let Some((param_count, return_name)) = trait_sig_data {
            let params: Vec<TypeHandle> = (0..param_count)
                .map(|_| self.arena.fresh_type_var())
                .collect();
            let return_type = self.type_handle_from_name(Some(return_name));
            return Some(self.arena.make(ConcreteType::Fn {
                params: params.into_boxed_slice(),
                return_type,
            }));
        }

        // v2 收敛：路径 2 — 查 TypeDefInfo.methods（类型自有方法，按 method_idx 索引）
        if let Some(ref name) = type_name {
            let sig_data: Option<(Vec<TypeRepr>, Option<TypeRepr>)> =
                if let Some(&type_idx) = self.sema_result.type_def_index.get(name.as_str()) {
                    self.sema_result.type_defs[type_idx as usize]
                        .methods
                        .iter()
                        .find(|m| m.name.as_ref() == method)
                        .map(|sig| (sig.param_type_reprs.to_vec(), sig.return_type_repr.clone()))
                } else {
                    None
                };
            if let Some((param_type_reprs, return_type_repr)) = sig_data {
                return Some(self.build_fn_type_from_sig(param_type_reprs, return_type_repr, resolved));
            }
        }

        None
    }

    /// 查找对象类型的字段类型。
    /// line/column 用于字段不存在时的错误定位（由调用方传入 AST span）。
    fn lookup_field_type(&mut self, recv_ty: TypeHandle, field: &str, line: u32, column: u32) -> TypeHandle {
        let resolved = self.arena.resolve(recv_ty);

        // Ref 自动解引用：&T 的字段访问转发到 T。
        // 对 &Record / &Adt 等引用类型，先剥除 Ref 再走正常的字段查找路径，
        // 避免 type_name 间接路径在 inner 为 TypeVar 时返回 None 而静默失败。
        if let ConcreteType::Ref { inner, .. } = self.arena.get(resolved).clone() {
            return self.lookup_field_type(inner, field, line, column);
        }

        // ModuleRef 字段访问：在 ModuleRef 携带的模块 env 中按裸名查找 field。
        //
        // 使用 lookup_local（不穿透父 env 链）统一处理：
        // - 子模块：ensure_module_env 创建层级 env 时已将子模块短名注册到父 env
        // - 模块内符号：predeclare_declarations 已将函数/构造器注册到 module_env
        // 查不到即报错，无需字符串拼接或前缀校验。
        if let ConcreteType::ModuleRef { path, env: module_env } = self.arena.get(resolved).clone()
        {
            if let Some(sym_ty) = self.env.lookup_local(module_env, field) {
                return sym_ty;
            }
            self.add_error_at(
                &format!("no module or symbol '{}.{}'", path, field),
                line,
                column,
            );
            return self.arena.make(ConcreteType::Unknown);
        }

        let type_name = self.arena.type_name(resolved).map(|s| s.to_string());
        if let Some(name) = type_name {
            if let Some(field_id) = self.sema_result.lookup_field_id(&name, field) {
                if let Some(ctor) = self.sema_result.get_ctor_def(&name) {
                    let idx = match self.sema_result.get_type_def(&name) {
                        Some(def) if def.kind == TypeDefKind::Record => field_id as usize,
                        _ => (field_id as usize).saturating_sub(1),
                    };
                    // 使用 field_type_reprs 通过 type_repr_to_handle 完整解析字段类型，
                    // 正确处理数组（T[]）、Nullable、Ref 等复合类型，
                    // 克服 field_type_names 仅存顶层名的限制。
                    // 先克隆 TypeRepr 以释放 sema_result 的不可变借用，再调用可变方法。
                    if let Some(repr) = ctor.field_type_reprs.get(idx).cloned() {
                        return self.type_repr_to_handle(&repr);
                    }
                    return self.arena.fresh_type_var();
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
        // 字段未找到：对已确定类型报"字段不存在"错误（与方法调用兜底一致）；
        // 未决类型（TypeVar/Unknown/Never/Void）静默返回 fresh var，延迟到 solver 全局诊断
        match &ct {
            ConcreteType::Record { .. } => {
                self.add_error_at(&format!("no such field '{}' on this type", field), line, column);
                self.arena.fresh_type_var()
            }
            ConcreteType::Adt { name, .. } => {
                // 对已注册的 Adt 类型报字段不存在错误；未注册的保守放行
                if self.sema_result.get_type_def(name).is_some() {
                    self.add_error_at(
                        &format!("no such field '{}' on type '{}'", field, name),
                        line,
                        column,
                    );
                }
                self.arena.fresh_type_var()
            }
            // 未决类型：静默返回 fresh var（推断未决，延迟到 solver 全局诊断）
            ConcreteType::TypeVar(_) | ConcreteType::Unknown
            | ConcreteType::Never | ConcreteType::Void => {
                self.arena.fresh_type_var()
            }
            // 已确定类型但字段查找失败：报错
            ct_other => {
                let recv_name = self.arena.type_name(resolved)
                    .map(|s| s.to_string())
                    .unwrap_or_else(|| format!("{:?}", ct_other));
                self.add_error_at(
                    &format!("no such field '{}' on type '{}'", field, recv_name),
                    line,
                    column,
                );
                self.arena.fresh_type_var()
            }
        }
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
                    if self.try_widen_unify(annot_ty, val_ty).is_err() {
                        let annot_str = format!("{}", self.arena.display(annot_ty));
                        let val_str = format!("{}", self.arena.display(val_ty));
                        let span = ast.ty(*ta).span;
                        self.add_error_at(
                            &format!(
                                "type annotation mismatch: expected '{}', found '{}'",
                                annot_str, val_str
                            ),
                            span.line,
                            span.column,
                        );
                    }
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
                if self.arena.unify(target_ty, val_ty).is_err() {
                    let target_str = format!("{}", self.arena.display(target_ty));
                    let val_str = format!("{}", self.arena.display(val_ty));
                    let span = ast.stmt(stmt).span;
                    self.add_error_at(
                        &format!(
                            "assignment type mismatch: cannot assign '{}' to '{}'",
                            val_str, target_str
                        ),
                        span.line,
                        span.column,
                    );
                }
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
                    // 传播 expected_return 给 infer_expr，使 NullLit / match arm 等
                    // 依赖 expected 约束的表达式能正确推导，避免创建孤儿 TypeVar。
                    let expected = self.expected_return;
                    let val_ty = self.infer_expr(*v, ast, env, expected);
                    if let Some(fn_ret) = self.expected_return {
                        if self.unify_return_type(fn_ret, val_ty).is_err() {
                            let ret_str = format!("{}", self.arena.display(fn_ret));
                            let val_str = format!("{}", self.arena.display(val_ty));
                            let span = ast.stmt(stmt).span;
                            self.add_error_at(
                                &format!(
                                    "return type mismatch: expected '{}', found '{}'",
                                    ret_str, val_str
                                ),
                                span.line,
                                span.column,
                            );
                        }
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
                let span = ast.stmt(stmt).span;
                self.check_throw_stmt(thrown_ty, span.line, span.column);
                None
            }
            Stmt::Break | Stmt::Continue => None,
            Stmt::For { name, iterable, body } => {
                let span = ast.stmt(stmt).span;
                let iterable_ty = self.infer_expr(*iterable, ast, env, None);
                let child_env = self.env.child(env);
                let item_ty = {
                    let resolved = self.arena.resolve(iterable_ty);
                    let ct = self.arena.get(resolved).clone();
                    // 检查 iterable 是否为非迭代器类型（Array/Str/基元）
                    let is_non_iterator = match &ct {
                        ConcreteType::Array { .. } => true,
                        ct if ct.classify_scalar().is_some() => true,
                        _ => false,
                    };
                    if is_non_iterator {
                        let type_name = match &ct {
                            ConcreteType::Array { .. } => "array",
                            _ => ct.builtin_name().unwrap_or("unknown"),
                        };
                        self.add_error_at(
                            &format!(
                                "类型 '{}' 未实现 Iterator，For 循环要求迭代器类型。数组请用 arr.iter()，字符串请用 str_iter(s)",
                                type_name
                            ),
                            span.line,
                            span.column,
                        );
                    }
                    // 循环变量类型用 fresh_type_var（next() 返回 T? 的内层 T 由 IR 运行时分派）
                    self.arena.fresh_type_var()
                };
                self.env.define(child_env, name, item_ty);
                let _ = self.infer_expr(*body, ast, child_env, None);
                None
            }
            Stmt::While { condition, body } => {
                let cond_ty = self.infer_expr(*condition, ast, env, None);
                let bool_ty = self.make_builtin(ConcreteType::Bool);
                if self.arena.unify(cond_ty, bool_ty).is_err() {
                    let cond_str = format!("{}", self.arena.display(cond_ty));
                    let span = ast.stmt(stmt).span;
                    self.add_error_at(
                        &format!(
                            "while condition must be bool, found '{}'",
                            cond_str
                        ),
                        span.line,
                        span.column,
                    );
                }
                let _ = self.infer_expr(*body, ast, env, None);
                None
            }
            Stmt::Loop { body } => {
                let _ = self.infer_expr(*body, ast, env, None);
                None
            }
            Stmt::LocalDecl { decl } => {
                // 统一走 check_decl：函数、类型、trait 嵌套声明共享同一处理路径
                // LocalDecl 的 Box<Decl> 无 span，由所属 Stmt 提供
                self.check_decl(decl.as_ref(), ast.stmt(stmt).span, ast, env);
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
                        self.unify_or_constrain(lt, expected_ty);
                    }
                }
            }
            Pattern::Variable { name } => {
                // 大写开头 → 零参构造器
                if name.chars().next().map(|c| c.is_uppercase()).unwrap_or(false) {
                    let sub_pats: Vec<PatternRef> = Vec::new();
                    self.refine_constructor_pattern(name, &sub_pats, expected_ty, ast, env);
                } else {
                    self.env.define(env, name, expected_ty);
                }
            }
            Pattern::Constructor { name, patterns } => {
                if !self.refine_constructor_pattern(name, patterns, expected_ty, ast, env) {
                    // 常规构造器 fallback：使用 field_type_reprs（自包含 TypeRepr）
                    // 替代 field_type_nodes（AST 引用），避免跨模块 AST arena 不匹配。
                    let field_type_reprs: Box<[TypeRepr]> = self
                        .sema_result
                        .get_ctor_def(name)
                        .map(|c| c.field_type_reprs.clone())
                        .unwrap_or_else(|| Box::new([]));
                    for (i, &sub_pat) in patterns.iter().enumerate() {
                        let sub_ty = if i < field_type_reprs.len() {
                            self.type_repr_to_handle(&field_type_reprs[i])
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
                self.unify_or_constrain(cond_ty, bool_ty);
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

        // type/type_name 已改为 glue wrapper（见 Reflect.glue::type_name）
        // Sema 不再注册 type builtin

        // Ok: ∀T,E. (T) -> Throw<T, E>
        // 用 rigid var 注册（泛型参数），调用时由 instantiate_fn_type 实例化为 fresh non-rigid var
        let val_ty = self.arena.fresh_rigid_var();
        let err_ty = self.arena.fresh_rigid_var();
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
        // 用 rigid var 注册，调用时由 instantiate_fn_type 实例化
        for &(name, ref ct) in NUMERIC_BUILTIN_NAMES {
            let param = self.arena.fresh_rigid_var();
            let ret_ty = self.make_builtin(ct.clone());
            let fn_ty = self.arena.make(ConcreteType::Fn {
                params: vec![param].into_boxed_slice(),
                return_type: ret_ty,
            });
            self.env.define(env, name, fn_ty);
        }

        // channel<T>(capacity: usize) -> Channel<T>
        // 内置 channel 构造器：创建容量为 capacity 的 Channel<T>
        let usize_ty = self.make_builtin(ConcreteType::Usize);
        let t_var3 = self.arena.fresh_rigid_var();
        let chan_ret = self.arena.make(ConcreteType::Generic {
            name: "Channel".into(),
            args: vec![t_var3].into_boxed_slice(),
        });
        let chan_fn = self.arena.make(ConcreteType::Fn {
            params: vec![usize_ty].into_boxed_slice(),
            return_type: chan_ret,
        });
        self.env.define(env, "channel", chan_fn);

        // Value：builtin opaque 类型（ValueHandle, u32）
        // 反射原语接收 Value，内部查 ValueArena 拿 HeapObj 直接 match。
        // 对 Sema 是 opaque 类型（不暴露内部结构），大小 4B。
        let value_ty = self.arena.make(ConcreteType::Generic {
            name: "Value".into(),
            args: Box::new([]),
        });
        self.env.define(env, "Value", value_ty);
    }

    // ── check_module ──

    /// 获取或创建模块路径对应的专属 EnvId。
    ///
    /// 按路径段逐级创建 env，形成层级结构：
    ///   "std.io.File" → 创建 env_std (parent=root_env)
    ///                  → env_std_io (parent=env_std)
    ///                  → env_std_io_file (parent=env_std_io)
    ///
    /// 每一级 env 中会注册子模块短名 → ModuleRef，使逐级字段访问能通过 env 链结构化查找。
    /// 已存在的路径 env 会被复用（幂等）。
    ///
    /// 返回该路径对应的 EnvId。
    fn ensure_module_env(&mut self, full_path: &str, root_env: EnvId) -> EnvId {
        // 已缓存：直接返回
        if let Some(&eid) = self.module_envs.get(full_path) {
            return eid;
        }
        let segments: Vec<&str> = full_path.split('.').collect();
        let mut current_path = String::new();
        let mut parent_env = root_env;
        for (i, seg) in segments.iter().enumerate() {
            if i > 0 {
                current_path.push('.');
            }
            current_path.push_str(seg);
            // 当前路径段的 env：已存在则复用，否则创建
            let env_id = if let Some(&eid) = self.module_envs.get(&current_path) {
                eid
            } else {
                let eid = self.env.child(parent_env);
                self.module_envs.insert(current_path.clone(), eid);
                eid
            };
            // 在父 env 中注册当前段短名 → ModuleRef（使逐级字段访问可查到）
            // 首段注册到 root_env，其余段注册到父路径 env
            let mod_ref_ty = self.arena.make(ConcreteType::ModuleRef {
                path: current_path.clone().into_boxed_str(),
                env: env_id,
            });
            // 不覆盖已存在的绑定（用户显式 import / 构造器优先）
            self.env.define(parent_env, seg, mod_ref_ty);
            parent_env = env_id;
        }
        parent_env
    }

    /// 注册模块路径别名到环境（用于同包模块符号可见性）。
    ///
    /// 为每个模块路径创建层级 env，并在 root_env 中注册末段短名 → ModuleRef，
    /// 使同包模块可直接通过短名访问（如 `Calendar` → `ModuleRef("std.time.Calendar", env)`）。
    /// 已存在的绑定不会被覆盖（用户显式 import 优先）。
    pub fn register_module_aliases(&mut self, root_env: EnvId, module_paths: &[String]) {
        for path in module_paths {
            if path.is_empty() {
                continue;
            }
            // 确保模块层级 env 存在（含中间路径前缀）
            let module_env = self.ensure_module_env(path, root_env);
            // 在 root_env 注册末段短名（同包短名访问）
            if let Some(last_seg) = path.rsplit('.').next() {
                if !last_seg.is_empty() && path.contains('.') {
                    // 不覆盖已存在的绑定
                    if self.env.lookup(root_env, last_seg).is_none() {
                        let mod_ref_ty = self.arena.make(ConcreteType::ModuleRef {
                            path: path.clone().into_boxed_str(),
                            env: module_env,
                        });
                        self.env.define(root_env, last_seg, mod_ref_ty);
                    }
                }
            }
        }
    }

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
        // 单模块检查：创建新 root_env，注册 builtins，检查模块
        self.reset_state();
        let root_env = self.env.root();
        self.register_builtins(root_env);
        self.check_module_with_env(module, root_env)
    }

    /// 多模块共享 env 检查入口。
    ///
    /// 接受外部共享的 `root_env`（已注册 builtins 和前置模块的符号），
    /// 在此基础上处理 import、预声明、检查当前模块。
    /// 跨模块符号通过共享 env 链查找。
    pub fn check_module_with_env(&mut self, module: &Module<'_>, root_env: EnvId) -> bool {
        // 1. 填充定义表（若尚未填充）
        populate_module(self.sema_result, module);

        // 2. 重置状态（不重置 env，保留共享 root_env）
        self.reset_state();
        // 快照当前 type_vars/types 长度：arena 跨模块共享不重置，诊断时只统计本模块新增的 TypeVar
        let type_vars_baseline = self.arena.type_vars_len();
        let types_baseline = self.arena.len();
        self.current_module_logical_path = module_logical_path(module.name);
        self.current_module_name = module.name.to_string();

        // 3. 处理 import 声明：注册模块引用别名 + import 别名
        self.process_import_decls(module, root_env);

        // 4. 预声明函数和类型构造器（含 extern 函数）
        self.predeclare_declarations(module, root_env);

        // 5. 填充 witness table（遍历 trait impl）
        self.populate_witness_table(module);

        // 6. 推导声明
        // 使用 module_env 作为基环境（而非 root_env），使函数体可通过 env 链
        // 查找同模块函数（predeclare_declarations 注册于 module_env），
        // 同时仍可通过父链访问 root_env 的全局 builtins 和构造器。
        let check_env = self.current_module_env.unwrap_or(root_env);
        for decl in module.declarations.iter() {
            self.check_decl(&decl.node, decl.span, &module.arena, check_env);
        }

        // 7. kind_check 所有类型注解
        self.run_kind_checks(module);

        // 8. 收集单态化实例
        collect_monomorph_instances(module, self.sema_result);

        // 9. 求解延迟约束（带 witness table 支持 trait bound 求解）
        // 分离借用 self 的不同字段：arena 可变借用，witness_table 只读借用
        let InferContext { arena, solver, witness_table, type_trace, .. } = self;
        solver.solve_with_witness(arena, Some(witness_table));

        // 9.5 全局残留 TypeVar 诊断：求解后仍有未绑定的非 rigid TypeVar 表示类型推断失败
        // 只统计本模块新增的 TypeVar（arena 跨模块共享，baseline 之前的属于前置模块）
        let unresolved: Vec<u32> = arena.type_vars.iter().enumerate()
            .skip(type_vars_baseline)
            .filter(|(_, tv)| !tv.is_rigid && tv.bound.is_none())
            .map(|(i, _)| i as u32)
            .collect();

        // 详细日志（环境变量 GLUE_SEMA_TRACE 控制）：打印未解析 TypeVar 详情，便于定位
        if !unresolved.is_empty() && std::env::var("GLUE_SEMA_TRACE").is_ok() {
            let unresolved_set: FxHashSet<u32> = unresolved.iter().copied().collect();
            eprintln!(
                "[sema] {} unresolved type variable(s) after constraint solving:",
                unresolved.len()
            );
            for &idx in unresolved.iter().take(50) {
                let tv = &arena.type_vars[idx as usize];
                eprintln!("  TypeVar({}) kind={:?}", idx, tv.kind);
            }
            if unresolved.len() > 50 {
                eprintln!("  ... and {} more", unresolved.len() - 50);
            }
            // 打印包含未解析 TypeVar 的类型槽位样本（最多 30 个）
            // 只遍历本模块新增的类型槽位（baseline 之前的属于前置模块）
            eprintln!("  sample referencing types (baseline={}):", types_baseline);
            let mut shown = 0u32;
            for i in types_baseline..arena.types.len() {
                let h = TypeHandle(i as u32);
                let s = format!("{}", arena.display(h));
                if s.contains("'_") {
                    eprintln!("    types[{}] = {}", i, s);
                    shown += 1;
                    if shown >= 30 { break; }
                }
            }
            // 反向定位：遍历 type_trace，找到引用未解析 TypeVar 的表达式 span
            eprintln!("  referencing expression spans:");
            let mut span_shown = 0u32;
            for &(ty, span) in type_trace.iter() {
                if type_contains_any_unresolved(ty, arena, &unresolved_set) {
                    let s = format!("{}", arena.display(ty));
                    eprintln!("    {}:{}  {}", span.line, span.column, s);
                    span_shown += 1;
                    if span_shown >= 50 { break; }
                }
            }
            if span_shown == 0 {
                eprintln!("    (no direct expression references found — TypeVar may be inside fn signature)");
            }
        }

        // 10. 镜像 witness_table 到 sema_result（供 IR 层访问 trait 方法分派信息）
        // witness_table 跨模块累积，每次 check 完成后同步最新状态。
        self.sema_result.witness_table = witness_table.clone();

        // 11. 报告全局残留 TypeVar 诊断
        if !unresolved.is_empty() {
            self.add_error_at(
                &format!("{} unresolved type variable(s) after constraint solving", unresolved.len()),
                0, 0,
            );
        }

        !self.sema_result.has_error
    }

    /// 重置检查状态（env 不重置，保留共享 root_env）。
    pub fn reset_state(&mut self) {
        self.expected_return = None;
        self.type_binding_stack = TypeBindingStack::new();
        self.self_binding_stack = SelfBindingStack::new();
        self.solver.reset();
        self.flow_ctx.reset();
        self.type_trace.clear();
        // witness_table 不重置（跨模块累积，支持多模块 trait 实现）
    }

    /// 处理模块中的 ImportDecl：
    /// - 整路径导入 `import std.io.File` → 确保模块层级 env 存在，首段注册为 ModuleRef
    ///   （字段访问逐级构建路径：std → std.io → std.io.File，通过 env 链查找）
    /// - selective import `import std.io.File { open }` → 从目标模块 env 查找符号并注册别名
    fn process_import_decls(&mut self, module: &Module<'_>, env: EnvId) {
        // 注册当前模块自身的模块路径前缀（如 std/io/Path.glue → std.io.Path）
        // 使模块内自引用（如 std.io.Path.last_index_of）可解析
        if let Some(logical_path) = module_logical_path(module.name) {
            // ensure_module_env 会创建层级 env 并在父 env 注册首段 ModuleRef
            self.ensure_module_env(&logical_path, env);
        }

        for decl in module.declarations.iter() {
            if let Decl::ImportDecl { module_path, items, .. } = &decl.node {
                if module_path.is_empty() {
                    continue;
                }
                let full_path = module_path.join(".");
                // 确保导入模块的层级 env 存在（含中间路径前缀和首段 ModuleRef 注册）
                let module_env = self.ensure_module_env(&full_path, env);

                // selective import：从目标模块 env 查找符号并注册到当前 env
                if let Some(items) = items {
                    for item in items.iter() {
                        // 在模块 env 中按裸名查找符号（不穿透父 env，避免导入全局符号）
                        if let Some(sym_ty) = self.env.lookup_local(module_env, item.name) {
                            let local_name = item.alias.unwrap_or(item.name);
                            self.env.define(env, local_name, sym_ty);
                        }
                    }
                }
            }
        }
    }

    /// 填充 witness table：遍历模块中的 trait impl，注册到 witness table。
    ///
    /// 对于每个 `impl Trait for Type`，提取 trait_name 和 type_name，
    /// 查询 type_def 获取 type_id，将方法注册到 witness table。
    fn populate_witness_table(&mut self, module: &Module<'_>) {
        type TraitImplInfo = (String, String, Vec<(String, u16)>);
        // 收集 trait impl 信息，避免在遍历时借用 module 同时 &mut self
        let mut impls: Vec<TraitImplInfo> = Vec::new();

        for decl in module.declarations.iter() {
            if let Decl::TypeDecl { name, implemented_traits, methods, .. } = &decl.node {
                // 查询 type_id（用 type_def_index + 22 偏移）
                let type_id = self
                    .sema_result
                    .type_def_index
                    .get(*name)
                    .map(|&idx| 22 + idx);

                if let Some(tid) = type_id {
                    // 为每个实现的 trait 注册 witness entry
                    for impl_trait in implemented_traits.iter() {
                        let trait_name = impl_trait.trait_name.to_string();
                        // 收集方法槽位：method_name → method_idx（在 TypeDefInfo.methods 中的位置）
                        let method_slots: Vec<(String, u16)> = methods
                            .iter()
                            .enumerate()
                            .map(|(i, m)| (m.name.to_string(), i as u16))
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
                .map(|&idx| 22 + idx);
            if let Some(tid) = type_id {
                let mut slots = FxHashMap::default();
                for (method_name, method_idx) in method_slots_vec {
                    slots.insert(method_name.into_boxed_str(), method_idx);
                }
                self.witness_table
                    .register(&trait_name, tid, &type_name, slots);
            }
        }
    }

    /// 预声明模块中的函数和类型构造器到环境。
    ///
    /// 函数和类型构造器注册到模块专属 env（module_env），而非 root_env。
    /// 模块 env 的父环境指向 root_env（或父路径 env），使模块内可访问全局 builtins。
    /// 调用方通过 ModuleRef 携带的 env 引用直接在模块 env 中按裸名查找，无需 mangled name。
    pub fn predeclare_declarations(&mut self, module: &Module<'_>, root_env: EnvId) {
        let module_path = module_logical_path(module.name);
        // 获取或创建模块专属 env（幂等：ensure_module_env 会复用已存在的 env）
        let module_env = match &module_path {
            Some(mp) => self.ensure_module_env(mp, root_env),
            None => root_env,
        };
        // 记录当前模块 env，供 check_decl 中的 let 绑定等使用
        self.current_module_env = Some(module_env);
        for decl in module.declarations.iter() {
            match &decl.node {
                Decl::FunDecl { name, type_params, params, return_type, .. } => {
                    // 顶层函数不允许 self 参数（通过 SelfType 类型节点判断，不依赖参数名）
                    if !params.is_empty() && self.is_self_param(params[0].type_annotation, &module.arena) {
                        self.add_error_at(
                            "self parameter is not allowed in top-level function",
                            decl.span.line,
                            decl.span.column,
                        );
                    }
                    // 所有函数都预声明（含泛型）：泛型函数用 fresh_type_var 占位参数/返回类型，
                    // 解决前向引用问题（函数体内可引用后续定义的同模块函数）
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
                    // 注册到模块专属 env（裸名），ModuleRef 查找时通过 lookup_local 在此 env 中查找
                    // 同时注册到 root_env 使其全局可见（跨模块裸名引用兼容）：
                    //   define 不覆盖已存在绑定，同名函数首次注册生效
                    self.env.define(module_env, name, fn_ty);
                    self.env.define(root_env, name, fn_ty);
                    let _ = type_params; // 泛型参数暂不处理，预声明用具体类型
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
                    // 构造器注册到 root_env（而非 module_env）：
                    // 构造器是类型的伴生符号，与类型在同一命名层级，
                    // 需通过 redefine 覆盖 register_module_aliases 先注册的 ModuleRef 别名，
                    // 使 `DateTime(...)` 解析为构造器而非 ModuleRef。
                    match def {
                        crate::Ast::TypeDef::Adt { constructors } => {
                            for ctor in constructors.iter() {
                                let ctor_fn_ty = self.build_ctor_fn_type(ctor, name, &module.arena);
                                self.env.redefine(root_env, ctor.name, ctor_fn_ty);
                            }
                        }
                        crate::Ast::TypeDef::Newtype { name: ctor_name, inner } => {
                            // newtype 构造器：(inner) -> Self
                            let inner_ty = self.type_from_ast(*inner, &module.arena);
                            let ctor_fn_ty = self.arena.make(ConcreteType::Fn {
                                params: vec![inner_ty].into_boxed_slice(),
                                return_type: self_ty,
                            });
                            self.env.redefine(root_env, ctor_name, ctor_fn_ty);
                        }
                        _ => {}
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
        // 零参数变体是值，不是函数：Leaf 的类型应为 Tree 而非 () -> Tree
        if param_types.is_empty() {
            return ret_ty;
        }
        self.arena.make(ConcreteType::Fn {
            params: param_types.into_boxed_slice(),
            return_type: ret_ty,
        })
    }

    /// 检查单个声明（推导函数体/表达式）。
    ///
    /// 接受 `&Decl` 与 `decl_span` 分开参数：顶层声明从 `Spanned<Decl>` 取 span+node，
    /// 嵌套 `LocalDecl` 的 `Box<Decl>` 无 span，由调用方从所属 Stmt 提供。
    fn check_decl(&mut self, decl: &Decl<'_>, decl_span: crate::Ast::Span, ast: &AstArena<'_>, env: EnvId) {
        match decl {
            Decl::FunDecl { name, type_params, params, return_type, body, extern_c_body, is_async: _, .. } => {
                // 顶层函数不允许 self 参数（通过 SelfType 类型节点判断，不依赖参数名；
                // self 只能在 type/trait 块内方法中使用）
                if !params.is_empty() && self.is_self_param(params[0].type_annotation, ast) {
                    self.add_error_at(
                        "self parameter is not allowed in top-level function",
                        decl_span.line,
                        decl_span.column,
                    );
                }
                // 为函数创建子环境
                let fn_env = self.env.child(env);
                // 类型参数绑定
                if !type_params.is_empty() {
                    self.push_type_bindings(
                        &type_params.iter().map(|tp| {
                            (tp.name, tp.kind.as_ref().map(|k| SemKind::from_ast(k)))
                        }).collect::<Vec<_>>(),
                    );
                }
                // @extern("C") 函数：注册签名但跳过函数体类型检查（body 为 C 代码，非 Glue 表达式）
                if extern_c_body.is_some() {
                    if !type_params.is_empty() {
                        self.pop_type_bindings();
                    }
                    let _ = name;
                    return;
                }
                // 参数绑定（同时收集参数类型用于构造函数类型）
                let param_types: Vec<TypeHandle> = params.iter().map(|p| {
                    let param_ty = match p.type_annotation {
                        Some(ta) => self.type_from_ast(ta, ast),
                        None => self.arena.fresh_type_var(),
                    };
                    self.env.define(fn_env, p.name, param_ty);
                    param_ty
                }).collect();
                // 返回类型（未标注时用 fresh_type_var，后续与函数体类型统一）
                let ret_ty = match return_type {
                    Some(rt) => self.type_from_ast(*rt, ast),
                    None => self.arena.fresh_type_var(),
                };
                // 构造函数类型并注册到 fn_env（支持递归自引用）和 env（支持后续引用）
                // 顶层函数已由 predeclare_declarations 预注册，define 返回 false 不覆盖
                let fn_ty = self.arena.make(ConcreteType::Fn {
                    params: param_types.into_boxed_slice(),
                    return_type: ret_ty,
                });
                self.env.define(fn_env, *name, fn_ty);
                self.env.define(env, *name, fn_ty);
                // 设置返回类型
                let prev_return = self.expected_return;
                self.expected_return = Some(ret_ty);
                // 推导函数体
                let body_ty = self.infer_expr(*body, ast, fn_env, self.expected_return);
                // 恢复
                self.expected_return = prev_return;
                // 返回类型与函数体类型统一：
                // - 无标注返回类型：ret_ty 为 fresh TypeVar，用 unify_or_constrain 绑定
                // - 有标注返回类型：用 unify_return_type 统一，处理 async 穿透
                //   （声明 Async<Throw<T, E>>，body 直接返回 Throw<T', E'>，
                //    需穿透 Async 层统一内层 Throw，使 E' 中的 TypeVar 被求解）
                //   失败时注册 Equality 约束供 solver 延迟重试
                if return_type.is_none() {
                    self.unify_or_constrain(ret_ty, body_ty);
                } else if self.unify_return_type(ret_ty, body_ty).is_err() {
                    self.solver.add_equality(ret_ty, body_ty);
                }
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
            Decl::TypeDecl { name, type_params, def, methods, .. } => {
                // 注册嵌套类型定义到 sema_result（使构造器调用可被类型检查识别）
                ast_type_decl_to_type_def(self.sema_result, *name, type_params, def, ast);
                // 类型参数绑定（含 kind 注册）：使类型块内部引用泛型参数 T 时可从 type_binding_stack 解析
                if !type_params.is_empty() {
                    self.push_type_bindings(
                        &type_params.iter().map(|tp| {
                            (tp.name, tp.kind.as_ref().map(|k| SemKind::from_ast(k)))
                        }).collect::<Vec<_>>(),
                    );
                }
                // 构造 ADT 类型 handle
                let self_ty = if type_params.is_empty() {
                    self.arena.make(ConcreteType::Adt {
                        name: (*name).into(),
                        type_args: Box::new([]),
                    })
                } else {
                    // 泛型类型：构造 Adt { name, type_args: [rigid_T, ...] }
                    // 使用 type_binding_stack 中的 rigid var 作为 type_args，
                    // 避免 fresh_type_var 作为 self_ty 产生未解析 TypeVar
                    let type_args: Vec<TypeHandle> = type_params.iter()
                        .map(|tp| self.lookup_type_binding(tp.name)
                            .unwrap_or_else(|| self.arena.fresh_type_var()))
                        .collect();
                    self.arena.make(ConcreteType::Adt {
                        name: (*name).into(),
                        type_args: type_args.into_boxed_slice(),
                    })
                };
                // 将构造器函数类型注册到当前环境（使 Call 表达式能查找到构造器）
                match def {
                    crate::Ast::TypeDef::Record { fields } => {
                        let param_types: Vec<TypeHandle> = fields.iter().map(|f| {
                            self.type_from_ast(f.ty, ast)
                        }).collect();
                        let fn_ty = self.arena.make(ConcreteType::Fn {
                            params: param_types.into_boxed_slice(),
                            return_type: self_ty,
                        });
                        self.env.define(env, *name, fn_ty);
                    }
                    crate::Ast::TypeDef::Adt { constructors } => {
                        for ctor in constructors {
                            let param_types: Vec<TypeHandle> = ctor.fields.iter().map(|f| {
                                self.type_from_ast(f.ty, ast)
                            }).collect();
                            let fn_ty = if param_types.is_empty() {
                                // 零参数变体是值，不是函数
                                self_ty
                            } else {
                                self.arena.make(ConcreteType::Fn {
                                    params: param_types.into_boxed_slice(),
                                    return_type: self_ty,
                                })
                            };
                            self.env.define(env, ctor.name, fn_ty);
                        }
                    }
                    crate::Ast::TypeDef::Alias { .. } | crate::Ast::TypeDef::Newtype { .. } => {}
                }
                // 类型方法检查
                self.push_self_type(self_ty);
                // 先注册所有方法为函数到 env（支持裸名方法调用 method(recv, args) 语法糖），
                // 再检查方法体（避免前向引用问题）
                for method in methods.iter() {
                    let m_param_types: Vec<TypeHandle> = method.params.iter().map(|p| {
                        if self.is_self_param(p.type_annotation, ast) {
                            self_ty
                        } else {
                            match p.type_annotation {
                                Some(ta) => self.type_from_ast(ta, ast),
                                None => self.arena.fresh_type_var(),
                            }
                        }
                    }).collect();
                    let m_ret_ty = match method.return_type {
                        Some(rt) => self.type_from_ast(rt, ast),
                        None => self.arena.fresh_type_var(),
                    };
                    let m_fn_ty = self.arena.make(ConcreteType::Fn {
                        params: m_param_types.into_boxed_slice(),
                        return_type: m_ret_ty,
                    });
                    self.env.define(env, method.name, m_fn_ty);
                }
                for method in methods.iter() {
                    if let Some(body) = method.body {
                        let method_env = self.env.child(env);
                        for param in method.params.iter() {
                            let param_ty = if self.is_self_param(param.type_annotation, ast) {
                                self.infer_self_param(param.type_annotation, ast)
                            } else {
                                match param.type_annotation {
                                    Some(ta) => self.type_from_ast(ta, ast),
                                    None => self.arena.fresh_type_var(),
                                }
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
                if !type_params.is_empty() {
                    self.pop_type_bindings();
                }
            }
            Decl::TraitDecl { name, type_params, methods, .. } => {
                // 注册嵌套 trait 定义到 sema_result（使 trait 类型标注可被识别）
                ast_trait_decl_to_trait_def(self.sema_result, name, methods, ast);
                // 类型参数绑定（含 kind 注册）：使 trait 块内部引用泛型参数时可从 type_binding_stack 解析
                if !type_params.is_empty() {
                    self.push_type_bindings(
                        &type_params.iter().map(|tp| {
                            (tp.name, tp.kind.as_ref().map(|k| SemKind::from_ast(k)))
                        }).collect::<Vec<_>>(),
                    );
                }
                let self_var = self.push_self_type_var();
                for method in methods.iter() {
                    if let Some(body) = method.body {
                        let method_env = self.env.child(env);
                        for param in method.params.iter() {
                            let param_ty = if self.is_self_param(param.type_annotation, ast) {
                                self.infer_self_param(param.type_annotation, ast)
                            } else {
                                match param.type_annotation {
                                    Some(ta) => self.type_from_ast(ta, ast),
                                    None => self.arena.fresh_type_var(),
                                }
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
                if !type_params.is_empty() {
                    self.pop_type_bindings();
                }
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
                Decl::TypeDecl { def: crate::Ast::TypeDef::Adt { constructors }, .. } => {
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
// - DOD：约束用 Vec，snapshot 用长度索引，subst 用 FxHashMap
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
    // 已知限制：Constraint 枚举不携带 span 信息，求解时无法回溯 AST 位置，
    // 故 line/column 恒为 0,0。完整修复需为 Constraint 添加 span 字段。
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
    subst: FxHashMap<u32, TypeHandle>,
    errors: Vec<ConstraintError>,
    /// 每个 TypeVar 在不动点迭代中收到的所有候选绑定（多值记录）。
    ///
    /// key = TypeVar idx，value = 该 TypeVar 被要求绑定的所有目标类型 handle 列表。
    /// 不动点收敛后由 `finalize_solution` 去重并检测歧义：
    /// - 唯一候选 → 写入 subst
    /// - 多个不同候选 → 标记歧义错误（仍选 arena 的实际解写入 subst 以避免级联误报）
    candidates: FxHashMap<u32, Vec<TypeHandle>>,
}

/// Snapshot 内部状态：pending 长度 + subst 快照 + candidates 快照
#[derive(Debug, Clone)]
struct SnapshotState {
    pending_len: usize,
    subst_snapshot: FxHashMap<u32, TypeHandle>,
    errors_len: usize,
    candidates_snapshot: FxHashMap<u32, Vec<TypeHandle>>,
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
            subst: FxHashMap::default(),
            errors: Vec::new(),
            candidates: FxHashMap::default(),
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
            candidates_snapshot: self.candidates.clone(),
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
        self.candidates = state.candidates_snapshot;
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
    /// 不动点迭代：重复扫描约束队列，直到一轮无新绑定产生。
    /// 约束间存在依赖关系（约束 A 依赖约束 B 先绑定某 TypeVar），
    /// 单遍 FIFO 会因时序问题漏解；不动点迭代通过重试消除时序依赖。
    ///
    /// - Equality：两边仍含 TypeVar 时重新入队等待下一轮；两边都是具体类型时记入 errors
    /// - TraitBound：ty 仍是 TypeVar 时重新入队；否则查 witness table 判定
    /// - Subtype/Narrow：单遍处理（不涉及 TypeVar 绑定传播）
    pub fn solve_with_witness(&mut self, arena: &mut TypeArena, witness: Option<&WitnessTable>) {
        const MAX_ITERATIONS: usize = 1000;
        let mut pending = std::mem::take(&mut self.pending);

        for _iteration in 0..MAX_ITERATIONS {
            if pending.is_empty() {
                break;
            }

            // 取出当前所有约束，本轮处理
            let current = std::mem::take(&mut pending);
            let mut changed = false;

            for c in current {
                match c {
                    Constraint::Equality(t1, t2) => {
                        // 在 resolve/unify 之前记录候选（多值记录）。
                        // arena.get 返回原始 ConcreteType，即使 TypeVar 已被
                        // 之前的 unify 绑定，get 仍返回 TypeVar(idx)，
                        // 因此能捕捉到所有约束路径对该 TypeVar 的绑定要求。
                        self.record_candidate(arena, t1, t2);

                        let r1 = arena.resolve(t1);
                        let r2 = arena.resolve(t2);

                        // 两边都已解析为同一类型，无需处理
                        if r1 == r2 {
                            continue;
                        }

                        match arena.unify(r1, r2) {
                            Ok(()) => {
                                changed = true;
                            }
                            Err(_) => {
                                // unify 失败：若两边仍含 TypeVar，重新入队等待下一轮
                                // （其他约束可能在本轮绑定这些 TypeVar）
                                let r1_has_var = Self::resolve_has_type_var(arena, r1);
                                let r2_has_var = Self::resolve_has_type_var(arena, r2);
                                if r1_has_var || r2_has_var {
                                    pending.push(Constraint::Equality(t1, t2));
                                } else {
                                    // 两边都是具体类型且不匹配：真错误
                                    self.errors.push(ConstraintError {
                                        constraint: Constraint::Equality(t1, t2),
                                        reason: "type mismatch".into(),
                                        line: 0,
                                        column: 0,
                                    });
                                }
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
                        let resolved = arena.resolve(ty);
                        // ty 仍是 TypeVar：重新入队等待下一轮
                        if matches!(arena.get(resolved), ConcreteType::TypeVar(_)) {
                            pending.push(Constraint::TraitBound {
                                ty,
                                trait_name,
                                type_args,
                            });
                            continue;
                        }

                        // ty 已解析：查 witness table 判定
                        if let Some(wt) = witness {
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
                    }
                    Constraint::Narrow { .. } => {
                        // 延迟到 flow narrowing 实现（phase 3）
                    }
                }
            }

            // 不动点：一轮无新绑定且无重新入队的约束，结束
            if !changed {
                break;
            }
        }

        // 超过 MAX_ITERATIONS 仍未收敛的约束：记录但不报错（防御性）
        // 这些通常是 TypeVar ↔ TypeVar 的循环依赖，不影响正确性

        // 不动点收敛后：从 candidates 构建 subst，检测歧义
        self.finalize_solution(arena);
    }

    /// 判断 resolve 后的 TypeHandle 是否仍含未绑定 TypeVar。
    /// 用于不动点迭代中决定是否重新入队约束。
    fn resolve_has_type_var(arena: &TypeArena, ty: TypeHandle) -> bool {
        let resolved = arena.resolve(ty);
        match arena.get(resolved) {
            ConcreteType::TypeVar(_) => true,
            ConcreteType::Fn { params, return_type } => {
                params.iter().any(|&p| Self::resolve_has_type_var(arena, p))
                    || Self::resolve_has_type_var(arena, *return_type)
            }
            ConcreteType::Nullable(inner) => Self::resolve_has_type_var(arena, *inner),
            ConcreteType::Ref { inner, .. } => Self::resolve_has_type_var(arena, *inner),
            ConcreteType::Adt { type_args, .. } => {
                type_args.iter().any(|&a| Self::resolve_has_type_var(arena, a))
            }
            ConcreteType::Throw { value_type, error_type } => {
                Self::resolve_has_type_var(arena, *value_type)
                    || Self::resolve_has_type_var(arena, *error_type)
            }
            ConcreteType::Generic { args, .. } => {
                args.iter().any(|&a| Self::resolve_has_type_var(arena, a))
            }
            ConcreteType::Trait { type_args, .. } => {
                type_args.iter().any(|&a| Self::resolve_has_type_var(arena, a))
            }
            ConcreteType::Array { element_type, .. } => {
                Self::resolve_has_type_var(arena, *element_type)
            }
            _ => false,
        }
    }

    /// 记录 TypeVar 的候选绑定到 candidates（多值记录）。
    ///
    /// 在 unify **之前**调用，用 `arena.get`（原始 ConcreteType，不 resolve）判断 TypeVar。
    /// 即使 TypeVar 已被先前 unify 绑定到具体类型，`get` 仍返回 `TypeVar(idx)`，
    /// 因此能捕捉到所有约束路径对该 TypeVar 的绑定要求，用于后续歧义检测。
    ///
    /// - 若 t1 是 TypeVar 且 t2 不是 → candidates[t1.idx].push(t2)
    /// - 若 t2 是 TypeVar 且 t1 不是 → candidates[t2.idx].push(t1)
    /// - 两边都是 TypeVar → 不记录（var-var 绑定由 unify 直接处理）
    fn record_candidate(&mut self, arena: &TypeArena, t1: TypeHandle, t2: TypeHandle) {
        match (arena.get(t1), arena.get(t2)) {
            (ConcreteType::TypeVar(_), ConcreteType::TypeVar(_)) => {
                // 两边都是 TypeVar：由 unify 处理 var-var 绑定，不记录候选
            }
            (ConcreteType::TypeVar(idx), _) => {
                self.candidates.entry(*idx).or_default().push(t2);
            }
            (_, ConcreteType::TypeVar(idx)) => {
                self.candidates.entry(*idx).or_default().push(t1);
            }
            _ => {}
        }
    }

    /// 不动点收敛后从 candidates 构建最终 subst，并检测歧义。
    ///
    /// 对每个 TypeVar 的候选集：
    /// 1. 基于 resolve 后的 TypeHandle 相等性去重
    /// 2. 唯一候选 → 写入 subst
    /// 3. 多个不同候选 → 标记歧义错误，仍选 arena 实际解写入 subst（避免级联误报）
    fn finalize_solution(&mut self, arena: &TypeArena) {
        let candidates = std::mem::take(&mut self.candidates);
        for (idx, cands) in candidates {
            // 去重：基于 resolve 后的 TypeHandle 相等性
            let mut unique: Vec<TypeHandle> = Vec::new();
            for c in &cands {
                let r = arena.resolve(*c);
                if !unique.iter().any(|&u| arena.resolve(u) == r) {
                    unique.push(r);
                }
            }

            match unique.len() {
                0 => {} // 不可能（cands 非空才会迭代）
                1 => {
                    // 唯一候选：写入 subst
                    self.subst.insert(idx, unique[0]);
                }
                _ => {
                    // 多个不同候选：歧义
                    // 选 arena 实际解（unify 已选第一个成功的）写入 subst，避免级联误报
                    let resolved = arena.resolve(cands[0]);
                    self.subst.insert(idx, resolved);
                    // 记录歧义错误
                    self.errors.push(ConstraintError {
                        constraint: Constraint::Equality(unique[0], unique[1]),
                        reason: format!(
                            "ambiguous inference for TypeVar{}: {} distinct candidates",
                            idx,
                            unique.len()
                        )
                        .into(),
                        line: 0,
                        column: 0,
                    });
                }
            }
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
        self.candidates.clear();
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
/// DOD：facts 用 Vec，by_path 用 FxHashMap 索引。
#[derive(Default)]
pub struct FlowFactTable {
    facts: Vec<FlowFact>,
    /// 按路径索引：path → fact indices
    by_path: FxHashMap<Box<str>, Vec<u32>>,
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
///
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

    /// 解析 trait 方法 → 实现类型的 method_idx。
    ///
    /// 通过 (trait_name, type_id) 定位 witness entry，
    /// 确认 method_name 存在于方法槽中，返回 method_idx。
    /// IR 层用 (type_id, method_idx) 查 method_subgraphs 获取子图。
    pub fn resolve_method_idx(
        &self,
        trait_name: &str,
        type_id: u16,
        method_name: &str,
    ) -> Option<u16> {
        self.resolve_method(trait_name, type_id, method_name)
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