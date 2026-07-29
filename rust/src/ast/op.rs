//! 运算符枚举、Kind 类型系统与 AST 辅助类型

use crate::ast::node::{ExprRef, PatternRef, TypeRef};

// =========================================================================
// 运算符枚举
// =========================================================================

/// 二元运算符种类
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BinaryOp {
    Add,
    Sub,
    Mul,
    Div,
    Mod,
    Eq,
    NotEq,
    RefEq,
    RefNeq,
    Lt,
    Gt,
    LtEq,
    GtEq,
    And,
    Or,
    BitAnd,
    BitOr,
    BitXor,
    Shl,
    Shr,
    ConcatList,
    Range,
    RangeInclusive,
    Elvis,
}

/// 复合赋值运算符种类（如 +=、-=）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CompoundAssignOp {
    AddAssign,
    SubAssign,
    MulAssign,
    DivAssign,
    ModAssign,
    BitAndAssign,
    BitOrAssign,
    BitXorAssign,
    ShlAssign,
    ShrAssign,
}

/// 一元运算符种类
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum UnaryOp {
    Not,
    Neg,
    BitNot,
}

/// cast builder 转换模式
/// - `To`: wrap on overflow（产生 Inf 时 panic），结果类型 = T
/// - `TryTo`: 越界/解析失败/产生 Inf 时返回 `Throw<T, CastError>`
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CastMode {
    To,
    TryTo,
}

/// 可见性修饰：区分私有与公开声明
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Visibility {
    Private,
    Public,
}

// =========================================================================
// Kind 类型系统
// =========================================================================

/// 类型种类（kind）：用于高阶类型标注，支持星类型与箭头类型
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Kind {
    Star,
    Arrow { param: Box<Kind>, result: Box<Kind> },
}

// =========================================================================
// 辅助结构体
// =========================================================================

/// 模式匹配中的字面量模式
#[derive(Debug, Clone, PartialEq)]
pub enum PatternLiteral<'a> {
    Int(&'a str),
    Float(&'a str),
    Bool(bool),
    Char(u32),
    String(&'a str),
    Null,
}

/// 记录模式中的字段：字段名与对应子模式
#[derive(Debug, Clone, PartialEq)]
pub struct PatternRecordField<'a> {
    pub name: &'a str,
    pub pattern: PatternRef<'a>,
}

/// 函数/lambda 参数
#[derive(Debug, Clone, PartialEq)]
pub struct Param<'a> {
    pub name: &'a str,
    pub type_annotation: Option<TypeRef<'a>>,
}

/// 类型参数：携带名称、kind 约束与 trait 约束
#[derive(Debug, Clone, PartialEq)]
pub struct TypeParam<'a> {
    pub name: &'a str,
    pub kind: Option<Box<Kind>>,
    pub bounds: Vec<TraitBound<'a>>,
}

/// trait 约束：trait 名与类型实参
#[derive(Debug, Clone, PartialEq)]
pub struct TraitBound<'a> {
    pub trait_name: &'a str,
    pub type_args: Vec<TypeRef<'a>>,
}

/// 类型约束：将类型参数绑定到具体类型
#[derive(Debug, Clone, PartialEq)]
pub struct TypeConstraint<'a> {
    pub type_param: &'a str,
    pub concrete_type: TypeRef<'a>,
}

/// 记录类型字段：字段名与字段类型
#[derive(Debug, Clone, PartialEq)]
pub struct RecordFieldType<'a> {
    pub name: &'a str,
    pub ty: TypeRef<'a>,
}

/// 记录字面量字段：字段名与字段值表达式
#[derive(Debug, Clone, PartialEq)]
pub struct RecordFieldExpr<'a> {
    pub name: &'a str,
    pub value: ExprRef<'a>,
}

/// 构造器字段：可选字段名与类型（无名时为位置参数）
#[derive(Debug, Clone, PartialEq)]
pub struct ConstructorField<'a> {
    pub name: Option<&'a str>,
    pub ty: TypeRef<'a>,
}

/// 字符串插值的组成部分：字面量文本或内嵌表达式
#[derive(Debug, Clone, PartialEq)]
pub enum InterpolationPart<'a> {
    Literal(&'a str),
    Expression(ExprRef<'a>),
}

/// lambda 体：既可以是块表达式，也可以是普通表达式
#[derive(Debug, Clone, PartialEq)]
pub enum LambdaBody<'a> {
    Block(ExprRef<'a>),
    Expression(ExprRef<'a>),
}

/// match 表达式的一个分支：模式、可选守卫与分支体
#[derive(Debug, Clone, PartialEq)]
pub struct MatchArm<'a> {
    pub pattern: PatternRef<'a>,
    pub guard: Option<ExprRef<'a>>,
    pub body: ExprRef<'a>,
}

/// select 表达式的一个分支：接收通道消息或超时
#[derive(Debug, Clone, PartialEq)]
pub enum SelectArm<'a> {
    Receive {
        channel_expr: ExprRef<'a>,
        binding: Option<&'a str>,
        body: ExprRef<'a>,
    },
    Timeout {
        duration: ExprRef<'a>,
        body: ExprRef<'a>,
    },
}

/// import 语句中的单个导入项：名称与可选别名
#[derive(Debug, Clone, PartialEq)]
pub struct ImportItem<'a> {
    pub name: &'a str,
    pub alias: Option<&'a str>,
}

/// 构造器定义：名称、字段列表与可选返回类型
#[derive(Debug, Clone, PartialEq)]
pub struct ConstructorDef<'a> {
    pub name: &'a str,
    pub fields: Vec<ConstructorField<'a>>,
    pub return_type: Option<TypeRef<'a>>,
}

/// 方法声明：名称、类型参数、参数、返回类型、可选方法体、是否覆盖、委托信息
#[derive(Debug, Clone, PartialEq)]
pub struct MethodDecl<'a> {
    pub name: &'a str,
    pub type_params: Vec<TypeParam<'a>>,
    pub params: Vec<Param<'a>>,
    pub return_type: Option<TypeRef<'a>>,
    pub body: Option<ExprRef<'a>>,
    pub is_override: bool,
    pub delegate: Option<DelegateInfo<'a>>,
    pub visibility: Visibility,
    pub is_async: bool,
}

/// 委托信息：将方法委托给某个 trait 的某个方法
#[derive(Debug, Clone, PartialEq)]
pub struct DelegateInfo<'a> {
    pub trait_name: &'a str,
    pub method_name: &'a str,
}

/// trait 中的关联类型声明
#[derive(Debug, Clone, PartialEq)]
pub struct AssociatedType<'a> {
    pub name: &'a str,
    pub kind: Option<Box<Kind>>,
}
