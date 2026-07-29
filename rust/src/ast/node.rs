//! AST 节点定义：表达式、语句、声明、类型节点、模式、类型定义与模块

use crate::ast::op::*;
use crate::ast::span::Spanned;

// =========================================================================
// 引用类型别名
//
// 所有子节点通过 arena 分配后以引用形式持有，零拷贝引用源码。
// =========================================================================

pub type ExprRef<'a> = &'a Spanned<Expr<'a>>;
pub type StmtRef<'a> = &'a Spanned<Stmt<'a>>;
pub type TypeRef<'a> = &'a Spanned<TypeNode<'a>>;
pub type PatternRef<'a> = &'a Spanned<Pattern<'a>>;
pub type KindRef<'a> = &'a Spanned<Kind>;

// =========================================================================
// TypeNode — 类型语法节点
// =========================================================================

/// 类型语法节点：命名类型、泛型、可空、函数、记录、数组、kind 标注等
#[derive(Debug, Clone, PartialEq)]
pub enum TypeNode<'a> {
    /// 命名类型，如 `i32`、`String`
    Named { name: &'a str },
    /// `Self` 类型
    SelfType,
    /// 泛型应用，如 `List<i32>`
    Generic { name: &'a str, args: Vec<TypeRef<'a>> },
    /// 可空类型 `T?`
    Nullable { inner: TypeRef<'a> },
    /// 借用引用 `&T`：指向已有对象的引用，共享读写，RC 管理
    RefType { inner: TypeRef<'a> },
    /// 裸指针 `*T`：绕过 RC，不安全，预留用于 FFI
    RawPtr { inner: TypeRef<'a> },
    /// 函数类型 `(P1, P2) -> R`
    Function {
        params: Vec<TypeRef<'a>>,
        return_type: TypeRef<'a>,
    },
    /// 记录类型 `{ x: i32, y: i32 }`
    Record { fields: Vec<RecordFieldType<'a>> },
    /// 数组类型 `[T; N]`，size 为 None 时为切片
    Array {
        element_type: TypeRef<'a>,
        size: Option<u64>,
    },
    /// kind 标注类型 `T :: *`
    KindAnnotated { inner: TypeRef<'a>, kind: Box<Kind> },
}

// =========================================================================
// Pattern — 模式匹配
// =========================================================================

/// 模式匹配中的模式：通配符、字面量、变量、构造器、记录、或模式、守卫模式
#[derive(Debug, Clone, PartialEq)]
pub enum Pattern<'a> {
    /// 通配符 `_`
    Wildcard,
    /// 字面量模式
    Literal(PatternLiteral<'a>),
    /// 变量绑定模式 `x`
    Variable { name: &'a str },
    /// 构造器模式 `Some(x)`
    Constructor {
        name: &'a str,
        patterns: Vec<PatternRef<'a>>,
    },
    /// 记录模式 `{ x, y: p }`
    Record { fields: Vec<PatternRecordField<'a>> },
    /// 或模式 `p1 | p2`
    OrPattern {
        left: PatternRef<'a>,
        right: PatternRef<'a>,
    },
    /// 守卫模式 `p if cond`
    Guard {
        pattern: PatternRef<'a>,
        condition: ExprRef<'a>,
    },
}

// =========================================================================
// Expr — 表达式节点
// =========================================================================

/// 表达式节点：涵盖字面量、标识符、各种运算、调用、控制流、模式匹配等全部表达式形式
#[derive(Debug, Clone, PartialEq)]
pub enum Expr<'a> {
    /// 整数字面量，raw 保留源码文本，suffix 为可选类型后缀（如 `42i32`）
    IntLit { raw: &'a str, suffix: Option<&'a str> },
    /// 浮点字面量
    FloatLit { raw: &'a str, suffix: Option<&'a str> },
    /// 布尔字面量
    BoolLit(bool),
    /// 字符字面量（Unicode scalar value）
    CharLit(u32),
    /// 字符串字面量
    StrLit(&'a str),
    /// 字符串插值 `"foo ${expr} bar"`
    StrInterp(Vec<InterpolationPart<'a>>),
    /// `null` 字面量
    NullLit,
    /// `()` 单元字面量
    UnitLit,
    /// 标识符引用
    Ident(&'a str),
    /// 赋值表达式 `target = value`
    Assign { target: ExprRef<'a>, value: ExprRef<'a> },
    /// 复合赋值 `target op= value`
    CompoundAssign {
        op: CompoundAssignOp,
        target: ExprRef<'a>,
        value: ExprRef<'a>,
    },
    /// 二元运算 `lhs op rhs`
    Binary {
        op: BinaryOp,
        lhs: ExprRef<'a>,
        rhs: ExprRef<'a>,
    },
    /// 一元运算 `op operand`
    Unary { op: UnaryOp, operand: ExprRef<'a> },
    /// 取引用 `&expr`
    RefOf(ExprRef<'a>),
    /// 解引用 `*expr`
    Deref(ExprRef<'a>),
    /// 函数调用 `callee(args)`，type_args 为显式泛型实参
    Call {
        callee: ExprRef<'a>,
        args: Vec<ExprRef<'a>>,
        type_args: Option<Vec<TypeRef<'a>>>,
    },
    /// 方法调用 `recv.method(args)`
    MethodCall {
        recv: ExprRef<'a>,
        method: &'a str,
        args: Vec<ExprRef<'a>>,
        type_args: Option<Vec<TypeRef<'a>>>,
    },
    /// 字段访问 `recv.field`
    FieldAccess { recv: ExprRef<'a>, field: &'a str },
    /// 索引 `recv[index]`
    Index { recv: ExprRef<'a>, index: ExprRef<'a> },
    /// 切片 `recv[start..end]` 或 `recv[start..=end]`
    Slice {
        recv: ExprRef<'a>,
        start: ExprRef<'a>,
        end: ExprRef<'a>,
        inclusive: bool,
    },
    /// 安全字段访问 `recv?.field`
    SafeAccess { recv: ExprRef<'a>, field: &'a str },
    /// 安全方法调用 `recv?.method(args)`
    SafeMethodCall {
        recv: ExprRef<'a>,
        method: &'a str,
        args: Vec<ExprRef<'a>>,
        type_args: Option<Vec<TypeRef<'a>>>,
    },
    /// 错误传播 `expr!`
    Propagate(ExprRef<'a>),
    /// 非空断言 `expr!!`
    NonNullAssert(ExprRef<'a>),
    /// Elvis 运算 `lhs ?: rhs`
    Elvis { lhs: ExprRef<'a>, rhs: ExprRef<'a> },
    /// 数组字面量 `[a, b, c]` 或填充语法 `[value, ..count]`
    ArrayLit {
        elements: Vec<ExprRef<'a>>,
        fill: Option<(ExprRef<'a>, ExprRef<'a>)>,
    },
    /// 记录字面量 `{ x: 1, y: 2 }`
    RecordLit(Vec<RecordFieldExpr<'a>>),
    /// 记录扩展 `{ base with x: 1 }`
    RecordExtend {
        base: ExprRef<'a>,
        updates: Vec<RecordFieldExpr<'a>>,
    },
    /// lambda 表达式 `|params| body`
    Lambda {
        params: Vec<Param<'a>>,
        body: LambdaBody<'a>,
        is_async: bool,
        return_type: Option<TypeRef<'a>>,
    },
    /// if 表达式 `if cond { then } else { else_ }`
    If {
        cond: ExprRef<'a>,
        then_branch: ExprRef<'a>,
        else_branch: Option<ExprRef<'a>>,
    },
    /// 块表达式 `{ stmts; trailing }`
    Block {
        stmts: Vec<StmtRef<'a>>,
        trailing: Option<ExprRef<'a>>,
    },
    /// match 表达式 `match scrutinee { arms }`
    Match {
        scrutinee: ExprRef<'a>,
        arms: Vec<MatchArm<'a>>,
    },
    /// 类型转换 `target(expr)`，safe=true 时为安全转换 `target(expr)?`
    TypeCast {
        target: TypeRef<'a>,
        expr: ExprRef<'a>,
        safe: bool,
    },
    /// cast builder 表达式 `cast(expr).to(T)` / `cast(expr).try_to(T)`
    CastBuilder {
        expr: ExprRef<'a>,
        target: TypeRef<'a>,
        mode: CastMode,
    },
    /// 原子表达式 `atomic(expr)`
    Atomic(ExprRef<'a>),
    /// 惰性求值 `lazy(expr)`
    Lazy(ExprRef<'a>),
    /// select 表达式 `select { arms }`
    Select(Vec<SelectArm<'a>>),
    /// inline trait 值 `inline_trait { methods }`
    InlineTrait(Vec<MethodDecl<'a>>),
}

impl<'a> Expr<'a> {
    /// 判断是否为字面量表达式
    pub fn is_literal(&self) -> bool {
        matches!(
            self,
            Expr::IntLit { .. }
                | Expr::FloatLit { .. }
                | Expr::BoolLit(_)
                | Expr::CharLit(_)
                | Expr::StrLit(_)
                | Expr::NullLit
                | Expr::UnitLit
        )
    }

    /// 判断是否为左值（可赋值目标）
    pub fn is_lvalue(&self) -> bool {
        matches!(
            self,
            Expr::Ident(_) | Expr::FieldAccess { .. } | Expr::Index { .. } | Expr::Deref(_)
        )
    }

    /// 若为标识符表达式，返回其名称
    pub fn as_ident(&self) -> Option<&'a str> {
        match self {
            Expr::Ident(name) => Some(*name),
            _ => None,
        }
    }
}

// =========================================================================
// Stmt — 语句节点
// =========================================================================

/// 语句节点：声明、赋值、控制流（return/throw/break/continue）、循环等
#[derive(Debug, Clone, PartialEq)]
pub enum Stmt<'a> {
    /// 不可变绑定 `val name = value`
    ValDecl {
        name: &'a str,
        type_annotation: Option<TypeRef<'a>>,
        value: ExprRef<'a>,
        visibility: Visibility,
    },
    /// 可变绑定 `var name = value`
    VarDecl {
        name: &'a str,
        type_annotation: Option<TypeRef<'a>>,
        value: ExprRef<'a>,
        visibility: Visibility,
    },
    /// 赋值语句 `target = value`
    Assignment {
        target: ExprRef<'a>,
        value: ExprRef<'a>,
    },
    /// 字段赋值 `object.field = value`
    FieldAssignment {
        object: ExprRef<'a>,
        field: &'a str,
        value: ExprRef<'a>,
    },
    /// 复合赋值 `target op= value`
    CompoundAssignment {
        target: ExprRef<'a>,
        op: CompoundAssignOp,
        value: ExprRef<'a>,
    },
    /// 纯表达式语句 `expr`
    Expression { expr: ExprRef<'a> },
    /// return 语句 `return value?`
    Return { value: Option<ExprRef<'a>> },
    /// defer 语句 `defer expr`
    Defer { expr: ExprRef<'a> },
    /// throw 语句 `throw expr`
    Throw { expr: ExprRef<'a> },
    /// break 语句
    Break,
    /// continue 语句
    Continue,
    /// for 循环 `for name in iterable { body }`
    For {
        name: &'a str,
        iterable: ExprRef<'a>,
        body: ExprRef<'a>,
    },
    /// while 循环 `while condition { body }`
    While {
        condition: ExprRef<'a>,
        body: ExprRef<'a>,
    },
    /// loop 循环 `loop { body }`
    Loop { body: ExprRef<'a> },
}

// =========================================================================
// Decl — 顶层声明
// =========================================================================

/// 顶层声明：函数、类型、trait、import、pack、表达式声明
#[derive(Debug, Clone, PartialEq)]
pub enum Decl<'a> {
    /// 函数声明 `fun name(params): ret { body }`
    FunDecl {
        visibility: Visibility,
        name: &'a str,
        type_params: Vec<TypeParam<'a>>,
        params: Vec<Param<'a>>,
        return_type: Option<TypeRef<'a>>,
        bounds: Vec<TraitBound<'a>>,
        body: ExprRef<'a>,
        is_async: bool,
        is_entry: bool,
    },
    /// 类型声明 `type name { ... }`
    TypeDecl {
        visibility: Visibility,
        name: &'a str,
        type_params: Vec<TypeParam<'a>>,
        implemented_traits: Vec<TraitBound<'a>>,
        type_constraints: Vec<TypeConstraint<'a>>,
        def: TypeDef<'a>,
        methods: Vec<MethodDecl<'a>>,
    },
    /// trait 声明 `trait name { ... }`
    TraitDecl {
        visibility: Visibility,
        name: &'a str,
        type_params: Vec<TypeParam<'a>>,
        parents: Vec<TraitBound<'a>>,
        associated_types: Vec<AssociatedType<'a>>,
        methods: Vec<MethodDecl<'a>>,
    },
    /// import 声明 `import module_path { items }`
    ImportDecl {
        module_path: Vec<&'a str>,
        items: Option<Vec<ImportItem<'a>>>,
        visibility: Visibility,
    },
    /// pack 声明 `pack name`
    PackDecl {
        visibility: Visibility,
        name: &'a str,
    },
    /// 顶层表达式声明
    ExprDecl {
        expr: ExprRef<'a>,
        stmt: Option<StmtRef<'a>>,
    },
}

// =========================================================================
// TypeDef — 类型定义体
// =========================================================================

/// 类型定义体：代数数据类型、记录、别名、新类型、错误新类型
#[derive(Debug, Clone, PartialEq)]
pub enum TypeDef<'a> {
    /// 代数数据类型 `adt { Constructor1 | Constructor2 }`
    Adt { constructors: Vec<ConstructorDef<'a>> },
    /// 记录类型 `record { field1: T1, field2: T2 }`
    Record { fields: Vec<RecordFieldType<'a>> },
    /// 类型别名 `alias = target`
    Alias { target: TypeRef<'a> },
    /// 新类型 `newtype name = inner`
    Newtype { name: &'a str, inner: TypeRef<'a> },
    /// 错误新类型 `error_newtype name(params)`
    ErrorNewtype { name: &'a str, params: Vec<Param<'a>> },
}

// =========================================================================
// Module — 模块
// =========================================================================

/// 模块：名称、源码路径与顶层声明列表
#[derive(Debug, Clone, PartialEq)]
pub struct Module<'a> {
    pub name: &'a str,
    pub source_path: Option<&'a str>,
    pub declarations: Vec<Spanned<Decl<'a>>>,
}

impl<'a> Module<'a> {
    /// 按名称查找模块中的函数声明
    pub fn find_function(&self, name: &str) -> Option<&Spanned<Decl<'a>>> {
        self.declarations.iter().find(|d| match &d.node {
            Decl::FunDecl { name: n, .. } => *n == name,
            _ => false,
        })
    }
}
