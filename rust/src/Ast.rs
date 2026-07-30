//! Ast.rs — Glue 语法树（合并 8 个子模块）

// AST 源码位置与节点包装

/// 源码位置：行号与列号，用于错误定位
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Span {
    pub line: u32,
    pub column: u32,
}

impl Span {
    pub fn new(line: u32, column: u32) -> Self {
        Self { line, column }
    }
}

/// AST 节点包装：将源码位置与节点本体绑定
#[derive(Debug, Clone, PartialEq)]
pub struct Spanned<T> {
    pub span: Span,
    pub node: T,
}

impl<T> Spanned<T> {
    pub fn new(span: Span, node: T) -> Self {
        Self { span, node }
    }

    pub fn map<U, F: FnOnce(T) -> U>(self, f: F) -> Spanned<U> {
        Spanned {
            span: self.span,
            node: f(self.node),
        }
    }

    pub fn as_ref(&self) -> Spanned<&T> {
        Spanned {
            span: self.span,
            node: &self.node,
        }
    }
}

// =========================================================================
// NodeId — 节点索引（u32，替代 &'a Spanned<T> 引用）
// =========================================================================

/// 表达式节点索引
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ExprId(pub u32);
/// 语句节点索引
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct StmtId(pub u32);
/// 类型节点索引
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TypeId(pub u32);
/// 模式节点索引
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct PatternId(pub u32);

// =========================================================================
// AstArena — 统一节点存储（替代 bumpalo arena + 引用）
//
// 4 种节点类型各一个 Vec<Spanned<T>>。节点通过 NodeId(u32) 索引引用，
// 消除节点间的生命周期参数。字符串字段仍为 &'a str（零拷贝）。
// =========================================================================

/// AST 节点统一存储
#[derive(Debug, Clone, PartialEq)]
pub struct AstArena<'a> {
    pub exprs: Vec<Spanned<Expr<'a>>>,
    pub stmts: Vec<Spanned<Stmt<'a>>>,
    pub types: Vec<Spanned<TypeNode<'a>>>,
    pub patterns: Vec<Spanned<Pattern<'a>>>,
}

impl<'a> AstArena<'a> {
    pub fn new() -> Self {
        Self {
            exprs: Vec::new(),
            stmts: Vec::new(),
            types: Vec::new(),
            patterns: Vec::new(),
        }
    }

    pub fn alloc_expr(&mut self, span: Span, node: Expr<'a>) -> ExprId {
        let id = ExprId(self.exprs.len() as u32);
        self.exprs.push(Spanned { span, node });
        id
    }

    pub fn alloc_stmt(&mut self, span: Span, node: Stmt<'a>) -> StmtId {
        let id = StmtId(self.stmts.len() as u32);
        self.stmts.push(Spanned { span, node });
        id
    }

    pub fn alloc_type(&mut self, span: Span, node: TypeNode<'a>) -> TypeId {
        let id = TypeId(self.types.len() as u32);
        self.types.push(Spanned { span, node });
        id
    }

    pub fn alloc_pattern(&mut self, span: Span, node: Pattern<'a>) -> PatternId {
        let id = PatternId(self.patterns.len() as u32);
        self.patterns.push(Spanned { span, node });
        id
    }

    /// 索引访问（带边界检查）
    pub fn expr(&self, id: ExprId) -> &Spanned<Expr<'a>> {
        &self.exprs[id.0 as usize]
    }

    pub fn stmt(&self, id: StmtId) -> &Spanned<Stmt<'a>> {
        &self.stmts[id.0 as usize]
    }

    pub fn ty(&self, id: TypeId) -> &Spanned<TypeNode<'a>> {
        &self.types[id.0 as usize]
    }

    pub fn pattern(&self, id: PatternId) -> &Spanned<Pattern<'a>> {
        &self.patterns[id.0 as usize]
    }
}

impl<'a> Default for AstArena<'a> {
    fn default() -> Self {
        Self::new()
    }
}

// 运算符枚举、Kind 类型系统与 AST 辅助类型


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
    pub pattern: PatternRef,
}

/// 函数/lambda 参数
#[derive(Debug, Clone, PartialEq)]
pub struct Param<'a> {
    pub name: &'a str,
    pub type_annotation: Option<TypeRef>,
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
    pub type_args: Vec<TypeRef>,
}

/// 类型约束：将类型参数绑定到具体类型
#[derive(Debug, Clone, PartialEq)]
pub struct TypeConstraint<'a> {
    pub type_param: &'a str,
    pub concrete_type: TypeRef,
}

/// 记录类型字段：字段名与字段类型
#[derive(Debug, Clone, PartialEq)]
pub struct RecordFieldType<'a> {
    pub name: &'a str,
    pub ty: TypeRef,
}

/// 记录字面量字段：字段名与字段值表达式
#[derive(Debug, Clone, PartialEq)]
pub struct RecordFieldExpr<'a> {
    pub name: &'a str,
    pub value: ExprRef,
}

/// 构造器字段：可选字段名与类型（无名时为位置参数）
#[derive(Debug, Clone, PartialEq)]
pub struct ConstructorField<'a> {
    pub name: Option<&'a str>,
    pub ty: TypeRef,
}

/// 字符串插值的组成部分：字面量文本或内嵌表达式
#[derive(Debug, Clone, PartialEq)]
pub enum InterpolationPart<'a> {
    Literal(&'a str),
    Expression(ExprRef),
}

/// lambda 体：既可以是块表达式，也可以是普通表达式
#[derive(Debug, Clone, PartialEq)]
pub enum LambdaBody {
    Block(ExprRef),
    Expression(ExprRef),
}

/// match 表达式的一个分支：模式、可选守卫与分支体
#[derive(Debug, Clone, PartialEq)]
pub struct MatchArm {
    pub pattern: PatternRef,
    pub guard: Option<ExprRef>,
    pub body: ExprRef,
}

/// select 表达式的一个分支：接收通道消息或超时
#[derive(Debug, Clone, PartialEq)]
pub enum SelectArm<'a> {
    Receive {
        channel_expr: ExprRef,
        binding: Option<&'a str>,
        body: ExprRef,
    },
    Timeout {
        duration: ExprRef,
        body: ExprRef,
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
    pub return_type: Option<TypeRef>,
}

/// 方法声明：名称、类型参数、参数、返回类型、可选方法体、是否覆盖、委托信息
#[derive(Debug, Clone, PartialEq)]
pub struct MethodDecl<'a> {
    pub name: &'a str,
    pub type_params: Vec<TypeParam<'a>>,
    pub params: Vec<Param<'a>>,
    pub return_type: Option<TypeRef>,
    pub body: Option<ExprRef>,
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

// AST 节点定义：表达式、语句、声明、类型节点、模式、类型定义与模块


// =========================================================================
// 引用类型别名
//
// 子节点通过 AstArena 分配后以 NodeId(u32) 索引形式持有，零拷贝引用源码。
// 别名保留以减少调用点改动（字段类型语义从引用变为索引）。
// =========================================================================

pub type ExprRef = ExprId;
pub type StmtRef = StmtId;
pub type TypeRef = TypeId;
pub type PatternRef = PatternId;

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
    Generic { name: &'a str, args: Vec<TypeRef> },
    /// 可空类型 `T?`
    Nullable { inner: TypeRef },
    /// 借用引用 `&T`：指向已有对象的引用，共享读写，RC 管理
    RefType { inner: TypeRef },
    /// 裸指针 `*T`：绕过 RC，不安全，预留用于 FFI
    RawPtr { inner: TypeRef },
    /// 函数类型 `(P1, P2) -> R`
    Function {
        params: Vec<TypeRef>,
        return_type: TypeRef,
    },
    /// 记录类型 `{ x: i32, y: i32 }`
    Record { fields: Vec<RecordFieldType<'a>> },
    /// 数组类型 `[T; N]`，size 为 None 时为切片
    Array {
        element_type: TypeRef,
        size: Option<u64>,
    },
    /// kind 标注类型 `T :: *`
    KindAnnotated { inner: TypeRef, kind: Box<Kind> },
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
        patterns: Vec<PatternRef>,
    },
    /// 记录模式 `{ x, y: p }`
    Record { fields: Vec<PatternRecordField<'a>> },
    /// 或模式 `p1 | p2`
    OrPattern {
        left: PatternRef,
        right: PatternRef,
    },
    /// 守卫模式 `p if cond`
    Guard {
        pattern: PatternRef,
        condition: ExprRef,
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
    /// `()` void 字面量
    VoidLit,
    /// 标识符引用
    Ident(&'a str),
    /// 赋值表达式 `target = value`
    Assign { target: ExprRef, value: ExprRef },
    /// 复合赋值 `target op= value`
    CompoundAssign {
        op: CompoundAssignOp,
        target: ExprRef,
        value: ExprRef,
    },
    /// 二元运算 `lhs op rhs`
    Binary {
        op: BinaryOp,
        lhs: ExprRef,
        rhs: ExprRef,
    },
    /// 一元运算 `op operand`
    Unary { op: UnaryOp, operand: ExprRef },
    /// 取引用 `&expr`
    RefOf(ExprRef),
    /// 解引用 `*expr`
    Deref(ExprRef),
    /// 函数调用 `callee(args)`，type_args 为显式泛型实参
    Call {
        callee: ExprRef,
        args: Vec<ExprRef>,
        type_args: Option<Vec<TypeRef>>,
    },
    /// 方法调用 `recv.method(args)`
    MethodCall {
        recv: ExprRef,
        method: &'a str,
        args: Vec<ExprRef>,
        type_args: Option<Vec<TypeRef>>,
    },
    /// 字段访问 `recv.field`
    FieldAccess { recv: ExprRef, field: &'a str },
    /// 索引 `recv[index]`
    Index { recv: ExprRef, index: ExprRef },
    /// 切片 `recv[start..end]` 或 `recv[start..=end]`
    Slice {
        recv: ExprRef,
        start: ExprRef,
        end: ExprRef,
        inclusive: bool,
    },
    /// 安全字段访问 `recv?.field`
    SafeAccess { recv: ExprRef, field: &'a str },
    /// 安全方法调用 `recv?.method(args)`
    SafeMethodCall {
        recv: ExprRef,
        method: &'a str,
        args: Vec<ExprRef>,
        type_args: Option<Vec<TypeRef>>,
    },
    /// 错误传播 `expr!`
    Propagate(ExprRef),
    /// 非空断言 `expr!!`
    NonNullAssert(ExprRef),
    /// Elvis 运算 `lhs ?: rhs`
    Elvis { lhs: ExprRef, rhs: ExprRef },
    /// 数组字面量 `[a, b, c]` 或填充语法 `[value, ..count]`
    ArrayLit {
        elements: Vec<ExprRef>,
        fill: Option<(ExprRef, ExprRef)>,
    },
    /// 记录字面量 `{ x: 1, y: 2 }`
    RecordLit(Vec<RecordFieldExpr<'a>>),
    /// 记录扩展 `{ base with x: 1 }`
    RecordExtend {
        base: ExprRef,
        updates: Vec<RecordFieldExpr<'a>>,
    },
    /// lambda 表达式 `|params| body`
    Lambda {
        params: Vec<Param<'a>>,
        body: LambdaBody,
        is_async: bool,
        return_type: Option<TypeRef>,
    },
    /// if 表达式 `if cond { then } else { else_ }`
    If {
        cond: ExprRef,
        then_branch: ExprRef,
        else_branch: Option<ExprRef>,
    },
    /// 块表达式 `{ stmts; trailing }`
    Block {
        stmts: Vec<StmtRef>,
        trailing: Option<ExprRef>,
    },
    /// match 表达式 `match scrutinee { arms }`
    Match {
        scrutinee: ExprRef,
        arms: Vec<MatchArm>,
    },
    /// 类型转换 `target(expr)`，safe=true 时为安全转换 `target(expr)?`
    TypeCast {
        target: TypeRef,
        expr: ExprRef,
        safe: bool,
    },
    /// cast builder 表达式 `cast(expr).to(T)` / `cast(expr).try_to(T)`
    CastBuilder {
        expr: ExprRef,
        target: TypeRef,
        mode: CastMode,
    },
    /// 原子表达式 `atomic(expr)`
    Atomic(ExprRef),
    /// 惰性求值 `lazy(expr)`
    Lazy(ExprRef),
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
                | Expr::VoidLit
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
        type_annotation: Option<TypeRef>,
        value: ExprRef,
        visibility: Visibility,
    },
    /// 可变绑定 `var name = value`
    VarDecl {
        name: &'a str,
        type_annotation: Option<TypeRef>,
        value: ExprRef,
        visibility: Visibility,
    },
    /// 赋值语句 `target = value`
    Assignment {
        target: ExprRef,
        value: ExprRef,
    },
    /// 字段赋值 `object.field = value`
    FieldAssignment {
        object: ExprRef,
        field: &'a str,
        value: ExprRef,
    },
    /// 复合赋值 `target op= value`
    CompoundAssignment {
        target: ExprRef,
        op: CompoundAssignOp,
        value: ExprRef,
    },
    /// 纯表达式语句 `expr`
    Expression { expr: ExprRef },
    /// return 语句 `return value?`
    Return { value: Option<ExprRef> },
    /// defer 语句 `defer expr`
    Defer { expr: ExprRef },
    /// throw 语句 `throw expr`
    Throw { expr: ExprRef },
    /// break 语句
    Break,
    /// continue 语句
    Continue,
    /// for 循环 `for name in iterable { body }`
    For {
        name: &'a str,
        iterable: ExprRef,
        body: ExprRef,
    },
    /// while 循环 `while condition { body }`
    While {
        condition: ExprRef,
        body: ExprRef,
    },
    /// loop 循环 `loop { body }`
    Loop { body: ExprRef },
}

// =========================================================================
// Attribute — 通用属性
// =========================================================================

/// 通用属性：@name 或 @name("arg1", "arg2") 或 @name "arg"
#[derive(Debug, Clone, PartialEq)]
pub struct Attribute<'a> {
    pub name: &'a str,
    pub args: Vec<&'a str>,
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
        return_type: Option<TypeRef>,
        bounds: Vec<TraitBound<'a>>,
        body: ExprRef,
        is_async: bool,
        is_entry: bool,
        attributes: Vec<Attribute<'a>>,
        extern_c_body: Option<&'a str>,
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
        expr: ExprRef,
        stmt: Option<StmtRef>,
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
    Alias { target: TypeRef },
    /// 新类型 `newtype name = inner`
    Newtype { name: &'a str, inner: TypeRef },
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
    pub arena: AstArena<'a>,
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

// =========================================================================
// AstVisitor — AST 遍历 trait（hook 默认空，由 walk_* 驱动递归）
// =========================================================================

/// AST 遍历器 trait。`visit_*` 方法为 hook，默认空实现。
/// 想要递归遍历的调用方使用对应的 `walk_*` 自由函数（接收 `&AstArena` 解引用节点）。
/// 重写 `visit_*` 即可拦截该节点类型；自驱动 visitor（如 Printer）在 hook 内自行递归。
///
/// 非对象安全（泛型方法 `walk_*` 需要 `Sized`），仅静态分派，零虚函数开销。
pub trait AstVisitor<'a>: Sized {
    fn visit_module(&mut self, _module: &'a Module<'a>) {}
    fn visit_decl(&mut self, _decl: &'a Spanned<Decl<'a>>) {}
    fn visit_type_def(&mut self, _def: &'a TypeDef<'a>) {}
    fn visit_stmt(&mut self, _stmt: StmtId) {}
    fn visit_expr(&mut self, _expr: ExprId) {}
    fn visit_type(&mut self, _ty: TypeId) {}
    fn visit_pattern(&mut self, _pat: PatternId) {}
    fn visit_kind(&mut self, _kind: &'a Kind) {}
}

// --- walk_* 自由函数：先调 hook 再递归子节点 ---

pub fn walk_module<'a, V: AstVisitor<'a>>(v: &mut V, arena: &'a AstArena<'a>, m: &'a Module<'a>) {
    v.visit_module(m);
    for decl in &m.declarations {
        walk_decl(v, arena, decl);
    }
}

pub fn walk_decl<'a, V: AstVisitor<'a>>(v: &mut V, arena: &'a AstArena<'a>, decl: &'a Spanned<Decl<'a>>) {
    v.visit_decl(decl);
    match &decl.node {
        Decl::FunDecl {
            type_params,
            params,
            return_type,
            bounds,
            body,
            ..
        } => {
            for tp in type_params {
                walk_type_param(v, arena, tp);
            }
            for p in params {
                walk_param(v, arena, p);
            }
            if let Some(rt) = return_type {
                walk_type(v, arena, *rt);
            }
            for b in bounds {
                walk_trait_bound(v, arena, b);
            }
            walk_expr(v, arena, *body);
        }
        Decl::TypeDecl {
            type_params,
            implemented_traits,
            type_constraints,
            def,
            methods,
            ..
        } => {
            for tp in type_params {
                walk_type_param(v, arena, tp);
            }
            for b in implemented_traits {
                walk_trait_bound(v, arena, b);
            }
            for c in type_constraints {
                walk_type_constraint(v, arena, c);
            }
            walk_type_def(v, arena, def);
            for m in methods {
                walk_method_decl(v, arena, m);
            }
        }
        Decl::TraitDecl {
            type_params,
            parents,
            associated_types,
            methods,
            ..
        } => {
            for tp in type_params {
                walk_type_param(v, arena, tp);
            }
            for p in parents {
                walk_trait_bound(v, arena, p);
            }
            for at in associated_types {
                walk_associated_type(v, at);
            }
            for m in methods {
                walk_method_decl(v, arena, m);
            }
        }
        Decl::ImportDecl { .. } | Decl::PackDecl { .. } => {}
        Decl::ExprDecl { expr, stmt } => {
            walk_expr(v, arena, *expr);
            if let Some(s) = stmt {
                walk_stmt(v, arena, *s);
            }
        }
    }
}

pub fn walk_type_def<'a, V: AstVisitor<'a>>(v: &mut V, arena: &'a AstArena<'a>, def: &'a TypeDef<'a>) {
    v.visit_type_def(def);
    match def {
        TypeDef::Adt { constructors } => {
            for ctor in constructors {
                walk_constructor_def(v, arena, ctor);
            }
        }
        TypeDef::Record { fields } => {
            for f in fields {
                walk_record_field_type(v, arena, f);
            }
        }
        TypeDef::Alias { target } => {
            walk_type(v, arena, *target);
        }
        TypeDef::Newtype { inner, .. } => {
            walk_type(v, arena, *inner);
        }
        TypeDef::ErrorNewtype { params, .. } => {
            for p in params {
                walk_param(v, arena, p);
            }
        }
    }
}

pub fn walk_stmt<'a, V: AstVisitor<'a>>(v: &mut V, arena: &'a AstArena<'a>, id: StmtId) {
    v.visit_stmt(id);
    let stmt = arena.stmt(id);
    match &stmt.node {
        Stmt::ValDecl {
            type_annotation,
            value,
            ..
        } => {
            if let Some(ty) = type_annotation {
                walk_type(v, arena, *ty);
            }
            walk_expr(v, arena, *value);
        }
        Stmt::VarDecl {
            type_annotation,
            value,
            ..
        } => {
            if let Some(ty) = type_annotation {
                walk_type(v, arena, *ty);
            }
            walk_expr(v, arena, *value);
        }
        Stmt::Assignment { target, value } => {
            walk_expr(v, arena, *target);
            walk_expr(v, arena, *value);
        }
        Stmt::FieldAssignment {
            object, value, ..
        } => {
            walk_expr(v, arena, *object);
            walk_expr(v, arena, *value);
        }
        Stmt::CompoundAssignment {
            target, value, ..
        } => {
            walk_expr(v, arena, *target);
            walk_expr(v, arena, *value);
        }
        Stmt::Expression { expr } => {
            walk_expr(v, arena, *expr);
        }
        Stmt::Return { value } => {
            if let Some(e) = value {
                walk_expr(v, arena, *e);
            }
        }
        Stmt::Defer { expr } => {
            walk_expr(v, arena, *expr);
        }
        Stmt::Throw { expr } => {
            walk_expr(v, arena, *expr);
        }
        Stmt::Break | Stmt::Continue => {}
        Stmt::For {
            iterable, body, ..
        } => {
            walk_expr(v, arena, *iterable);
            walk_expr(v, arena, *body);
        }
        Stmt::While { condition, body } => {
            walk_expr(v, arena, *condition);
            walk_expr(v, arena, *body);
        }
        Stmt::Loop { body } => {
            walk_expr(v, arena, *body);
        }
    }
}

pub fn walk_expr<'a, V: AstVisitor<'a>>(v: &mut V, arena: &'a AstArena<'a>, id: ExprId) {
    v.visit_expr(id);
    let expr = arena.expr(id);
    match &expr.node {
        Expr::IntLit { .. }
        | Expr::FloatLit { .. }
        | Expr::BoolLit(_)
        | Expr::CharLit(_)
        | Expr::StrLit(_)
        | Expr::NullLit
        | Expr::VoidLit
        | Expr::Ident(_) => {}
        Expr::StrInterp(parts) => {
            for part in parts {
                walk_interpolation_part(v, arena, part);
            }
        }
        Expr::Assign { target, value } => {
            walk_expr(v, arena, *target);
            walk_expr(v, arena, *value);
        }
        Expr::CompoundAssign { target, value, .. } => {
            walk_expr(v, arena, *target);
            walk_expr(v, arena, *value);
        }
        Expr::Binary { lhs, rhs, .. } => {
            walk_expr(v, arena, *lhs);
            walk_expr(v, arena, *rhs);
        }
        Expr::Unary { operand, .. } => {
            walk_expr(v, arena, *operand);
        }
        Expr::RefOf(inner) | Expr::Deref(inner) | Expr::Propagate(inner)
        | Expr::NonNullAssert(inner) | Expr::Atomic(inner) | Expr::Lazy(inner) => {
            walk_expr(v, arena, *inner);
        }
        Expr::Call {
            callee,
            args,
            type_args,
        } => {
            walk_expr(v, arena, *callee);
            for a in args {
                walk_expr(v, arena, *a);
            }
            if let Some(ta) = type_args {
                for t in ta {
                    walk_type(v, arena, *t);
                }
            }
        }
        Expr::MethodCall {
            recv,
            args,
            type_args,
            ..
        } => {
            walk_expr(v, arena, *recv);
            for a in args {
                walk_expr(v, arena, *a);
            }
            if let Some(ta) = type_args {
                for t in ta {
                    walk_type(v, arena, *t);
                }
            }
        }
        Expr::FieldAccess { recv, .. } | Expr::SafeAccess { recv, .. } => {
            walk_expr(v, arena, *recv);
        }
        Expr::Index { recv, index } => {
            walk_expr(v, arena, *recv);
            walk_expr(v, arena, *index);
        }
        Expr::Slice {
            recv, start, end, ..
        } => {
            walk_expr(v, arena, *recv);
            walk_expr(v, arena, *start);
            walk_expr(v, arena, *end);
        }
        Expr::SafeMethodCall {
            recv,
            args,
            type_args,
            ..
        } => {
            walk_expr(v, arena, *recv);
            for a in args {
                walk_expr(v, arena, *a);
            }
            if let Some(ta) = type_args {
                for t in ta {
                    walk_type(v, arena, *t);
                }
            }
        }
        Expr::Elvis { lhs, rhs } => {
            walk_expr(v, arena, *lhs);
            walk_expr(v, arena, *rhs);
        }
        Expr::ArrayLit { elements, fill } => {
            for e in elements {
                walk_expr(v, arena, *e);
            }
            if let Some((value, count)) = fill {
                walk_expr(v, arena, *value);
                walk_expr(v, arena, *count);
            }
        }
        Expr::RecordLit(fields) => {
            for f in fields {
                walk_record_field_expr(v, arena, f);
            }
        }
        Expr::RecordExtend { base, updates } => {
            walk_expr(v, arena, *base);
            for f in updates {
                walk_record_field_expr(v, arena, f);
            }
        }
        Expr::Lambda {
            params,
            body,
            return_type,
            ..
        } => {
            for p in params {
                walk_param(v, arena, p);
            }
            walk_lambda_body(v, arena, body);
            if let Some(rt) = return_type {
                walk_type(v, arena, *rt);
            }
        }
        Expr::If {
            cond,
            then_branch,
            else_branch,
        } => {
            walk_expr(v, arena, *cond);
            walk_expr(v, arena, *then_branch);
            if let Some(e) = else_branch {
                walk_expr(v, arena, *e);
            }
        }
        Expr::Block { stmts, trailing } => {
            for s in stmts {
                walk_stmt(v, arena, *s);
            }
            if let Some(e) = trailing {
                walk_expr(v, arena, *e);
            }
        }
        Expr::Match { scrutinee, arms } => {
            walk_expr(v, arena, *scrutinee);
            for arm in arms {
                walk_match_arm(v, arena, arm);
            }
        }
        Expr::TypeCast { target, expr, .. } => {
            walk_type(v, arena, *target);
            walk_expr(v, arena, *expr);
        }
        Expr::CastBuilder { expr, target, .. } => {
            walk_expr(v, arena, *expr);
            walk_type(v, arena, *target);
        }
        Expr::Select(arms) => {
            for arm in arms {
                walk_select_arm(v, arena, arm);
            }
        }
        Expr::InlineTrait(methods) => {
            for m in methods {
                walk_method_decl(v, arena, m);
            }
        }
    }
}

pub fn walk_type<'a, V: AstVisitor<'a>>(v: &mut V, arena: &'a AstArena<'a>, id: TypeId) {
    v.visit_type(id);
    let ty = arena.ty(id);
    match &ty.node {
        TypeNode::Named { .. } | TypeNode::SelfType => {}
        TypeNode::Generic { args, .. } => {
            for a in args {
                walk_type(v, arena, *a);
            }
        }
        TypeNode::Nullable { inner }
        | TypeNode::RefType { inner }
        | TypeNode::RawPtr { inner } => {
            walk_type(v, arena, *inner);
        }
        TypeNode::Function {
            params,
            return_type,
        } => {
            for p in params {
                walk_type(v, arena, *p);
            }
            walk_type(v, arena, *return_type);
        }
        TypeNode::Record { fields } => {
            for f in fields {
                walk_record_field_type(v, arena, f);
            }
        }
        TypeNode::Array { element_type, .. } => {
            walk_type(v, arena, *element_type);
        }
        TypeNode::KindAnnotated { inner, kind } => {
            walk_type(v, arena, *inner);
            walk_kind(v, kind);
        }
    }
}

pub fn walk_pattern<'a, V: AstVisitor<'a>>(v: &mut V, arena: &'a AstArena<'a>, id: PatternId) {
    v.visit_pattern(id);
    let pat = arena.pattern(id);
    match &pat.node {
        Pattern::Wildcard | Pattern::Literal(_) | Pattern::Variable { .. } => {}
        Pattern::Constructor { patterns, .. } => {
            for p in patterns {
                walk_pattern(v, arena, *p);
            }
        }
        Pattern::Record { fields } => {
            for f in fields {
                walk_pattern(v, arena, f.pattern);
            }
        }
        Pattern::OrPattern { left, right } => {
            walk_pattern(v, arena, *left);
            walk_pattern(v, arena, *right);
        }
        Pattern::Guard { pattern, condition } => {
            walk_pattern(v, arena, *pattern);
            walk_expr(v, arena, *condition);
        }
    }
}

pub fn walk_kind<'a, V: AstVisitor<'a>>(v: &mut V, kind: &'a Kind) {
    v.visit_kind(kind);
    match kind {
        Kind::Star => {}
        Kind::Arrow { param, result } => {
            walk_kind(v, param);
            walk_kind(v, result);
        }
    }
}

// --- 辅助 struct 的 walk 函数 ---

fn walk_type_param<'a, V: AstVisitor<'a>>(v: &mut V, arena: &'a AstArena<'a>, tp: &'a TypeParam<'a>) {
    if let Some(k) = &tp.kind {
        walk_kind(v, k);
    }
    for b in &tp.bounds {
        walk_trait_bound(v, arena, b);
    }
}

fn walk_trait_bound<'a, V: AstVisitor<'a>>(v: &mut V, arena: &'a AstArena<'a>, b: &'a TraitBound<'a>) {
    for t in &b.type_args {
        walk_type(v, arena, *t);
    }
}

fn walk_type_constraint<'a, V: AstVisitor<'a>>(v: &mut V, arena: &'a AstArena<'a>, c: &'a TypeConstraint<'a>) {
    walk_type(v, arena, c.concrete_type);
}

fn walk_param<'a, V: AstVisitor<'a>>(v: &mut V, arena: &'a AstArena<'a>, p: &'a Param<'a>) {
    if let Some(ty) = &p.type_annotation {
        walk_type(v, arena, *ty);
    }
}

fn walk_associated_type<'a, V: AstVisitor<'a>>(v: &mut V, at: &'a AssociatedType<'a>) {
    if let Some(k) = &at.kind {
        walk_kind(v, k);
    }
}

fn walk_method_decl<'a, V: AstVisitor<'a>>(v: &mut V, arena: &'a AstArena<'a>, m: &'a MethodDecl<'a>) {
    for tp in &m.type_params {
        walk_type_param(v, arena, tp);
    }
    for p in &m.params {
        walk_param(v, arena, p);
    }
    if let Some(rt) = &m.return_type {
        walk_type(v, arena, *rt);
    }
    if let Some(body) = &m.body {
        walk_expr(v, arena, *body);
    }
}

fn walk_constructor_def<'a, V: AstVisitor<'a>>(v: &mut V, arena: &'a AstArena<'a>, ctor: &'a ConstructorDef<'a>) {
    for f in &ctor.fields {
        walk_constructor_field(v, arena, f);
    }
    if let Some(rt) = &ctor.return_type {
        walk_type(v, arena, *rt);
    }
}

fn walk_constructor_field<'a, V: AstVisitor<'a>>(v: &mut V, arena: &'a AstArena<'a>, f: &'a ConstructorField<'a>) {
    walk_type(v, arena, f.ty);
}

fn walk_record_field_type<'a, V: AstVisitor<'a>>(v: &mut V, arena: &'a AstArena<'a>, f: &'a RecordFieldType<'a>) {
    walk_type(v, arena, f.ty);
}

fn walk_record_field_expr<'a, V: AstVisitor<'a>>(v: &mut V, arena: &'a AstArena<'a>, f: &'a RecordFieldExpr<'a>) {
    walk_expr(v, arena, f.value);
}

fn walk_interpolation_part<'a, V: AstVisitor<'a>>(v: &mut V, arena: &'a AstArena<'a>, part: &'a InterpolationPart<'a>) {
    if let InterpolationPart::Expression(e) = part {
        walk_expr(v, arena, *e);
    }
}

fn walk_lambda_body<'a, V: AstVisitor<'a>>(v: &mut V, arena: &'a AstArena<'a>, body: &LambdaBody) {
    match body {
        LambdaBody::Block(e) | LambdaBody::Expression(e) => {
            walk_expr(v, arena, *e);
        }
    }
}

fn walk_match_arm<'a, V: AstVisitor<'a>>(v: &mut V, arena: &'a AstArena<'a>, arm: &MatchArm) {
    walk_pattern(v, arena, arm.pattern);
    if let Some(g) = &arm.guard {
        walk_expr(v, arena, *g);
    }
    walk_expr(v, arena, arm.body);
}

fn walk_select_arm<'a, V: AstVisitor<'a>>(v: &mut V, arena: &'a AstArena<'a>, arm: &'a SelectArm<'a>) {
    match arm {
        SelectArm::Receive {
            channel_expr, body, ..
        } => {
            walk_expr(v, arena, *channel_expr);
            walk_expr(v, arena, *body);
        }
        SelectArm::Timeout { duration, body } => {
            walk_expr(v, arena, *duration);
            walk_expr(v, arena, *body);
        }
    }
}

// BinaryOp 优先级表
//
// 单一扁平注册表 + 数值优先级，驱动单一 Pratt 解析器。
// 替代 13 层 parseXxx 模板函数（parseElvis/Or/And/BitOr/BitXor/BitAnd/Shift/
// Equality/Comparison/Range/Addition/Multiplication）。
//
// 新增二元运算符只需在 BINARY_OPS 追加一条，无需改解析器。


/// 单个运算符映射：token 类型 → BinaryOp + 优先级
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OpMapping {
    pub token: TokenKind,
    pub op: BinaryOp,
    /// 数值越大越紧密
    pub precedence: u8,
    /// 仅 `*`（乘法 vs 解引用歧义）需跨行检查
    pub check_multiline_deref: bool,
    /// 右结合（如 `??` elvis 运算符）
    pub right_assoc: bool,
}

// 优先级常量（从低到高）
pub const ELVIS_PREC: u8 = 1;
pub const OR_PREC: u8 = 2;
pub const AND_PREC: u8 = 3;
pub const BIT_OR_PREC: u8 = 4;
pub const BIT_XOR_PREC: u8 = 5;
pub const BIT_AND_PREC: u8 = 6;
pub const SHIFT_PREC: u8 = 7;
pub const EQUALITY_PREC: u8 = 8;
pub const COMPARISON_PREC: u8 = 9;
pub const RANGE_PREC: u8 = 10;
pub const ADDITION_PREC: u8 = 11;
pub const MULTIPLICATION_PREC: u8 = 12;

/// 最低优先级（Pratt 解析器入口）
pub const MIN_PREC: u8 = ELVIS_PREC;

/// 扁平二元运算符注册表（单一真相来源）
///
/// 新增运算符只需在此追加一条。
pub const BINARY_OPS: &[OpMapping] = &[
    // Elvis ?? (最低，右结合)
    OpMapping {
        token: TokenKind::QuestionQuestion,
        op: BinaryOp::Elvis,
        precedence: ELVIS_PREC,
        check_multiline_deref: false,
        right_assoc: true,
    },
    // 逻辑或 ||
    OpMapping {
        token: TokenKind::PipePipe,
        op: BinaryOp::Or,
        precedence: OR_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    // 逻辑与 &&
    OpMapping {
        token: TokenKind::AmpAmp,
        op: BinaryOp::And,
        precedence: AND_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    // 按位或 |
    OpMapping {
        token: TokenKind::Pipe,
        op: BinaryOp::BitOr,
        precedence: BIT_OR_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    // 按位异或 ^
    OpMapping {
        token: TokenKind::Caret,
        op: BinaryOp::BitXor,
        precedence: BIT_XOR_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    // 按位与 &
    OpMapping {
        token: TokenKind::Ampersand,
        op: BinaryOp::BitAnd,
        precedence: BIT_AND_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    // 移位 << >>
    OpMapping {
        token: TokenKind::LtLt,
        op: BinaryOp::Shl,
        precedence: SHIFT_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    OpMapping {
        token: TokenKind::GtGt,
        op: BinaryOp::Shr,
        precedence: SHIFT_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    // 相等 == != === !==
    OpMapping {
        token: TokenKind::EqEq,
        op: BinaryOp::Eq,
        precedence: EQUALITY_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    OpMapping {
        token: TokenKind::BangEq,
        op: BinaryOp::NotEq,
        precedence: EQUALITY_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    OpMapping {
        token: TokenKind::RefEq,
        op: BinaryOp::RefEq,
        precedence: EQUALITY_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    OpMapping {
        token: TokenKind::RefNeq,
        op: BinaryOp::RefNeq,
        precedence: EQUALITY_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    // 比较 < > <= >=
    OpMapping {
        token: TokenKind::Lt,
        op: BinaryOp::Lt,
        precedence: COMPARISON_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    OpMapping {
        token: TokenKind::Gt,
        op: BinaryOp::Gt,
        precedence: COMPARISON_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    OpMapping {
        token: TokenKind::LtEq,
        op: BinaryOp::LtEq,
        precedence: COMPARISON_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    OpMapping {
        token: TokenKind::GtEq,
        op: BinaryOp::GtEq,
        precedence: COMPARISON_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    // 范围 .. ..=
    OpMapping {
        token: TokenKind::DotDot,
        op: BinaryOp::Range,
        precedence: RANGE_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    OpMapping {
        token: TokenKind::DotDotEq,
        op: BinaryOp::RangeInclusive,
        precedence: RANGE_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    // 加减 + ++ -
    OpMapping {
        token: TokenKind::Plus,
        op: BinaryOp::Add,
        precedence: ADDITION_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    OpMapping {
        token: TokenKind::PlusPlus,
        op: BinaryOp::ConcatList,
        precedence: ADDITION_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    OpMapping {
        token: TokenKind::Minus,
        op: BinaryOp::Sub,
        precedence: ADDITION_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    // 乘除模 * / %（`*` 需跨行解引用检查）
    OpMapping {
        token: TokenKind::Star,
        op: BinaryOp::Mul,
        precedence: MULTIPLICATION_PREC,
        check_multiline_deref: true,
        right_assoc: false,
    },
    OpMapping {
        token: TokenKind::Slash,
        op: BinaryOp::Div,
        precedence: MULTIPLICATION_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
    OpMapping {
        token: TokenKind::Percent,
        op: BinaryOp::Mod,
        precedence: MULTIPLICATION_PREC,
        check_multiline_deref: false,
        right_assoc: false,
    },
];

/// 按 token 类型查找二元运算符映射，未找到返回 None
pub fn lookup_binary_op(tok: TokenKind) -> Option<&'static OpMapping> {
    BINARY_OPS.iter().find(|m| m.token == tok)
}

#[cfg(test)]
mod binary_op_table_tests {
    use super::*;

    #[test]
    fn test_lookup_all_operators() {
        // 全部 22 个二元运算符都可查到
        assert!(lookup_binary_op(TokenKind::QuestionQuestion).is_some());
        assert!(lookup_binary_op(TokenKind::PipePipe).is_some());
        assert!(lookup_binary_op(TokenKind::AmpAmp).is_some());
        assert!(lookup_binary_op(TokenKind::Pipe).is_some());
        assert!(lookup_binary_op(TokenKind::Caret).is_some());
        assert!(lookup_binary_op(TokenKind::Ampersand).is_some());
        assert!(lookup_binary_op(TokenKind::LtLt).is_some());
        assert!(lookup_binary_op(TokenKind::GtGt).is_some());
        assert!(lookup_binary_op(TokenKind::EqEq).is_some());
        assert!(lookup_binary_op(TokenKind::BangEq).is_some());
        assert!(lookup_binary_op(TokenKind::RefEq).is_some());
        assert!(lookup_binary_op(TokenKind::RefNeq).is_some());
        assert!(lookup_binary_op(TokenKind::Lt).is_some());
        assert!(lookup_binary_op(TokenKind::Gt).is_some());
        assert!(lookup_binary_op(TokenKind::LtEq).is_some());
        assert!(lookup_binary_op(TokenKind::GtEq).is_some());
        assert!(lookup_binary_op(TokenKind::DotDot).is_some());
        assert!(lookup_binary_op(TokenKind::DotDotEq).is_some());
        assert!(lookup_binary_op(TokenKind::Plus).is_some());
        assert!(lookup_binary_op(TokenKind::PlusPlus).is_some());
        assert!(lookup_binary_op(TokenKind::Minus).is_some());
        assert!(lookup_binary_op(TokenKind::Star).is_some());
        assert!(lookup_binary_op(TokenKind::Slash).is_some());
        assert!(lookup_binary_op(TokenKind::Percent).is_some());
    }

    #[test]
    fn test_lookup_non_operator_returns_none() {
        assert!(lookup_binary_op(TokenKind::Identifier).is_none());
        assert!(lookup_binary_op(TokenKind::IntLiteral).is_none());
        assert!(lookup_binary_op(TokenKind::LParen).is_none());
        assert!(lookup_binary_op(TokenKind::Eof).is_none());
        assert!(lookup_binary_op(TokenKind::Eq).is_none()); // 赋值不是二元运算符
        assert!(lookup_binary_op(TokenKind::PlusEq).is_none()); // 复合赋值不是二元运算符
    }

    #[test]
    fn test_elvis_is_right_assoc() {
        let m = lookup_binary_op(TokenKind::QuestionQuestion).unwrap();
        assert!(m.right_assoc);
        assert_eq!(m.precedence, ELVIS_PREC);
        assert_eq!(m.op, BinaryOp::Elvis);
    }

    #[test]
    fn test_star_needs_multiline_deref_check() {
        let m = lookup_binary_op(TokenKind::Star).unwrap();
        assert!(m.check_multiline_deref);
        assert_eq!(m.precedence, MULTIPLICATION_PREC);
        assert_eq!(m.op, BinaryOp::Mul);
    }

    #[test]
    fn test_other_ops_not_multiline() {
        // 除 `*` 外其他运算符都不需要跨行检查
        for m in BINARY_OPS {
            if m.token == TokenKind::Star {
                continue;
            }
            assert!(!m.check_multiline_deref, "token {:?} should not check multiline", m.token);
        }
    }

    #[test]
    fn test_only_elvis_is_right_assoc() {
        // 除 `??` 外其他运算符都是左结合
        for m in BINARY_OPS {
            if m.token == TokenKind::QuestionQuestion {
                assert!(m.right_assoc);
            } else {
                assert!(!m.right_assoc, "token {:?} should be left-assoc", m.token);
            }
        }
    }

    #[test]
    fn test_precedence_ordering() {
        // 验证优先级顺序：elvis < or < and < bit_or < bit_xor < bit_and
        // < shift < equality < comparison < range < addition < multiplication
        const {
            assert!(ELVIS_PREC < OR_PREC);
            assert!(OR_PREC < AND_PREC);
            assert!(AND_PREC < BIT_OR_PREC);
            assert!(BIT_OR_PREC < BIT_XOR_PREC);
            assert!(BIT_XOR_PREC < BIT_AND_PREC);
            assert!(BIT_AND_PREC < SHIFT_PREC);
            assert!(SHIFT_PREC < EQUALITY_PREC);
            assert!(EQUALITY_PREC < COMPARISON_PREC);
            assert!(COMPARISON_PREC < RANGE_PREC);
            assert!(RANGE_PREC < ADDITION_PREC);
            assert!(ADDITION_PREC < MULTIPLICATION_PREC);
        }
    }

    #[test]
    fn test_binary_ops_count() {
        // 共 24 条映射（22 种运算符，其中 Range/RangeInclusive 各 1，Add/ConcatList/Sub 各 1，Mul/Div/Mod 各 1）
        // 实际：1(elvis) + 1(or) + 1(and) + 1(bor) + 1(bxor) + 1(band)
        //     + 2(shift) + 4(equality) + 4(comparison) + 2(range) + 3(addition) + 3(mul) = 24
        assert_eq!(BINARY_OPS.len(), 24);
    }
}

// 词法分析器（Lexer）
//
// 将 Glue 源码字符串逐字符扫描为 Token 序列，支持关键字、标识符、
// 整数（含二/八/十六进制）、浮点数、字符与字符串字面量（含插值），
// 以及各类运算符与分隔符。Token 同时携带行列号信息以便错误定位。
//
// 语义对应 Zig 原版 `src/parse/lexer.zig`，但用 Rust 惯例重写。
// 分号 `;` 被当作空白字符跳过；遇到词法错误时生成 `Err` token 并继续扫描，
// 以便 parser 能收集更多错误。

// =========================================================================
// TokenKind：覆盖所有字面量、关键字、运算符与分隔符
// =========================================================================

/// 词法单元类型：覆盖所有字面量、关键字、运算符与分隔符
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TokenKind {
    // --- 字面量（7 种）---
    IntLiteral,
    FloatLiteral,
    CharLiteral,
    StringLiteral,
    TrueLiteral,
    FalseLiteral,
    NullLiteral,

    // --- 关键字（28 种）---
    KwFun,
    KwType,
    KwTrait,
    KwOverride,
    KwPack,
    KwPub,
    KwImport,
    KwWith,
    KwAs,
    KwVal,
    KwVar,
    KwMatch,
    KwIf,
    KwElse,
    KwAsync,
    KwChannel,
    KwSelect,
    KwAtomic,
    KwLoop,
    KwFor,
    KwIn,
    KwWhile,
    KwBreak,
    KwContinue,
    KwReturn,
    KwThrow,
    KwLazy,
    KwDefer,

    // 标识符
    Identifier,

    // --- 运算符（42 种）---
    Plus,
    Minus,
    Star,
    Slash,
    Percent,
    EqEq,
    BangEq,
    RefEq,
    RefNeq,
    Lt,
    Gt,
    LtEq,
    GtEq,
    LtMinus,
    AmpAmp,
    PipePipe,
    Bang,
    Ampersand,
    Caret,
    QuestionDot,
    QuestionQuestion,
    Question,
    DotDot,
    DotDotEq,
    Ellipsis,
    Eq,
    PlusEq,
    PlusPlus,
    MinusEq,
    StarEq,
    SlashEq,
    PercentEq,
    AmpEq,
    PipeEq,
    CaretEq,
    LtLt,
    GtGt,
    LtLtEq,
    GtGtEq,
    Tilde,
    EqGt,
    MinusGt,

    // --- 分隔符（10 种）---
    LParen,
    RParen,
    LBracket,
    RBracket,
    LBrace,
    RBrace,
    Comma,
    Colon,
    Dot,
    Pipe,

    // --- 属性与原始块 ---
    At,        // @
    RawBlock,  // #{ ... }# 原始块（lexeme 为内部内容，不含 #{ 和 }#）

    // --- 特殊（2 种）---
    Eof,
    Err,
}

// =========================================================================
// Token
// =========================================================================

/// 词法单元：类型、字面文本（零拷贝引用源码）、行列号
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Token<'a> {
    pub kind: TokenKind,
    pub lexeme: &'a str,
    pub line: u32,
    pub column: u32,
}

// =========================================================================
// LexerError
// =========================================================================

/// 词法分析可能产生的错误类型
#[derive(Debug, Clone)]
pub enum LexerError {
    UnterminatedString,
    UnterminatedChar,
    UnterminatedComment,
    InvalidEscape,
    InvalidUnicodeEscape,
    InvalidNumber,
    InvalidHexDigit,
    InvalidOctalDigit,
    InvalidBinaryDigit,
}

// =========================================================================
// TokenSink — Token 接收器 trait
// =========================================================================

/// Token 接收器 trait。Lexer 每生成一个 Token 调用 `emit_token`。
/// 默认实现 `TokenCollector` 收集到 `Vec<Token>`。
pub trait TokenSink<'a> {
    fn emit_token(&mut self, token: Token<'a>);
}

/// 默认接收器：收集到 Vec
pub struct TokenCollector<'a> {
    pub tokens: Vec<Token<'a>>,
}

impl<'a> TokenCollector<'a> {
    pub fn new() -> Self {
        Self { tokens: Vec::new() }
    }

    /// 消费 self 返回收集到的 Token 列表
    pub fn into_tokens(self) -> Vec<Token<'a>> {
        self.tokens
    }
}

impl<'a> Default for TokenCollector<'a> {
    fn default() -> Self {
        Self::new()
    }
}

impl<'a> TokenSink<'a> for TokenCollector<'a> {
    fn emit_token(&mut self, token: Token<'a>) {
        self.tokens.push(token);
    }
}

// =========================================================================
// Lexer
// =========================================================================

/// 词法分析器：持有源码、扫描位置与行列号
pub struct Lexer<'a> {
    source: &'a str,
    bytes: &'a [u8],
    pos: usize,
    line: u32,
    column: u32,
}

impl<'a> Lexer<'a> {
    /// 创建词法分析器
    pub fn new(source: &'a str) -> Self {
        Self {
            source,
            bytes: source.as_bytes(),
            pos: 0,
            line: 1,
            column: 1,
        }
    }

    /// 扫描整个源码并将 Token 流式发送到 sink，末尾追加 `Eof`。
    ///
    /// 遇到词法错误时生成 `Err` token 并继续扫描（不中断），
    /// 以便 parser 能收集更多错误。
    pub fn tokenize_into<S: TokenSink<'a>>(&mut self, sink: &mut S) {
        while self.pos < self.bytes.len() {
            let start = self.pos;
            let start_line = self.line;
            let start_col = self.column;
            match self.scan_token() {
                Ok(Some(tok)) => sink.emit_token(tok),
                Ok(None) => {}
                Err(_) => {
                    // 生成错误 Token，覆盖已消费的范围，继续扫描
                    sink.emit_token(Token {
                        kind: TokenKind::Err,
                        lexeme: &self.source[start..self.pos],
                        line: start_line,
                        column: start_col,
                    });
                }
            }
        }
        sink.emit_token(Token {
            kind: TokenKind::Eof,
            lexeme: "",
            line: self.line,
            column: self.column,
        });
    }

    // --- 基础字符操作 ---

    /// 查看当前位置字符（不前进）
    #[allow(dead_code)]
    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    /// 查看下一位置字符（不前进）
    #[allow(dead_code)]
    fn peek_next(&self) -> Option<u8> {
        self.bytes.get(self.pos + 1).copied()
    }

    /// 消费当前字符并前进，遇到换行时同步更新行列号
    fn advance(&mut self) -> Option<u8> {
        let ch = *self.bytes.get(self.pos)?;
        self.pos += 1;
        if ch == b'\n' {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        Some(ch)
    }

    /// 当当前字符等于预期时消费并前进，返回是否匹配
    fn match_char(&mut self, expected: u8) -> bool {
        if self.pos >= self.bytes.len() {
            return false;
        }
        if self.bytes[self.pos] != expected {
            return false;
        }
        self.pos += 1;
        if expected == b'\n' {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        true
    }

    /// 根据起止位置与行列号构造 Token（lexeme 零拷贝引用源码）
    fn make_token(&self, kind: TokenKind, start: usize, start_line: u32, start_col: u32) -> Token<'a> {
        Token {
            kind,
            lexeme: &self.source[start..self.pos],
            line: start_line,
            column: start_col,
        }
    }

    // --- 单个词法单元扫描 ---

    /// 扫描单个词法单元：根据首字符分派到对应处理分支。
    /// 返回 `Ok(None)` 表示空白/注释/分号（不产生 Token）。
    fn scan_token(&mut self) -> Result<Option<Token<'a>>, LexerError> {
        let start = self.pos;
        let start_line = self.line;
        let start_col = self.column;
        let ch = match self.advance() {
            Some(c) => c,
            None => return Ok(None),
        };
        match ch {
            // 空白字符直接跳过
            b' ' | b'\t' | b'\r' | b'\n' => Ok(None),
            b'/' => {
                if self.match_char(b'/') {
                    self.skip_line_comment();
                    Ok(None)
                } else if self.match_char(b'*') {
                    self.skip_block_comment()?;
                    Ok(None)
                } else if self.match_char(b'=') {
                    Ok(Some(self.make_token(TokenKind::SlashEq, start, start_line, start_col)))
                } else {
                    Ok(Some(self.make_token(TokenKind::Slash, start, start_line, start_col)))
                }
            }
            b'(' => Ok(Some(self.make_token(TokenKind::LParen, start, start_line, start_col))),
            b')' => Ok(Some(self.make_token(TokenKind::RParen, start, start_line, start_col))),
            b'[' => Ok(Some(self.make_token(TokenKind::LBracket, start, start_line, start_col))),
            b']' => Ok(Some(self.make_token(TokenKind::RBracket, start, start_line, start_col))),
            b'{' => Ok(Some(self.make_token(TokenKind::LBrace, start, start_line, start_col))),
            b'}' => Ok(Some(self.make_token(TokenKind::RBrace, start, start_line, start_col))),
            b',' => Ok(Some(self.make_token(TokenKind::Comma, start, start_line, start_col))),
            // 分号被当作空白字符跳过
            b';' => Ok(None),
            b':' => Ok(Some(self.make_token(TokenKind::Colon, start, start_line, start_col))),
            b'%' => {
                if self.match_char(b'=') {
                    Ok(Some(self.make_token(TokenKind::PercentEq, start, start_line, start_col)))
                } else {
                    Ok(Some(self.make_token(TokenKind::Percent, start, start_line, start_col)))
                }
            }
            b'+' => {
                if self.match_char(b'=') {
                    Ok(Some(self.make_token(TokenKind::PlusEq, start, start_line, start_col)))
                } else if self.match_char(b'+') {
                    Ok(Some(self.make_token(TokenKind::PlusPlus, start, start_line, start_col)))
                } else {
                    Ok(Some(self.make_token(TokenKind::Plus, start, start_line, start_col)))
                }
            }
            b'*' => {
                if self.match_char(b'=') {
                    Ok(Some(self.make_token(TokenKind::StarEq, start, start_line, start_col)))
                } else {
                    Ok(Some(self.make_token(TokenKind::Star, start, start_line, start_col)))
                }
            }
            b'|' => {
                if self.match_char(b'|') {
                    Ok(Some(self.make_token(TokenKind::PipePipe, start, start_line, start_col)))
                } else if self.match_char(b'=') {
                    Ok(Some(self.make_token(TokenKind::PipeEq, start, start_line, start_col)))
                } else {
                    Ok(Some(self.make_token(TokenKind::Pipe, start, start_line, start_col)))
                }
            }
            b'=' => {
                if self.match_char(b'=') {
                    if self.match_char(b'=') {
                        Ok(Some(self.make_token(TokenKind::RefEq, start, start_line, start_col)))
                    } else {
                        Ok(Some(self.make_token(TokenKind::EqEq, start, start_line, start_col)))
                    }
                } else if self.match_char(b'>') {
                    Ok(Some(self.make_token(TokenKind::EqGt, start, start_line, start_col)))
                } else {
                    Ok(Some(self.make_token(TokenKind::Eq, start, start_line, start_col)))
                }
            }
            b'!' => {
                if self.match_char(b'=') {
                    if self.match_char(b'=') {
                        Ok(Some(self.make_token(TokenKind::RefNeq, start, start_line, start_col)))
                    } else {
                        Ok(Some(self.make_token(TokenKind::BangEq, start, start_line, start_col)))
                    }
                } else {
                    Ok(Some(self.make_token(TokenKind::Bang, start, start_line, start_col)))
                }
            }
            b'<' => {
                if self.match_char(b'<') {
                    if self.match_char(b'=') {
                        Ok(Some(self.make_token(TokenKind::LtLtEq, start, start_line, start_col)))
                    } else {
                        Ok(Some(self.make_token(TokenKind::LtLt, start, start_line, start_col)))
                    }
                } else if self.match_char(b'=') {
                    Ok(Some(self.make_token(TokenKind::LtEq, start, start_line, start_col)))
                } else if self.match_char(b'-') {
                    Ok(Some(self.make_token(TokenKind::LtMinus, start, start_line, start_col)))
                } else {
                    Ok(Some(self.make_token(TokenKind::Lt, start, start_line, start_col)))
                }
            }
            b'>' => {
                if self.match_char(b'>') {
                    if self.match_char(b'=') {
                        Ok(Some(self.make_token(TokenKind::GtGtEq, start, start_line, start_col)))
                    } else {
                        Ok(Some(self.make_token(TokenKind::GtGt, start, start_line, start_col)))
                    }
                } else if self.match_char(b'=') {
                    Ok(Some(self.make_token(TokenKind::GtEq, start, start_line, start_col)))
                } else {
                    Ok(Some(self.make_token(TokenKind::Gt, start, start_line, start_col)))
                }
            }
            b'-' => {
                if self.match_char(b'>') {
                    Ok(Some(self.make_token(TokenKind::MinusGt, start, start_line, start_col)))
                } else if self.match_char(b'=') {
                    Ok(Some(self.make_token(TokenKind::MinusEq, start, start_line, start_col)))
                } else {
                    Ok(Some(self.make_token(TokenKind::Minus, start, start_line, start_col)))
                }
            }
            b'.' => {
                if self.match_char(b'.') {
                    if self.match_char(b'=') {
                        Ok(Some(self.make_token(TokenKind::DotDotEq, start, start_line, start_col)))
                    } else if self.match_char(b'.') {
                        Ok(Some(self.make_token(TokenKind::Ellipsis, start, start_line, start_col)))
                    } else {
                        Ok(Some(self.make_token(TokenKind::DotDot, start, start_line, start_col)))
                    }
                } else {
                    // 单独点号后跟数字时，按 .浮点数 处理（如 .5）
                    if self.pos < self.bytes.len() && is_digit(self.bytes[self.pos]) {
                        self.scan_dot_float(start, start_line, start_col)
                    } else {
                        Ok(Some(self.make_token(TokenKind::Dot, start, start_line, start_col)))
                    }
                }
            }
            b'?' => {
                if self.match_char(b'.') {
                    Ok(Some(self.make_token(TokenKind::QuestionDot, start, start_line, start_col)))
                } else if self.match_char(b'?') {
                    Ok(Some(self.make_token(TokenKind::QuestionQuestion, start, start_line, start_col)))
                } else {
                    Ok(Some(self.make_token(TokenKind::Question, start, start_line, start_col)))
                }
            }
            b'&' => {
                if self.match_char(b'&') {
                    Ok(Some(self.make_token(TokenKind::AmpAmp, start, start_line, start_col)))
                } else if self.match_char(b'=') {
                    Ok(Some(self.make_token(TokenKind::AmpEq, start, start_line, start_col)))
                } else {
                    Ok(Some(self.make_token(TokenKind::Ampersand, start, start_line, start_col)))
                }
            }
            b'^' => {
                if self.match_char(b'=') {
                    Ok(Some(self.make_token(TokenKind::CaretEq, start, start_line, start_col)))
                } else {
                    Ok(Some(self.make_token(TokenKind::Caret, start, start_line, start_col)))
                }
            }
            b'~' => Ok(Some(self.make_token(TokenKind::Tilde, start, start_line, start_col))),
            b'@' => Ok(Some(self.make_token(TokenKind::At, start, start_line, start_col))),
            b'#' => {
                if self.match_char(b'{') {
                    self.scan_raw_block(start, start_line, start_col)
                } else {
                    Ok(Some(self.make_token(TokenKind::Err, start, start_line, start_col)))
                }
            }
            b'\'' => self.scan_char(start, start_line, start_col),
            b'"' => self.scan_string(start, start_line, start_col),
            b'0'..=b'9' => self.scan_number(start, start_line, start_col),
            b'a'..=b'z' | b'A'..=b'Z' | b'_' => self.scan_identifier(start, start_line, start_col),
            // 未知字符：生成错误 Token（不中断扫描）
            _ => Ok(Some(self.make_token(TokenKind::Err, start, start_line, start_col))),
        }
    }

    // --- 注释 ---

    /// 跳过行注释（// 到行尾，不消费换行符）
    fn skip_line_comment(&mut self) {
        while self.pos < self.bytes.len() {
            if self.bytes[self.pos] == b'\n' {
                break;
            }
            self.pos += 1;
            self.column += 1;
        }
    }

    /// 跳过块注释（/* */，支持嵌套）
    fn skip_block_comment(&mut self) -> Result<(), LexerError> {
        let mut depth: u32 = 1;
        while self.pos < self.bytes.len() && depth > 0 {
            let ch = self.bytes[self.pos];
            if ch == b'/' && self.pos + 1 < self.bytes.len() && self.bytes[self.pos + 1] == b'*' {
                depth += 1;
                self.pos += 2;
                self.column += 2;
            } else if ch == b'*' && self.pos + 1 < self.bytes.len() && self.bytes[self.pos + 1] == b'/' {
                depth -= 1;
                self.pos += 2;
                self.column += 2;
            } else if ch == b'\n' {
                self.pos += 1;
                self.line += 1;
                self.column = 1;
            } else {
                self.pos += 1;
                self.column += 1;
            }
        }
        if depth > 0 {
            return Err(LexerError::UnterminatedComment);
        }
        Ok(())
    }

    // --- 数字 ---

    /// 扫描数字字面量，自动识别二/八/十六进制前缀、小数点、指数与类型后缀
    fn scan_number(&mut self, start: usize, start_line: u32, start_col: u32) -> Result<Option<Token<'a>>, LexerError> {
        if self.bytes[start] == b'0' && self.pos < self.bytes.len() {
            let prefix = self.bytes[self.pos];
            if prefix == b'x' || prefix == b'X' {
                self.pos += 1;
                self.column += 1;
                return self.scan_hex_number(start, start_line, start_col);
            } else if prefix == b'o' || prefix == b'O' {
                self.pos += 1;
                self.column += 1;
                return self.scan_octal_number(start, start_line, start_col);
            } else if prefix == b'b' || prefix == b'B' {
                self.pos += 1;
                self.column += 1;
                return self.scan_binary_number(start, start_line, start_col);
            }
        }
        while self.pos < self.bytes.len() && is_digit(self.bytes[self.pos]) {
            self.pos += 1;
            self.column += 1;
        }
        self.skip_underscore_digits(false);
        let mut is_float = false;
        // 小数部分
        if self.pos < self.bytes.len() && self.bytes[self.pos] == b'.'
            && self.pos + 1 < self.bytes.len() && is_digit(self.bytes[self.pos + 1])
        {
            is_float = true;
            self.pos += 1;
            self.column += 1;
            while self.pos < self.bytes.len() && is_digit(self.bytes[self.pos]) {
                self.pos += 1;
                self.column += 1;
            }
            self.skip_underscore_digits(false);
        }
        // 指数部分
        if self.pos < self.bytes.len() && (self.bytes[self.pos] == b'e' || self.bytes[self.pos] == b'E') {
            is_float = true;
            self.pos += 1;
            self.column += 1;
            if self.pos < self.bytes.len() && (self.bytes[self.pos] == b'+' || self.bytes[self.pos] == b'-') {
                self.pos += 1;
                self.column += 1;
            }
            if self.pos < self.bytes.len() && is_digit(self.bytes[self.pos]) {
                while self.pos < self.bytes.len() && is_digit(self.bytes[self.pos]) {
                    self.pos += 1;
                    self.column += 1;
                }
            } else {
                return Err(LexerError::InvalidNumber);
            }
        }
        // 类型后缀（如 i32、f64），非法后缀则回退
        if self.pos < self.bytes.len() && is_identifier_start(self.bytes[self.pos]) {
            let suffix_start = self.pos;
            while self.pos < self.bytes.len() && is_identifier_continue(self.bytes[self.pos]) {
                self.pos += 1;
                self.column += 1;
            }
            let suffix = &self.source[suffix_start..self.pos];
            if is_float_suffix(suffix) {
                is_float = true;
            } else if !is_int_suffix(suffix) {
                let backtrack = self.pos - suffix_start;
                self.pos = suffix_start;
                self.column = self.column.saturating_sub(backtrack as u32);
            }
        }
        let kind = if is_float { TokenKind::FloatLiteral } else { TokenKind::IntLiteral };
        Ok(Some(self.make_token(kind, start, start_line, start_col)))
    }

    /// 跳过数字中的下划线分隔符（如 1_000），`hex` 控制是否按十六进制判断
    fn skip_underscore_digits(&mut self, hex: bool) {
        while self.pos < self.bytes.len() {
            if self.bytes[self.pos] == b'_' && self.pos + 1 < self.bytes.len() {
                let next = self.bytes[self.pos + 1];
                let valid = if hex { is_hex_digit(next) } else { is_digit(next) };
                if valid {
                    self.pos += 1;
                    self.column += 1;
                    self.pos += 1;
                    self.column += 1;
                    while self.pos < self.bytes.len() {
                        let ch = self.bytes[self.pos];
                        let ok = if hex { is_hex_digit(ch) } else { is_digit(ch) };
                        if !ok {
                            break;
                        }
                        self.pos += 1;
                        self.column += 1;
                    }
                } else {
                    break;
                }
            } else {
                break;
            }
        }
    }

    /// 扫描以点号开头的浮点数（如 .5）
    fn scan_dot_float(&mut self, start: usize, start_line: u32, start_col: u32) -> Result<Option<Token<'a>>, LexerError> {
        while self.pos < self.bytes.len() && is_digit(self.bytes[self.pos]) {
            self.pos += 1;
            self.column += 1;
        }
        self.skip_underscore_digits(false);
        if self.pos < self.bytes.len() && (self.bytes[self.pos] == b'e' || self.bytes[self.pos] == b'E') {
            self.pos += 1;
            self.column += 1;
            if self.pos < self.bytes.len() && (self.bytes[self.pos] == b'+' || self.bytes[self.pos] == b'-') {
                self.pos += 1;
                self.column += 1;
            }
            if self.pos < self.bytes.len() && is_digit(self.bytes[self.pos]) {
                while self.pos < self.bytes.len() && is_digit(self.bytes[self.pos]) {
                    self.pos += 1;
                    self.column += 1;
                }
            } else {
                return Err(LexerError::InvalidNumber);
            }
        }
        // .浮点数 仅允许浮点类型后缀，非法后缀则回退
        if self.pos < self.bytes.len() && is_identifier_start(self.bytes[self.pos]) {
            let suffix_start = self.pos;
            while self.pos < self.bytes.len() && is_identifier_continue(self.bytes[self.pos]) {
                self.pos += 1;
                self.column += 1;
            }
            let suffix = &self.source[suffix_start..self.pos];
            if !is_float_suffix(suffix) {
                let backtrack = self.pos - suffix_start;
                self.pos = suffix_start;
                self.column = self.column.saturating_sub(backtrack as u32);
            }
        }
        Ok(Some(self.make_token(TokenKind::FloatLiteral, start, start_line, start_col)))
    }

    /// 扫描十六进制数字字面量（0x 前缀），支持十六进制小数与 p 指数
    fn scan_hex_number(&mut self, start: usize, start_line: u32, start_col: u32) -> Result<Option<Token<'a>>, LexerError> {
        let mut has_digits = false;
        while self.pos < self.bytes.len() && is_hex_digit(self.bytes[self.pos]) {
            has_digits = true;
            self.pos += 1;
            self.column += 1;
        }
        self.skip_underscore_digits(true);
        let mut is_float = false;
        if self.pos < self.bytes.len() && self.bytes[self.pos] == b'.'
            && self.pos + 1 < self.bytes.len()
            && (is_hex_digit(self.bytes[self.pos + 1])
                || self.bytes[self.pos + 1] == b'p'
                || self.bytes[self.pos + 1] == b'P')
        {
            is_float = true;
            self.pos += 1;
            self.column += 1;
            while self.pos < self.bytes.len() && is_hex_digit(self.bytes[self.pos]) {
                self.pos += 1;
                self.column += 1;
            }
            self.skip_underscore_digits(true);
        }
        if self.pos < self.bytes.len() && (self.bytes[self.pos] == b'p' || self.bytes[self.pos] == b'P') {
            is_float = true;
            self.pos += 1;
            self.column += 1;
            if self.pos < self.bytes.len() && (self.bytes[self.pos] == b'+' || self.bytes[self.pos] == b'-') {
                self.pos += 1;
                self.column += 1;
            }
            if self.pos < self.bytes.len() && is_digit(self.bytes[self.pos]) {
                while self.pos < self.bytes.len() && is_digit(self.bytes[self.pos]) {
                    self.pos += 1;
                    self.column += 1;
                }
            } else {
                return Err(LexerError::InvalidNumber);
            }
        }
        if !has_digits {
            return Err(LexerError::InvalidHexDigit);
        }
        // 类型后缀，非法则回退
        if self.pos < self.bytes.len() && is_identifier_start(self.bytes[self.pos]) {
            let suffix_start = self.pos;
            while self.pos < self.bytes.len() && is_identifier_continue(self.bytes[self.pos]) {
                self.pos += 1;
                self.column += 1;
            }
            let suffix = &self.source[suffix_start..self.pos];
            if !is_int_suffix(suffix) && !is_float_suffix(suffix) {
                let backtrack = self.pos - suffix_start;
                self.pos = suffix_start;
                self.column = self.column.saturating_sub(backtrack as u32);
            }
        }
        let kind = if is_float { TokenKind::FloatLiteral } else { TokenKind::IntLiteral };
        Ok(Some(self.make_token(kind, start, start_line, start_col)))
    }

    /// 扫描八进制数字字面量（0o 前缀）
    fn scan_octal_number(&mut self, start: usize, start_line: u32, start_col: u32) -> Result<Option<Token<'a>>, LexerError> {
        let mut has_digits = false;
        while self.pos < self.bytes.len() && is_octal_digit(self.bytes[self.pos]) {
            has_digits = true;
            self.pos += 1;
            self.column += 1;
        }
        while self.pos < self.bytes.len() {
            if self.bytes[self.pos] == b'_'
                && self.pos + 1 < self.bytes.len()
                && is_octal_digit(self.bytes[self.pos + 1])
            {
                has_digits = true;
                self.pos += 1;
                self.column += 1;
                self.pos += 1;
                self.column += 1;
                while self.pos < self.bytes.len() && is_octal_digit(self.bytes[self.pos]) {
                    self.pos += 1;
                    self.column += 1;
                }
            } else {
                break;
            }
        }
        if !has_digits {
            return Err(LexerError::InvalidOctalDigit);
        }
        // 仅允许整数类型后缀，非法则回退
        if self.pos < self.bytes.len() && is_identifier_start(self.bytes[self.pos]) {
            let suffix_start = self.pos;
            while self.pos < self.bytes.len() && is_identifier_continue(self.bytes[self.pos]) {
                self.pos += 1;
                self.column += 1;
            }
            let suffix = &self.source[suffix_start..self.pos];
            if !is_int_suffix(suffix) {
                let backtrack = self.pos - suffix_start;
                self.pos = suffix_start;
                self.column = self.column.saturating_sub(backtrack as u32);
            }
        }
        Ok(Some(self.make_token(TokenKind::IntLiteral, start, start_line, start_col)))
    }

    /// 扫描二进制数字字面量（0b 前缀）
    fn scan_binary_number(&mut self, start: usize, start_line: u32, start_col: u32) -> Result<Option<Token<'a>>, LexerError> {
        let mut has_digits = false;
        while self.pos < self.bytes.len() && is_binary_digit(self.bytes[self.pos]) {
            has_digits = true;
            self.pos += 1;
            self.column += 1;
        }
        while self.pos < self.bytes.len() {
            if self.bytes[self.pos] == b'_'
                && self.pos + 1 < self.bytes.len()
                && is_binary_digit(self.bytes[self.pos + 1])
            {
                has_digits = true;
                self.pos += 1;
                self.column += 1;
                self.pos += 1;
                self.column += 1;
                while self.pos < self.bytes.len() && is_binary_digit(self.bytes[self.pos]) {
                    self.pos += 1;
                    self.column += 1;
                }
            } else {
                break;
            }
        }
        if !has_digits {
            return Err(LexerError::InvalidBinaryDigit);
        }
        if self.pos < self.bytes.len() && is_identifier_start(self.bytes[self.pos]) {
            let suffix_start = self.pos;
            while self.pos < self.bytes.len() && is_identifier_continue(self.bytes[self.pos]) {
                self.pos += 1;
                self.column += 1;
            }
            let suffix = &self.source[suffix_start..self.pos];
            if !is_int_suffix(suffix) {
                let backtrack = self.pos - suffix_start;
                self.pos = suffix_start;
                self.column = self.column.saturating_sub(backtrack as u32);
            }
        }
        Ok(Some(self.make_token(TokenKind::IntLiteral, start, start_line, start_col)))
    }

    // --- 字符 ---

    /// 扫描字符字面量（'x'），支持转义与 Unicode 转义 \u{...}
    fn scan_char(&mut self, start: usize, start_line: u32, start_col: u32) -> Result<Option<Token<'a>>, LexerError> {
        if self.pos >= self.bytes.len() {
            return Err(LexerError::UnterminatedChar);
        }
        if self.bytes[self.pos] == b'\\' {
            self.pos += 1;
            self.column += 1;
            if self.pos >= self.bytes.len() {
                return Err(LexerError::UnterminatedChar);
            }
            let escaped = self.bytes[self.pos];
            match escaped {
                b'n' | b't' | b'r' | b'\\' | b'\'' | b'0' => {
                    self.pos += 1;
                    self.column += 1;
                }
                b'u' => {
                    self.pos += 1;
                    self.column += 1;
                    if self.pos >= self.bytes.len() || self.bytes[self.pos] != b'{' {
                        return Err(LexerError::InvalidUnicodeEscape);
                    }
                    self.pos += 1;
                    self.column += 1;
                    let mut digit_count: usize = 0;
                    while self.pos < self.bytes.len() && self.bytes[self.pos] != b'}' {
                        if !is_hex_digit(self.bytes[self.pos]) {
                            return Err(LexerError::InvalidUnicodeEscape);
                        }
                        self.pos += 1;
                        self.column += 1;
                        digit_count += 1;
                    }
                    if digit_count == 0 || self.pos >= self.bytes.len() {
                        return Err(LexerError::InvalidUnicodeEscape);
                    }
                    self.pos += 1;
                    self.column += 1;
                }
                _ => {
                    return Err(LexerError::InvalidEscape);
                }
            }
        } else {
            self.pos += 1;
            self.column += 1;
        }
        if self.pos >= self.bytes.len() || self.bytes[self.pos] != b'\'' {
            return Err(LexerError::UnterminatedChar);
        }
        self.pos += 1;
        self.column += 1;
        Ok(Some(self.make_token(TokenKind::CharLiteral, start, start_line, start_col)))
    }

    // --- 字符串 ---

    /// 扫描字符串字面量，支持转义、`{{` `}}` 字面花括号与 `{表达式}` 插值。
    ///
    /// 整个字符串字面量（含插值部分）被作为单个 `StringLiteral` Token，
    /// lexeme 包含原始文本。字符串中不允许裸换行。
    fn scan_string(&mut self, start: usize, start_line: u32, start_col: u32) -> Result<Option<Token<'a>>, LexerError> {
        while self.pos < self.bytes.len() {
            let ch = self.bytes[self.pos];
            if ch == b'"' {
                self.pos += 1;
                self.column += 1;
                return Ok(Some(self.make_token(TokenKind::StringLiteral, start, start_line, start_col)));
            }
            if ch == b'\\' {
                self.pos += 1;
                self.column += 1;
                if self.pos >= self.bytes.len() {
                    return Err(LexerError::UnterminatedString);
                }
                let escaped = self.bytes[self.pos];
                match escaped {
                    b'"' | b'\\' | b'n' | b't' | b'r' | b'{' | b'}' => {
                        self.pos += 1;
                        self.column += 1;
                    }
                    _ => {
                        return Err(LexerError::InvalidEscape);
                    }
                }
            } else if ch == b'{' {
                // {{ 表示字面 {，否则进入插值表达式扫描
                if self.pos + 1 < self.bytes.len() && self.bytes[self.pos + 1] == b'{' {
                    self.pos += 2;
                    self.column += 2;
                } else {
                    self.pos += 1;
                    self.column += 1;
                    let mut brace_depth: u32 = 1;
                    while self.pos < self.bytes.len() && brace_depth > 0 {
                        let inner = self.bytes[self.pos];
                        if inner == b'\\' {
                            self.pos += 1;
                            self.column += 1;
                            if self.pos < self.bytes.len() {
                                self.pos += 1;
                                self.column += 1;
                            }
                            continue;
                        } else if inner == b'{' {
                            brace_depth += 1;
                        } else if inner == b'}' {
                            brace_depth -= 1;
                        } else if inner == b'"' {
                            // 插值表达式中嵌套的字符串字面量
                            self.pos += 1;
                            self.column += 1;
                            while self.pos < self.bytes.len() && self.bytes[self.pos] != b'"' {
                                if self.bytes[self.pos] == b'\\' {
                                    self.pos += 1;
                                    self.column += 1;
                                    if self.pos < self.bytes.len() {
                                        self.pos += 1;
                                        self.column += 1;
                                    }
                                } else {
                                    if self.bytes[self.pos] == b'\n' {
                                        self.line += 1;
                                        self.column = 1;
                                    } else {
                                        self.column += 1;
                                    }
                                    self.pos += 1;
                                }
                            }
                            if self.pos < self.bytes.len() {
                                self.pos += 1;
                                self.column += 1;
                            }
                            continue;
                        }
                        if inner == b'\n' {
                            self.line += 1;
                            self.column = 1;
                        } else {
                            self.column += 1;
                        }
                        self.pos += 1;
                    }
                }
            } else if ch == b'}' {
                // }} 表示字面 }
                if self.pos + 1 < self.bytes.len() && self.bytes[self.pos + 1] == b'}' {
                    self.pos += 2;
                    self.column += 2;
                } else {
                    self.pos += 1;
                    self.column += 1;
                }
            } else if ch == b'\n' {
                return Err(LexerError::UnterminatedString);
            } else {
                self.pos += 1;
                self.column += 1;
            }
        }
        Err(LexerError::UnterminatedString)
    }

    /// 扫描原始块 #{ ... }#：逐字符扫描直到匹配 }#，lexeme 为内部内容（不含 #{ 和 }#）。
    fn scan_raw_block(&mut self, start: usize, start_line: u32, start_col: u32) -> Result<Option<Token<'a>>, LexerError> {
        let content_start = self.pos;
        while self.pos < self.bytes.len() {
            let ch = self.bytes[self.pos];
            if ch == b'}' && self.pos + 1 < self.bytes.len() && self.bytes[self.pos + 1] == b'#' {
                let content = &self.source[content_start..self.pos];
                self.pos += 2;
                self.column += 2;
                // 生成一个 Token，lexeme 为内部内容
                // 注意：make_token 用 start..self.pos 会包含 #{ 和 }#，我们需要手动构造
                let _ = start;
                return Ok(Some(Token {
                    kind: TokenKind::RawBlock,
                    lexeme: content,
                    line: start_line,
                    column: start_col,
                }));
            }
            if ch == b'\n' {
                self.pos += 1;
                self.line += 1;
                self.column = 1;
            } else {
                self.pos += 1;
                self.column += 1;
            }
        }
        Err(LexerError::UnterminatedString)
    }

    // --- 标识符 ---

    /// 扫描标识符或关键字，通过关键字表判定最终 Token 类型
    fn scan_identifier(&mut self, start: usize, start_line: u32, start_col: u32) -> Result<Option<Token<'a>>, LexerError> {
        while self.pos < self.bytes.len() && is_identifier_continue(self.bytes[self.pos]) {
            self.pos += 1;
            self.column += 1;
        }
        let text = &self.source[start..self.pos];
        let kind = keyword_type(text);
        Ok(Some(self.make_token(kind, start, start_line, start_col)))
    }
}

// =========================================================================
// 辅助函数
// =========================================================================

/// 判断是否为十进制数字
fn is_digit(ch: u8) -> bool {
    ch.is_ascii_digit()
}

/// 判断是否为十六进制数字
fn is_hex_digit(ch: u8) -> bool {
    ch.is_ascii_hexdigit()
}

/// 判断是否为八进制数字
fn is_octal_digit(ch: u8) -> bool {
    (b'0'..=b'7').contains(&ch)
}

/// 判断是否为二进制数字
fn is_binary_digit(ch: u8) -> bool {
    ch == b'0' || ch == b'1'
}

/// 判断字符是否可作为标识符首字符（仅 ASCII）
fn is_identifier_start(ch: u8) -> bool {
    ch.is_ascii_alphabetic() || ch == b'_'
}

/// 判断字符是否可作为标识符后续字符（仅 ASCII）
fn is_identifier_continue(ch: u8) -> bool {
    is_identifier_start(ch) || is_digit(ch)
}

/// 查询文本是否为关键字，否则返回 `Identifier`
fn keyword_type(text: &str) -> TokenKind {
    match text {
        "fun" => TokenKind::KwFun,
        "type" => TokenKind::KwType,
        "trait" => TokenKind::KwTrait,
        "override" => TokenKind::KwOverride,
        "pack" => TokenKind::KwPack,
        "pub" => TokenKind::KwPub,
        "import" => TokenKind::KwImport,
        "with" => TokenKind::KwWith,
        "as" => TokenKind::KwAs,
        "val" => TokenKind::KwVal,
        "var" => TokenKind::KwVar,
        "match" => TokenKind::KwMatch,
        "if" => TokenKind::KwIf,
        "else" => TokenKind::KwElse,
        "async" => TokenKind::KwAsync,
        "channel" => TokenKind::KwChannel,
        "select" => TokenKind::KwSelect,
        "atomic" => TokenKind::KwAtomic,
        "loop" => TokenKind::KwLoop,
        "for" => TokenKind::KwFor,
        "in" => TokenKind::KwIn,
        "while" => TokenKind::KwWhile,
        "break" => TokenKind::KwBreak,
        "continue" => TokenKind::KwContinue,
        "return" => TokenKind::KwReturn,
        "throw" => TokenKind::KwThrow,
        "lazy" => TokenKind::KwLazy,
        "defer" => TokenKind::KwDefer,
        "true" => TokenKind::TrueLiteral,
        "false" => TokenKind::FalseLiteral,
        "null" => TokenKind::NullLiteral,
        _ => TokenKind::Identifier,
    }
}

/// 判断后缀是否为合法整数类型后缀
fn is_int_suffix(suffix: &str) -> bool {
    matches!(
        suffix,
        "i8" | "i16" | "i32" | "i64" | "i128" | "u8" | "u16" | "u32" | "u64" | "u128" | "isize" | "usize"
    )
}

/// 判断后缀是否为合法浮点类型后缀
fn is_float_suffix(suffix: &str) -> bool {
    matches!(suffix, "f16" | "f32" | "f64" | "f128")
}

// =========================================================================
// 测试
// =========================================================================

#[cfg(test)]
mod lexer_tests {
    use super::*;

    fn tokenize(src: &str) -> Vec<Token<'_>> {
        let mut lexer = Lexer::new(src);
        let mut sink = TokenCollector::new();
        lexer.tokenize_into(&mut sink);
        sink.into_tokens()
    }

    fn kinds(src: &str) -> Vec<TokenKind> {
        tokenize(src).into_iter().map(|t| t.kind).collect()
    }

    fn lexemes(src: &str) -> Vec<&str> {
        tokenize(src).into_iter().map(|t| t.lexeme).collect()
    }

    #[test]
    fn test_keywords_and_literals() {
        assert_eq!(
            kinds("fun type trait override pack pub import with as val var"),
            vec![
                TokenKind::KwFun,
                TokenKind::KwType,
                TokenKind::KwTrait,
                TokenKind::KwOverride,
                TokenKind::KwPack,
                TokenKind::KwPub,
                TokenKind::KwImport,
                TokenKind::KwWith,
                TokenKind::KwAs,
                TokenKind::KwVal,
                TokenKind::KwVar,
                TokenKind::Eof,
            ]
        );
        assert_eq!(
            kinds("match if else async channel select atomic loop for in while break continue"),
            vec![
                TokenKind::KwMatch,
                TokenKind::KwIf,
                TokenKind::KwElse,
                TokenKind::KwAsync,
                TokenKind::KwChannel,
                TokenKind::KwSelect,
                TokenKind::KwAtomic,
                TokenKind::KwLoop,
                TokenKind::KwFor,
                TokenKind::KwIn,
                TokenKind::KwWhile,
                TokenKind::KwBreak,
                TokenKind::KwContinue,
                TokenKind::Eof,
            ]
        );
        assert_eq!(
            kinds("return throw lazy defer true false null"),
            vec![
                TokenKind::KwReturn,
                TokenKind::KwThrow,
                TokenKind::KwLazy,
                TokenKind::KwDefer,
                TokenKind::TrueLiteral,
                TokenKind::FalseLiteral,
                TokenKind::NullLiteral,
                TokenKind::Eof,
            ]
        );
    }

    #[test]
    fn test_identifiers() {
        assert_eq!(
            kinds("foo bar_baz _x _123 ABC"),
            vec![
                TokenKind::Identifier,
                TokenKind::Identifier,
                TokenKind::Identifier,
                TokenKind::Identifier,
                TokenKind::Identifier,
                TokenKind::Eof,
            ]
        );
        assert_eq!(lexemes("foo bar_baz"), vec!["foo", "bar_baz", ""]);
    }

    #[test]
    fn test_integer_literals() {
        assert_eq!(
            kinds("42 0 1_000 0x1F 0o17 0b1010"),
            vec![
                TokenKind::IntLiteral,
                TokenKind::IntLiteral,
                TokenKind::IntLiteral,
                TokenKind::IntLiteral,
                TokenKind::IntLiteral,
                TokenKind::IntLiteral,
                TokenKind::Eof,
            ]
        );
        assert_eq!(lexemes("42 1_000 0x1F 0o17 0b1010"), vec!["42", "1_000", "0x1F", "0o17", "0b1010", ""]);
    }

    #[test]
    fn test_integer_suffix() {
        assert_eq!(
            kinds("42i32 100u64 0xFFu8"),
            vec![TokenKind::IntLiteral, TokenKind::IntLiteral, TokenKind::IntLiteral, TokenKind::Eof]
        );
        assert_eq!(lexemes("42i32 100u64"), vec!["42i32", "100u64", ""]);
    }

    #[test]
    fn test_underscore_prefixed_suffix_fallback() {
        // 下划线开头的后缀（如 _u8）不是合法类型后缀，回退为标识符
        assert_eq!(
            kinds("0xFF_u8"),
            vec![TokenKind::IntLiteral, TokenKind::Identifier, TokenKind::Eof]
        );
        assert_eq!(lexemes("0xFF_u8"), vec!["0xFF", "_u8", ""]);
    }

    #[test]
    fn test_invalid_suffix_fallback() {
        // 非法后缀回退：42 后 abc 不是合法类型后缀，回退为标识符
        assert_eq!(
            kinds("42abc"),
            vec![TokenKind::IntLiteral, TokenKind::Identifier, TokenKind::Eof]
        );
        assert_eq!(lexemes("42abc"), vec!["42", "abc", ""]);
    }

    #[test]
    #[allow(clippy::approx_constant)]
    fn test_float_literals() {
        assert_eq!(
            kinds("3.14 1e10 .5 1.5e-3 0x1p4 1.0f64"),
            vec![
                TokenKind::FloatLiteral,
                TokenKind::FloatLiteral,
                TokenKind::FloatLiteral,
                TokenKind::FloatLiteral,
                TokenKind::FloatLiteral,
                TokenKind::FloatLiteral,
                TokenKind::Eof,
            ]
        );
        assert_eq!(lexemes("3.14 .5 1.5e-3"), vec!["3.14", ".5", "1.5e-3", ""]);
    }

    #[test]
    fn test_float_suffix_forces_float() {
        // 即使没有小数点，浮点后缀也强制为浮点
        assert_eq!(kinds("10f64"), vec![TokenKind::FloatLiteral, TokenKind::Eof]);
    }

    #[test]
    fn test_dot_float_invalid_suffix_fallback() {
        // .5abc：abc 非浮点后缀，回退为标识符
        assert_eq!(
            kinds(".5abc"),
            vec![TokenKind::FloatLiteral, TokenKind::Identifier, TokenKind::Eof]
        );
        assert_eq!(lexemes(".5abc"), vec![".5", "abc", ""]);
    }

    #[test]
    fn test_char_literals() {
        assert_eq!(
            kinds("'a' '\\n' '\\'' '\\\\' '\\0' '\\u{1F600}'"),
            vec![
                TokenKind::CharLiteral,
                TokenKind::CharLiteral,
                TokenKind::CharLiteral,
                TokenKind::CharLiteral,
                TokenKind::CharLiteral,
                TokenKind::CharLiteral,
                TokenKind::Eof,
            ]
        );
        assert_eq!(lexemes("'a' '\\u{1F600}'"), vec!["'a'", "'\\u{1F600}'", ""]);
    }

    #[test]
    fn test_string_literal_basic() {
        assert_eq!(kinds("\"hello\""), vec![TokenKind::StringLiteral, TokenKind::Eof]);
        assert_eq!(lexemes("\"hello\""), vec!["\"hello\"", ""]);
    }

    #[test]
    fn test_string_literal_braces() {
        // {{ 与 }} 表示字面花括号，仍是单个字符串 Token
        assert_eq!(kinds("\"{{x}}\""), vec![TokenKind::StringLiteral, TokenKind::Eof]);
        assert_eq!(lexemes("\"{{x}}\""), vec!["\"{{x}}\"", ""]);
    }

    #[test]
    fn test_string_interpolation() {
        // {1+2} 插值表达式，整个字符串作为单个 Token
        assert_eq!(kinds("\"a{1+2}b\""), vec![TokenKind::StringLiteral, TokenKind::Eof]);
        assert_eq!(lexemes("\"a{1+2}b\""), vec!["\"a{1+2}b\"", ""]);
    }

    #[test]
    fn test_string_interpolation_nested_braces() {
        // 嵌套花括号
        assert_eq!(kinds("\"a{f({x:1})}b\""), vec![TokenKind::StringLiteral, TokenKind::Eof]);
        assert_eq!(lexemes("\"a{f({x:1})}b\""), vec!["\"a{f({x:1})}b\"", ""]);
    }

    #[test]
    fn test_string_interpolation_nested_string() {
        // 插值表达式中嵌套字符串字面量（转义形式：\" 走转义分支）
        assert_eq!(kinds("\"a{\\\"x\\\"}b\""), vec![TokenKind::StringLiteral, TokenKind::Eof]);
        assert_eq!(lexemes("\"a{\\\"x\\\"}b\""), vec!["\"a{\\\"x\\\"}b\"", ""]);
        // 插值表达式中嵌套裸字符串字面量（走嵌套字符串扫描分支）
        assert_eq!(kinds("\"a{\"x\"}b\""), vec![TokenKind::StringLiteral, TokenKind::Eof]);
        assert_eq!(lexemes("\"a{\"x\"}b\""), vec!["\"a{\"x\"}b\"", ""]);
    }

    #[test]
    fn test_string_escapes() {
        assert_eq!(
            kinds("\"a\\nb\\tc\\\\d\\\"e\\{f\\}g\""),
            vec![TokenKind::StringLiteral, TokenKind::Eof]
        );
    }

    #[test]
    fn test_line_comment() {
        assert_eq!(kinds("// comment\n42"), vec![TokenKind::IntLiteral, TokenKind::Eof]);
        assert_eq!(kinds("42 // trailing"), vec![TokenKind::IntLiteral, TokenKind::Eof]);
    }

    #[test]
    fn test_block_comment() {
        assert_eq!(kinds("/* x */ 42"), vec![TokenKind::IntLiteral, TokenKind::Eof]);
        // 嵌套块注释
        assert_eq!(kinds("/* /* */ */ 42"), vec![TokenKind::IntLiteral, TokenKind::Eof]);
    }

    #[test]
    fn test_semicolon_skipped() {
        // 分号被当作空白字符跳过，不产生 Token
        assert_eq!(kinds("42;"), vec![TokenKind::IntLiteral, TokenKind::Eof]);
        assert_eq!(kinds("a;b;c"), vec![TokenKind::Identifier, TokenKind::Identifier, TokenKind::Identifier, TokenKind::Eof]);
    }

    #[test]
    fn test_operators() {
        let cases: &[(&str, TokenKind)] = &[
            ("+", TokenKind::Plus),
            ("-", TokenKind::Minus),
            ("*", TokenKind::Star),
            ("/", TokenKind::Slash),
            ("%", TokenKind::Percent),
            ("==", TokenKind::EqEq),
            ("!=", TokenKind::BangEq),
            ("===", TokenKind::RefEq),
            ("!==", TokenKind::RefNeq),
            ("<", TokenKind::Lt),
            (">", TokenKind::Gt),
            ("<=", TokenKind::LtEq),
            (">=", TokenKind::GtEq),
            ("<-", TokenKind::LtMinus),
            ("&&", TokenKind::AmpAmp),
            ("||", TokenKind::PipePipe),
            ("!", TokenKind::Bang),
            ("&", TokenKind::Ampersand),
            ("^", TokenKind::Caret),
            ("?.", TokenKind::QuestionDot),
            ("??", TokenKind::QuestionQuestion),
            ("?", TokenKind::Question),
            ("..", TokenKind::DotDot),
            ("..=", TokenKind::DotDotEq),
            ("...", TokenKind::Ellipsis),
            ("=", TokenKind::Eq),
            ("+=", TokenKind::PlusEq),
            ("++", TokenKind::PlusPlus),
            ("-=", TokenKind::MinusEq),
            ("*=", TokenKind::StarEq),
            ("/=", TokenKind::SlashEq),
            ("%=", TokenKind::PercentEq),
            ("&=", TokenKind::AmpEq),
            ("|=", TokenKind::PipeEq),
            ("^=", TokenKind::CaretEq),
            ("<<", TokenKind::LtLt),
            (">>", TokenKind::GtGt),
            ("<<=", TokenKind::LtLtEq),
            (">>=", TokenKind::GtGtEq),
            ("~", TokenKind::Tilde),
            ("=>", TokenKind::EqGt),
            ("->", TokenKind::MinusGt),
        ];
        for (input, expected) in cases {
            let toks = tokenize(input);
            assert_eq!(toks[0].kind, *expected, "input {:?}", input);
            assert_eq!(toks[1].kind, TokenKind::Eof, "input {:?}", input);
            assert_eq!(toks[0].lexeme, *input, "lexeme for {:?}", input);
        }
    }

    #[test]
    fn test_delimiters() {
        assert_eq!(
            kinds("( ) [ ] { } , : . |"),
            vec![
                TokenKind::LParen,
                TokenKind::RParen,
                TokenKind::LBracket,
                TokenKind::RBracket,
                TokenKind::LBrace,
                TokenKind::RBrace,
                TokenKind::Comma,
                TokenKind::Colon,
                TokenKind::Dot,
                TokenKind::Pipe,
                TokenKind::Eof,
            ]
        );
    }

    #[test]
    fn test_unexpected_character() {
        // 未知字符生成 Err Token，继续扫描
        let toks = tokenize("$");
        assert_eq!(toks[0].kind, TokenKind::Err);
        assert_eq!(toks[1].kind, TokenKind::Eof);
    }

    #[test]
    fn test_unterminated_string() {
        let toks = tokenize("\"abc");
        assert!(toks.iter().any(|t| t.kind == TokenKind::Err));
        assert_eq!(toks.last().unwrap().kind, TokenKind::Eof);
    }

    #[test]
    fn test_unterminated_char() {
        let toks = tokenize("'a");
        assert!(toks.iter().any(|t| t.kind == TokenKind::Err));
    }

    #[test]
    fn test_unterminated_block_comment() {
        let toks = tokenize("/* abc");
        assert!(toks.iter().any(|t| t.kind == TokenKind::Err));
    }

    #[test]
    fn test_newline_in_string_errors() {
        let toks = tokenize("\"a\nb\"");
        assert!(toks.iter().any(|t| t.kind == TokenKind::Err));
    }

    #[test]
    fn test_invalid_escape_errors() {
        let toks = tokenize("\"\\q\"");
        assert!(toks.iter().any(|t| t.kind == TokenKind::Err));
        let toks = tokenize("'\\q'");
        assert!(toks.iter().any(|t| t.kind == TokenKind::Err));
    }

    #[test]
    fn test_invalid_unicode_escape() {
        // \u{} 空内容
        let toks = tokenize("'\\u{}'");
        assert!(toks.iter().any(|t| t.kind == TokenKind::Err));
        // \u{GG} 非十六进制
        let toks = tokenize("'\\u{GG}'");
        assert!(toks.iter().any(|t| t.kind == TokenKind::Err));
    }

    #[test]
    fn test_invalid_hex_literal() {
        // 0x 后无数字
        let toks = tokenize("0x");
        assert!(toks.iter().any(|t| t.kind == TokenKind::Err));
    }

    #[test]
    fn test_invalid_exponent() {
        // 1e 后无数字
        let toks = tokenize("1e");
        assert!(toks.iter().any(|t| t.kind == TokenKind::Err));
    }

    #[test]
    fn test_positions() {
        let toks = tokenize("ab\ncd");
        assert_eq!(toks[0].kind, TokenKind::Identifier);
        assert_eq!(toks[0].lexeme, "ab");
        assert_eq!(toks[0].line, 1);
        assert_eq!(toks[0].column, 1);
        assert_eq!(toks[1].kind, TokenKind::Identifier);
        assert_eq!(toks[1].lexeme, "cd");
        assert_eq!(toks[1].line, 2);
        assert_eq!(toks[1].column, 1);
        assert_eq!(toks[2].kind, TokenKind::Eof);
    }

    #[test]
    fn test_empty_source() {
        let toks = tokenize("");
        assert_eq!(toks.len(), 1);
        assert_eq!(toks[0].kind, TokenKind::Eof);
    }

    #[test]
    fn test_whitespace_only() {
        let toks = tokenize("   \n\t  \n");
        assert_eq!(toks.len(), 1);
        assert_eq!(toks[0].kind, TokenKind::Eof);
        assert_eq!(toks[0].line, 3);
    }

    #[test]
    fn test_mixed_tokens() {
        let src = "val x = 42; fun f() { return x }";
        let toks = tokenize(src);
        let expected = vec![
            TokenKind::KwVal,
            TokenKind::Identifier,
            TokenKind::Eq,
            TokenKind::IntLiteral,
            TokenKind::KwFun,
            TokenKind::Identifier,
            TokenKind::LParen,
            TokenKind::RParen,
            TokenKind::LBrace,
            TokenKind::KwReturn,
            TokenKind::Identifier,
            TokenKind::RBrace,
            TokenKind::Eof,
        ];
        let actual: Vec<TokenKind> = toks.iter().map(|t| t.kind).collect();
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_error_recovery_continues() {
        // 错误后继续扫描，后续合法 Token 仍能被识别。
        // `1e` 是非法指数（缺数字），生成 Err 后 `+ 42` 仍被正常识别。
        let toks = tokenize("1e + 42");
        assert!(toks.iter().any(|t| t.kind == TokenKind::Err));
        assert!(toks.iter().any(|t| t.kind == TokenKind::Plus));
        assert!(toks.iter().any(|t| t.kind == TokenKind::IntLiteral));
        assert_eq!(toks.last().unwrap().kind, TokenKind::Eof);
    }

    #[test]
    fn test_no_infinite_loop_on_recovery() {
        // 确保错误恢复总能前进，不会死循环
        let toks = tokenize("$$$$");
        assert_eq!(toks.iter().filter(|t| t.kind == TokenKind::Err).count(), 4);
        assert_eq!(toks.last().unwrap().kind, TokenKind::Eof);
    }
}

// 递归下降语法分析器
//
// 将 Token 序列解析为 AST。核心特性：
// - 递归下降 + Pratt 优先级爬升（由 binary_op_table 驱动）
// - 虚拟 Token 拆分（`>>` → 两个 `>`，`>=` → `>` + `=`，`>>=` → `>` + `>=`）
// - 负数字面量折叠（`-42` → IntLit，非 Unary）
// - lambda 两种语法（`fun(params) body` 与 `(params) => expr`）
// - record literal vs record extend vs grouping 三路回溯
// - 字符串插值（复用 Parser 状态解析子表达式）
// - 错误恢复（synchronize 跳到声明边界）


use bumpalo::Bump;

// =========================================================================
// ParseError
// =========================================================================

/// 语法错误：携带源码位置与消息
#[derive(Debug, Clone)]
pub struct ParseError {
    pub line: u32,
    pub column: u32,
    pub message: String,
}

pub type ParseResult<T> = Result<T, ParseError>;

// =========================================================================
// ParseErrorHandler — 解析错误处理器 trait
// =========================================================================

/// 解析错误处理器 trait。Parser 在遇到错误时调用 hook，
/// 默认实现 `ErrorCollector` 收集到 `Vec<ParseError>`。
pub trait ParseErrorHandler {
    /// 记录一条语法错误，返回 ParseError 供传播
    fn on_error(&mut self, line: u32, column: u32, message: &str) -> ParseError;
    /// 错误恢复通知：Parser 在 `synchronize` 完成后调用
    fn on_recover(&mut self) {}
    /// 返回已收集的错误列表
    fn errors(&self) -> &[ParseError];
    /// 截断错误列表到指定长度（用于推测解析回退）
    fn truncate_errors(&mut self, len: usize);
}

/// 默认错误处理器：收集错误到 Vec，恢复时跳过到声明边界。
pub struct ErrorCollector {
    pub errors: Vec<ParseError>,
}

impl ErrorCollector {
    pub fn new() -> Self {
        Self { errors: Vec::new() }
    }
}

impl Default for ErrorCollector {
    fn default() -> Self {
        Self::new()
    }
}

impl ParseErrorHandler for ErrorCollector {
    fn on_error(&mut self, line: u32, column: u32, message: &str) -> ParseError {
        let err = ParseError {
            line,
            column,
            message: message.to_string(),
        };
        self.errors.push(err.clone());
        err
    }

    fn errors(&self) -> &[ParseError] {
        &self.errors
    }

    fn truncate_errors(&mut self, len: usize) {
        self.errors.truncate(len);
    }
}

// =========================================================================
// Parser
// =========================================================================

/// 递归下降语法分析器
pub struct Parser<'a, H: ParseErrorHandler> {
    tokens: &'a [Token<'a>],
    current: usize,
    /// bumpalo arena：仅用于分配动态构建的字符串（负数字面量、反转义、int_to_key）
    /// 与插值子表达式的 token 数组。AST 节点本身存储在 `ast` 中。
    arena: &'a Bump,
    /// AST 节点统一存储（替代节点级 bumpalo 分配）
    ast: AstArena<'a>,
    handler: H,
    /// 虚拟 Token 拆分：`>=` 拆为 `>` + `=`，消费 `>` 后设置 pending_eq
    pending_eq: bool,
    /// 虚拟 Token 拆分：`>>` 拆为 `>` + `>`，消费内层 `>` 后设置 pending_gt
    pending_gt: bool,
    /// 虚拟 Token 拆分：`>>=` 拆为 `>` + `>=`，消费内层 `>` 后设置 pending_gt_eq
    pending_gt_eq: bool,
}

// --- 解析辅助宏 ---

/// 生成逗号分隔列表解析方法：先解析一项，随后循环消费逗号直至遇到终止符。
/// `check($tk)` 以给定 TokenKind 为终止符；`check_close_angle` 以闭合尖括号为终止符。
macro_rules! impl_parse_comma_list {
    ($method:ident, $item:ty, $parse_fn:ident, check($tk:expr)) => {
        fn $method(&mut self, items: &mut Vec<$item>) -> ParseResult<()> {
            items.push(self.$parse_fn()?);
            while self.match_token(TokenKind::Comma) {
                if self.check($tk) {
                    break;
                }
                items.push(self.$parse_fn()?);
            }
            Ok(())
        }
    };
    ($method:ident, $item:ty, $parse_fn:ident, check_close_angle) => {
        fn $method(&mut self, items: &mut Vec<$item>) -> ParseResult<()> {
            items.push(self.$parse_fn()?);
            while self.match_token(TokenKind::Comma) {
                if self.check_close_angle() {
                    break;
                }
                items.push(self.$parse_fn()?);
            }
            Ok(())
        }
    };
}

impl<'a, H: ParseErrorHandler> Parser<'a, H> {
    /// 创建语法分析器，需显式传入错误处理器
    pub fn new(tokens: &'a [Token<'a>], arena: &'a Bump, handler: H) -> Self {
        Self {
            tokens,
            current: 0,
            arena,
            ast: AstArena::new(),
            handler,
            pending_eq: false,
            pending_gt: false,
            pending_gt_eq: false,
        }
    }

    /// 返回收集到的错误列表
    pub fn errors(&self) -> &[ParseError] {
        self.handler.errors()
    }

    // =====================================================================
    // Token 导航
    // =====================================================================

    /// 查看当前 Token（处理虚拟 Token 注入）
    fn peek(&self) -> Token<'a> {
        if self.pending_eq {
            let base = self.base_token();
            return Token { kind: TokenKind::Eq, lexeme: "=", line: base.line, column: base.column + 1 };
        }
        if self.pending_gt {
            let base = self.base_token();
            return Token { kind: TokenKind::Gt, lexeme: ">", line: base.line, column: base.column + 1 };
        }
        if self.pending_gt_eq {
            let base = self.base_token();
            return Token { kind: TokenKind::GtEq, lexeme: ">=", line: base.line, column: base.column + 1 };
        }
        if self.current >= self.tokens.len() {
            return self.tokens[self.tokens.len() - 1];
        }
        self.tokens[self.current]
    }

    /// 获取用于虚拟 Token 位置计算的基准 Token
    fn base_token(&self) -> Token<'a> {
        if self.current > 0 {
            self.tokens[self.current - 1]
        } else {
            self.tokens[0]
        }
    }

    /// 返回上一个已消费的 Token
    fn previous(&self) -> Token<'a> {
        debug_assert!(self.current > 0);
        self.tokens[self.current - 1]
    }

    /// 是否到达 Token 序列末尾
    fn is_at_end(&self) -> bool {
        self.peek().kind == TokenKind::Eof
    }

    /// 消费当前 Token 并前进（处理虚拟 Token 消费）
    fn advance(&mut self) -> Token<'a> {
        if self.pending_eq {
            self.pending_eq = false;
            let base = self.base_token();
            return Token { kind: TokenKind::Eq, lexeme: "=", line: base.line, column: base.column + 1 };
        }
        if self.pending_gt {
            self.pending_gt = false;
            let base = self.base_token();
            return Token { kind: TokenKind::Gt, lexeme: ">", line: base.line, column: base.column + 1 };
        }
        if self.pending_gt_eq {
            self.pending_gt_eq = false;
            let base = self.base_token();
            return Token { kind: TokenKind::GtEq, lexeme: ">=", line: base.line, column: base.column + 1 };
        }
        if !self.is_at_end() {
            self.current += 1;
        }
        self.tokens[self.current - 1]
    }

    /// 当前 Token 是否为指定类型
    fn check(&self, kind: TokenKind) -> bool {
        if self.is_at_end() {
            return false;
        }
        self.peek().kind == kind
    }

    /// 当当前 Token 匹配时消费并返回 true
    fn match_token(&mut self, kind: TokenKind) -> bool {
        if self.check(kind) {
            self.advance();
            return true;
        }
        false
    }

    /// 期望消费指定类型 Token，不匹配时记录错误并返回 Err
    fn expect(&mut self, kind: TokenKind, message: &str) -> ParseResult<Token<'a>> {
        if self.check(kind) {
            return Ok(self.advance());
        }
        let tok = self.peek();
        Err(self.report_error_at(tok.line, tok.column, message))
    }

    /// 当前 Token 是否为指定名称的标识符
    fn check_identifier(&self, name: &str) -> bool {
        self.peek().kind == TokenKind::Identifier && self.peek().lexeme == name
    }

    /// 检测当前位置是否为闭合泛型参数列表的 `>`（含虚拟拆分形态）
    fn check_close_angle(&self) -> bool {
        if self.pending_gt || self.pending_gt_eq {
            return true;
        }
        if self.current >= self.tokens.len() {
            return false;
        }
        matches!(
            self.tokens[self.current].kind,
            TokenKind::Gt | TokenKind::GtEq | TokenKind::GtGt | TokenKind::GtGtEq
        )
    }

    /// 期望消费关闭泛型参数的 `>`，支持虚拟拆分 `>=` / `>>` / `>>=`
    fn expect_close_angle(&mut self, message: &str) -> ParseResult<()> {
        if self.check(TokenKind::Gt) {
            self.advance();
            return Ok(());
        }
        if self.pending_gt_eq {
            self.pending_gt_eq = false;
            self.pending_eq = true;
            return Ok(());
        }
        if self.current < self.tokens.len() {
            match self.tokens[self.current].kind {
                TokenKind::GtEq => {
                    self.current += 1;
                    self.pending_eq = true;
                    return Ok(());
                }
                TokenKind::GtGt => {
                    self.current += 1;
                    self.pending_gt = true;
                    return Ok(());
                }
                TokenKind::GtGtEq => {
                    self.current += 1;
                    self.pending_gt_eq = true;
                    return Ok(());
                }
                _ => {}
            }
        }
        let tok = self.peek();
        Err(self.report_error_at(tok.line, tok.column, message))
    }

    // =====================================================================
    // 错误处理
    // =====================================================================

    /// 在指定位置记录一条语法错误，返回 ParseError 供传播
    fn report_error_at(&mut self, line: u32, column: u32, message: &str) -> ParseError {
        self.handler.on_error(line, column, message)
    }

    /// 在当前 Token 处记录一条语法错误
    fn report_error(&mut self, message: &str) -> ParseResult<()> {
        let tok = self.peek();
        Err(self.report_error_at(tok.line, tok.column, message))
    }

    /// 条件语句禁止使用括号
    fn reject_paren_condition(&mut self, kw_name: &str) -> ParseResult<()> {
        if self.check(TokenKind::LParen) {
            let msg = format!("{} 条件不允许使用括号", kw_name);
            self.report_error(&msg)?;
            unreachable!()
        }
        Ok(())
    }

    /// 错误恢复：跳过 Token 直到遇到声明起始或右大括号
    fn synchronize(&mut self) {
        while !self.is_at_end() {
            match self.peek().kind {
                TokenKind::KwFun
                | TokenKind::KwType
                | TokenKind::KwTrait
                | TokenKind::KwImport
                | TokenKind::KwPack
                | TokenKind::KwPub
                | TokenKind::KwVal
                | TokenKind::KwVar => break,
                TokenKind::RBrace => {
                    self.advance();
                    break;
                }
                _ => {
                    self.advance();
                }
            }
        }
        self.handler.on_recover();
    }

    // =====================================================================
    // AST 节点分配
    // =====================================================================

    fn alloc_expr(&mut self, span: Span, expr: Expr<'a>) -> ExprRef {
        self.ast.alloc_expr(span, expr)
    }

    fn alloc_stmt(&mut self, span: Span, stmt: Stmt<'a>) -> StmtRef {
        self.ast.alloc_stmt(span, stmt)
    }

    fn alloc_type(&mut self, span: Span, ty: TypeNode<'a>) -> TypeRef {
        self.ast.alloc_type(span, ty)
    }

    fn alloc_pattern(&mut self, span: Span, pat: Pattern<'a>) -> PatternRef {
        self.ast.alloc_pattern(span, pat)
    }

    fn spanned_decl(&self, span: Span, decl: Decl<'a>) -> Spanned<Decl<'a>> {
        Spanned { span, node: decl }
    }

    // =====================================================================
    // 模块解析
    // =====================================================================

    /// 解析整个模块
    pub fn parse_module(&mut self, module_name: &'a str) -> ParseResult<Module<'a>> {
        let mut declarations = Vec::new();
        while !self.is_at_end() {
            let at_decl_kw = matches!(
                self.peek().kind,
                TokenKind::KwFun
                    | TokenKind::KwType
                    | TokenKind::KwTrait
                    | TokenKind::KwImport
                    | TokenKind::KwPack
                    | TokenKind::KwPub
                    | TokenKind::At
            );
            if let Some(decl) = self.try_parse_decl() {
                declarations.push(decl);
                continue;
            }
            if at_decl_kw {
                self.synchronize();
                continue;
            }
            let before_expr = self.current;
            let expr = match self.parse_expr() {
                Ok(e) => e,
                Err(_) => {
                    self.synchronize();
                    continue;
                }
            };
            if self.current == before_expr {
                self.advance();
                continue;
            }
            let span = self.ast.expr(expr).span;
            if self.match_token(TokenKind::Eq) {
                let value = match self.parse_expr() {
                    Ok(v) => v,
                    Err(_) => {
                        self.synchronize();
                        continue;
                    }
                };
                let stmt = self.alloc_stmt(
                    span,
                    Stmt::Assignment {
                        target: expr,
                        value,
                    },
                );
                let void_expr = self.alloc_expr(span, Expr::VoidLit);
                declarations.push(self.spanned_decl(
                    span,
                    Decl::ExprDecl {
                        expr: void_expr,
                        stmt: Some(stmt),
                    },
                ));
            } else {
                declarations.push(self.spanned_decl(
                    span,
                    Decl::ExprDecl {
                        expr,
                        stmt: None,
                    },
                ));
            }
        }
        if !self.handler.errors().is_empty() {
            return Err(self.handler.errors()[0].clone());
        }
        Ok(Module {
            name: module_name,
            source_path: None,
            arena: std::mem::take(&mut self.ast),
            declarations,
        })
    }

    /// 解析 0..N 个属性前缀：@name 或 @name("arg") 或 @name "arg"
    fn parse_attributes(&mut self) -> Vec<Attribute<'a>> {
        let mut attrs = Vec::new();
        while self.check(TokenKind::At) {
            self.advance(); // @
            let name_tok = match self.expect(TokenKind::Identifier, "expected attribute name") {
                Ok(t) => t,
                Err(_) => break,
            };
            let mut args = Vec::new();
            if self.check(TokenKind::LParen) {
                self.advance(); // (
                while !self.check(TokenKind::RParen) && !self.is_at_end() {
                    if self.check(TokenKind::StringLiteral) {
                        let lex = self.advance().lexeme;
                        // 去掉首尾引号
                        if lex.len() >= 2 {
                            args.push(&lex[1..lex.len() - 1]);
                        } else {
                            args.push(lex);
                        }
                    } else if self.check(TokenKind::Identifier) {
                        args.push(self.advance().lexeme);
                    } else {
                        self.advance();
                    }
                    if self.check(TokenKind::Comma) {
                        self.advance();
                    }
                }
                let _ = self.expect(TokenKind::RParen, "expected ')' after attribute args");
            } else if self.check(TokenKind::StringLiteral) {
                let lex = self.advance().lexeme;
                if lex.len() >= 2 {
                    args.push(&lex[1..lex.len() - 1]);
                } else {
                    args.push(lex);
                }
            }
            attrs.push(Attribute { name: name_tok.lexeme, args });
        }
        attrs
    }

    /// 尝试解析顶层声明（容错版本，失败返回 None）
    fn try_parse_decl(&mut self) -> Option<Spanned<Decl<'a>>> {
        let saved = self.current;
        let attributes = self.parse_attributes();
        if !attributes.is_empty() && !self.check(TokenKind::KwPub) && !self.check(TokenKind::KwAsync) && !self.check(TokenKind::KwFun) {
            // 属性后必须跟 pub/async/fun
            self.current = saved;
            return None;
        }
        let mut visibility = Visibility::Private;
        if self.match_token(TokenKind::KwPub) {
            visibility = Visibility::Public;
        }
        let mut is_async = false;
        if self.match_token(TokenKind::KwAsync) {
            if !self.check(TokenKind::KwFun) {
                return None;
            }
            is_async = true;
        }
        if self.check(TokenKind::KwFun) {
            return self.parse_fun_decl(visibility, is_async, attributes).ok();
        }
        if self.check(TokenKind::KwType) {
            return self.parse_type_decl(visibility).ok();
        }
        if self.check(TokenKind::KwTrait) {
            return self.parse_trait_decl(visibility).ok();
        }
        if self.check(TokenKind::KwImport) {
            return self.parse_use_decl(visibility).ok();
        }
        if self.check(TokenKind::KwPack) {
            return self.parse_pack_decl(visibility).ok();
        }
        // pub val / pub var
        if visibility == Visibility::Public && (self.check(TokenKind::KwVal) || self.check(TokenKind::KwVar)) {
            if let Ok(stmt) = self.parse_stmt() {
                let stmt_spanned = self.ast.stmt(stmt);
                let mut s = stmt_spanned.node.clone();
                match &mut s {
                    Stmt::ValDecl { visibility: v, .. } => *v = visibility,
                    Stmt::VarDecl { visibility: v, .. } => *v = visibility,
                    _ => {}
                }
                let span = stmt_spanned.span;
                let stmt_ref = self.alloc_stmt(span, s);
                let dummy = self.alloc_expr(span, Expr::VoidLit);
                return Some(self.spanned_decl(
                    span,
                    Decl::ExprDecl {
                        expr: dummy,
                        stmt: Some(stmt_ref),
                    },
                ));
            }
            return None;
        }
        // 回退 pub
        if visibility == Visibility::Public {
            self.current = saved;
        }
        // 顶层语句
        if matches!(
            self.peek().kind,
            TokenKind::KwVal
                | TokenKind::KwVar
                | TokenKind::KwFor
                | TokenKind::KwWhile
                | TokenKind::KwLoop
                | TokenKind::KwDefer
                | TokenKind::KwThrow
                | TokenKind::KwReturn
        ) {
            if let Ok(stmt) = self.parse_stmt() {
                let span = self.ast.stmt(stmt).span;
                let dummy = self.alloc_expr(span, Expr::VoidLit);
                return Some(self.spanned_decl(
                    span,
                    Decl::ExprDecl {
                        expr: dummy,
                        stmt: Some(stmt),
                    },
                ));
            }
        }
        None
    }

    // =====================================================================
    // 声明解析
    // =====================================================================

    /// 解析函数声明：fun name<TParams>(params): ReturnType with bounds { body }
    fn parse_fun_decl(&mut self, visibility: Visibility, is_async: bool, attributes: Vec<Attribute<'a>>) -> ParseResult<Spanned<Decl<'a>>> {
        let fun_tok = self.advance(); // 'fun'
        let name_tok = self.expect(TokenKind::Identifier, "expected function name")?;
        let mut type_params = Vec::new();
        if self.match_token(TokenKind::Lt) {
            self.parse_type_param_list(&mut type_params)?;
            let _ = self.expect_close_angle("expected '>' to close type parameter list");
        }
        let mut params = Vec::new();
        let _ = self.expect(TokenKind::LParen, "expected '(' to start parameter list");
        if !self.check(TokenKind::RParen) {
            self.parse_param_list(&mut params)?;
        }
        let _ = self.expect(TokenKind::RParen, "expected ')' to close parameter list");
        let return_type = if self.match_token(TokenKind::Colon) {
            Some(self.parse_type()?)
        } else {
            return Err(self.report_error_at(
                name_tok.line,
                name_tok.column,
                "函数声明必须显式标注返回类型（无返回值请使用 ': void'）",
            ));
        };
        let mut bounds = Vec::new();
        if self.match_token(TokenKind::KwWith) {
            self.parse_trait_bound_list(&mut bounds)?;
        }
        let body = self.parse_expr()?;
        let extern_c_body = if self.check(TokenKind::RawBlock) {
            let tok = self.advance();
            Some(tok.lexeme)
        } else {
            None
        };
        Ok(self.spanned_decl(
            token_span(&fun_tok),
            Decl::FunDecl {
                visibility,
                name: name_tok.lexeme,
                type_params,
                params,
                return_type,
                bounds,
                body,
                is_async,
                is_entry: name_tok.lexeme == "main",
                attributes,
                extern_c_body,
            },
        ))
    }

    /// 解析类型声明：type Name<TParams> : traits = def with constraints { methods }
    fn parse_type_decl(&mut self, visibility: Visibility) -> ParseResult<Spanned<Decl<'a>>> {
        let type_tok = self.advance(); // 'type'
        let name_tok = self.expect(TokenKind::Identifier, "expected type name")?;
        let mut type_params = Vec::new();
        if self.match_token(TokenKind::Lt) {
            self.parse_type_param_list(&mut type_params)?;
            let _ = self.expect_close_angle("expected '>' to close type parameter list");
        }
        let mut implemented_traits = Vec::new();
        let mut has_error_trait = false;
        if self.match_token(TokenKind::Colon) {
            let has_paren = self.check(TokenKind::LParen);
            if has_paren {
                self.advance();
            }
            self.parse_trait_bound_list(&mut implemented_traits)?;
            if has_paren {
                let _ = self.expect(TokenKind::RParen, "expected ')' after trait list");
            }
            if implemented_traits.iter().any(|t| t.trait_name == "Err") {
                has_error_trait = true;
            }
        }
        let _ = self.expect(TokenKind::Eq, "expected '=' to define type body");
        let mut def = self.parse_type_def(has_error_trait)?;
        if let TypeDef::ErrorNewtype { name, .. } = &mut def {
            *name = name_tok.lexeme;
        }
        let mut type_constraints = Vec::new();
        if self.match_token(TokenKind::KwWith) {
            self.parse_type_constraints(&mut type_constraints)?;
        }
        let mut methods = Vec::new();
        if self.match_token(TokenKind::LBrace) {
            self.parse_method_block(&mut methods)?;
            let _ = self.expect(TokenKind::RBrace, "expected '}' to close method block");
        }
        Ok(self.spanned_decl(
            token_span(&type_tok),
            Decl::TypeDecl {
                visibility,
                name: name_tok.lexeme,
                type_params,
                implemented_traits,
                type_constraints,
                def,
                methods,
            },
        ))
    }

    /// 解析类型定义体
    fn parse_type_def(&mut self, has_error_trait: bool) -> ParseResult<TypeDef<'a>> {
        if self.match_token(TokenKind::Pipe) {
            return self.parse_adt_body();
        }
        if self.check(TokenKind::LParen) {
            let saved = self.current;
            if let Some(def) = self.try_parse_record_type_def() {
                return Ok(def);
            }
            self.current = saved;
        }
        if self.check(TokenKind::Identifier) {
            let saved = self.current;
            let name_tok = self.advance();
            if self.check(TokenKind::LParen) {
                self.advance();
                if !self.check(TokenKind::RParen) {
                    let saved2 = self.current;
                    if self.check(TokenKind::Identifier) {
                        self.advance();
                        if self.check(TokenKind::Colon) {
                            // name: Type → 记录式参数
                            self.current = saved2;
                            let mut params = Vec::new();
                            self.parse_param_list(&mut params)?;
                            if self.expect(TokenKind::RParen, "expected ')'").is_err() {
                                self.current = saved;
                                let target = self.parse_type()?;
                                return Ok(TypeDef::Alias { target });
                            }
                            if has_error_trait {
                                return Ok(TypeDef::ErrorNewtype {
                                    name: name_tok.lexeme,
                                    params,
                                });
                            }
                            self.current = saved;
                            if let Some(def) = self.try_parse_single_ctor_adt() {
                                return Ok(def);
                            }
                            self.current = saved;
                        }
                        self.current = saved2;
                    }
                    self.current = saved;
                    if let Some(def) = self.try_parse_single_ctor_adt() {
                        return Ok(def);
                    }
                    self.current = saved;
                }
            }
            self.current = saved;
        }
        let target = self.parse_type()?;
        if self.check(TokenKind::Pipe) {
            self.report_error(
                "each variant of a sum type must be prefixed with '|', including the first; for example `type Color = | Red | Green`",
            )?;
            unreachable!()
        }
        Ok(TypeDef::Alias { target })
    }

    /// 尝试解析单构造器 ADT
    fn try_parse_single_ctor_adt(&mut self) -> Option<TypeDef<'a>> {
        let name_tok = self.advance();
        if !self.check(TokenKind::LParen) {
            return None;
        }
        self.advance();
        if self.check(TokenKind::RParen) {
            self.advance();
            return Some(TypeDef::Adt {
                constructors: vec![ConstructorDef {
                    name: name_tok.lexeme,
                    fields: Vec::new(),
                    return_type: None,
                }],
            });
        }
        // 命名字段
        if self.check(TokenKind::Identifier)
            && self.current + 1 < self.tokens.len()
            && self.tokens[self.current + 1].kind == TokenKind::Colon
        {
            let mut fields = Vec::new();
            if self.parse_constructor_field_list(&mut fields).is_err() {
                return None;
            }
            if self.expect(TokenKind::RParen, "expected ')'").is_err() {
                return None;
            }
            return Some(TypeDef::Adt {
                constructors: vec![ConstructorDef {
                    name: name_tok.lexeme,
                    fields,
                    return_type: None,
                }],
            });
        }
        // 位置字段
        let first_type = match self.parse_type() {
            Ok(t) => t,
            Err(_) => return None,
        };
        if self.check(TokenKind::Comma) {
            let mut fields = vec![ConstructorField {
                name: None,
                ty: first_type,
            }];
            while self.match_token(TokenKind::Comma) {
                if self.check(TokenKind::RParen) {
                    break;
                }
                let ty = match self.parse_type() {
                    Ok(t) => t,
                    Err(_) => return None,
                };
                fields.push(ConstructorField { name: None, ty });
            }
            if self.expect(TokenKind::RParen, "expected ')'").is_err() {
                return None;
            }
            return Some(TypeDef::Adt {
                constructors: vec![ConstructorDef {
                    name: name_tok.lexeme,
                    fields,
                    return_type: None,
                }],
            });
        }
        if self.expect(TokenKind::RParen, "expected ')'").is_err() {
            return None;
        }
        Some(TypeDef::Newtype {
            name: name_tok.lexeme,
            inner: first_type,
        })
    }

    /// 尝试解析记录类型定义
    fn try_parse_record_type_def(&mut self) -> Option<TypeDef<'a>> {
        self.advance(); // '('
        if self.peek().kind == TokenKind::Identifier {
            let name = self.advance();
            if self.check(TokenKind::Colon) {
                self.advance();
                let ty = self.parse_type().ok()?;
                let mut fields = vec![RecordFieldType {
                    name: name.lexeme,
                    ty,
                }];
                while self.match_token(TokenKind::Comma) {
                    if self.check(TokenKind::RParen) {
                        break;
                    }
                    let field_name = self.expect(TokenKind::Identifier, "expected field name").ok()?;
                    let _ = self.expect(TokenKind::Colon, "expected ':'");
                    let field_ty = self.parse_type().ok()?;
                    fields.push(RecordFieldType {
                        name: field_name.lexeme,
                        ty: field_ty,
                    });
                }
                let _ = self.expect(TokenKind::RParen, "expected ')'");
                return Some(TypeDef::Record { fields });
            }
            return None;
        }
        None
    }

    /// 解析 ADT 构造器列表
    fn parse_adt_body(&mut self) -> ParseResult<TypeDef<'a>> {
        let mut constructors = vec![self.parse_constructor_def()?];
        while self.match_token(TokenKind::Pipe) {
            constructors.push(self.parse_constructor_def()?);
        }
        Ok(TypeDef::Adt { constructors })
    }

    /// 解析单个构造器定义
    fn parse_constructor_def(&mut self) -> ParseResult<ConstructorDef<'a>> {
        let name_tok = self.expect(TokenKind::Identifier, "expected constructor name")?;
        let mut fields = Vec::new();
        if self.match_token(TokenKind::LParen) {
            if !self.check(TokenKind::RParen) {
                self.parse_constructor_field_list(&mut fields)?;
            }
            let _ = self.expect(TokenKind::RParen, "expected ')' to close constructor fields");
        }
        let return_type = if self.match_token(TokenKind::Colon) {
            Some(self.parse_type()?)
        } else {
            None
        };
        Ok(ConstructorDef {
            name: name_tok.lexeme,
            fields,
            return_type,
        })
    }

    // 解析构造器字段列表
    impl_parse_comma_list!(parse_constructor_field_list, ConstructorField<'a>, parse_constructor_field, check(TokenKind::RParen));

    /// 解析单个构造器字段
    fn parse_constructor_field(&mut self) -> ParseResult<ConstructorField<'a>> {
        if self.peek().kind == TokenKind::Identifier {
            let saved = self.current;
            let name = self.advance();
            if self.match_token(TokenKind::Colon) {
                let ty = self.parse_type()?;
                return Ok(ConstructorField {
                    name: Some(name.lexeme),
                    ty,
                });
            }
            self.current = saved;
        }
        let ty = self.parse_type()?;
        Ok(ConstructorField { name: None, ty })
    }

    /// 解析 trait 声明
    fn parse_trait_decl(&mut self, visibility: Visibility) -> ParseResult<Spanned<Decl<'a>>> {
        let trait_tok = self.advance(); // 'trait'
        let name_tok = self.expect(TokenKind::Identifier, "expected trait name")?;
        let mut type_params = Vec::new();
        if self.match_token(TokenKind::Lt) {
            self.parse_type_param_list(&mut type_params)?;
            let _ = self.expect_close_angle("expected '>' to close type parameter list");
        }
        let mut parents = Vec::new();
        if self.match_token(TokenKind::LParen) {
            if !self.check(TokenKind::RParen) {
                self.parse_trait_bound_list_inner(&mut parents)?;
            }
            let _ = self.expect(TokenKind::RParen, "expected ')' to close parent trait list");
        }
        let mut associated_types = Vec::new();
        let mut methods = Vec::new();
        let _ = self.expect(TokenKind::LBrace, "expected '{' to start trait body");
        while !self.check(TokenKind::RBrace) && !self.is_at_end() {
            if self.check(TokenKind::KwType) {
                associated_types.push(self.parse_associated_type()?);
            } else {
                methods.push(self.parse_method_decl()?);
            }
        }
        let _ = self.expect(TokenKind::RBrace, "expected '}' to close trait body");
        Ok(self.spanned_decl(
            token_span(&trait_tok),
            Decl::TraitDecl {
                visibility,
                name: name_tok.lexeme,
                type_params,
                parents,
                associated_types,
                methods,
            },
        ))
    }

    /// 解析关联类型声明
    fn parse_associated_type(&mut self) -> ParseResult<AssociatedType<'a>> {
        let _type_tok = self.advance(); // 'type'
        let name_tok = self.expect(TokenKind::Identifier, "expected associated type name")?;
        let kind = if self.match_token(TokenKind::Colon) {
            Some(Box::new(self.parse_kind()?))
        } else {
            None
        };
        Ok(AssociatedType {
            name: name_tok.lexeme,
            kind,
        })
    }

    /// 解析方法声明
    fn parse_method_decl(&mut self) -> ParseResult<MethodDecl<'a>> {
        let mut visibility = Visibility::Private;
        if self.match_token(TokenKind::KwPub) {
            visibility = Visibility::Public;
        }
        let is_override = self.match_token(TokenKind::KwOverride);
        let is_async = self.match_token(TokenKind::KwAsync);
        let _ = self.expect(TokenKind::KwFun, "expected 'fun'");
        let name_tok = self.expect(TokenKind::Identifier, "expected method name")?;
        let mut type_params = Vec::new();
        if self.match_token(TokenKind::Lt) {
            self.parse_type_param_list(&mut type_params)?;
            let _ = self.expect_close_angle("expected '>'");
        }
        let mut params = Vec::new();
        let _ = self.expect(TokenKind::LParen, "expected '('");
        if !self.check(TokenKind::RParen) {
            self.parse_method_param_list(&mut params)?;
        }
        let _ = self.expect(TokenKind::RParen, "expected ')'");
        let return_type = if self.match_token(TokenKind::Colon) {
            Some(self.parse_type()?)
        } else {
            self.report_error(
                "方法声明必须显式标注返回类型（无返回值请使用 ': void'）",
            )?;
            unreachable!()
        };
        let delegate = if self.match_token(TokenKind::Eq) {
            let trait_tok = self.expect(TokenKind::Identifier, "expected delegate trait name")?;
            let _ = self.expect(TokenKind::Dot, "expected '.'");
            let method_tok = self.expect(TokenKind::Identifier, "expected delegate method name")?;
            Some(DelegateInfo {
                trait_name: trait_tok.lexeme,
                method_name: method_tok.lexeme,
            })
        } else {
            None
        };
        let body = if delegate.is_none() && self.check(TokenKind::LBrace) {
            Some(self.parse_expr()?)
        } else {
            None
        };
        Ok(MethodDecl {
            name: name_tok.lexeme,
            type_params,
            params,
            return_type,
            body,
            is_override,
            delegate,
            visibility,
            is_async,
        })
    }

    /// 解析 import 声明
    fn parse_use_decl(&mut self, visibility: Visibility) -> ParseResult<Spanned<Decl<'a>>> {
        let use_tok = self.advance(); // 'import'
        let first = self.expect(TokenKind::Identifier, "expected module name")?;
        let mut module_path = vec![first.lexeme];
        let mut dot_before_brace = false;
        while self.match_token(TokenKind::Dot) {
            if self.check(TokenKind::LBrace) {
                dot_before_brace = true;
                break;
            }
            let part = self.expect(TokenKind::Identifier, "expected module path segment")?;
            module_path.push(part.lexeme);
        }
        let items = if self.check(TokenKind::LBrace) {
            if !dot_before_brace {
                self.report_error(
                    "selective import must use '.{ }' syntax; expected '.' before '{'",
                )?;
                unreachable!()
            }
            self.advance(); // '{'
            let mut item_list = Vec::new();
            if !self.check(TokenKind::RBrace) {
                item_list.push(self.parse_import_item()?);
                while self.match_token(TokenKind::Comma) {
                    if self.check(TokenKind::RBrace) {
                        break;
                    }
                    item_list.push(self.parse_import_item()?);
                }
            }
            let _ = self.expect(TokenKind::RBrace, "expected '}'");
            Some(item_list)
        } else {
            None
        };
        Ok(self.spanned_decl(
            token_span(&use_tok),
            Decl::ImportDecl {
                module_path,
                items,
                visibility,
            },
        ))
    }

    /// 解析单个导入项
    fn parse_import_item(&mut self) -> ParseResult<ImportItem<'a>> {
        let name = self.expect(TokenKind::Identifier, "expected import item name")?;
        let alias = if self.match_token(TokenKind::KwAs) {
            let alias_tok = self.expect(TokenKind::Identifier, "expected alias")?;
            Some(alias_tok.lexeme)
        } else {
            None
        };
        Ok(ImportItem {
            name: name.lexeme,
            alias,
        })
    }

    /// 解析 pack 声明
    fn parse_pack_decl(&mut self, visibility: Visibility) -> ParseResult<Spanned<Decl<'a>>> {
        let pack_tok = self.advance(); // 'pack'
        let name_tok = self.expect(TokenKind::Identifier, "expected pack name")?;
        Ok(self.spanned_decl(
            token_span(&pack_tok),
            Decl::PackDecl {
                visibility,
                name: name_tok.lexeme,
            },
        ))
    }

    // =====================================================================
    // 类型参数、Kind、参数、约束
    // =====================================================================

    impl_parse_comma_list!(parse_type_param_list, TypeParam<'a>, parse_type_param, check_close_angle);

    fn parse_type_param(&mut self) -> ParseResult<TypeParam<'a>> {
        let name_tok = self.expect(TokenKind::Identifier, "expected type parameter name")?;
        let mut kind = None;
        let mut bounds = Vec::new();
        if self.match_token(TokenKind::Colon) {
            if self.check(TokenKind::Identifier) {
                let has_paren = self.check(TokenKind::LParen);
                if has_paren {
                    self.advance();
                }
                let trait_name_tok = self.expect(TokenKind::Identifier, "expected trait name")?;
                bounds.push(TraitBound {
                    trait_name: trait_name_tok.lexeme,
                    type_args: Vec::new(),
                });
                if has_paren {
                    while self.match_token(TokenKind::Comma) {
                        if self.check(TokenKind::RParen) {
                            break;
                        }
                        let next_trait = self.expect(TokenKind::Identifier, "expected trait name")?;
                        bounds.push(TraitBound {
                            trait_name: next_trait.lexeme,
                            type_args: Vec::new(),
                        });
                    }
                    let _ = self.expect(TokenKind::RParen, "expected ')' after trait list");
                }
            } else {
                kind = Some(Box::new(self.parse_kind()?));
            }
        }
        if self.match_token(TokenKind::KwWith) {
            self.parse_trait_bound_list_inner(&mut bounds)?;
        }
        Ok(TypeParam {
            name: name_tok.lexeme,
            kind,
            bounds,
        })
    }

    fn parse_kind(&mut self) -> ParseResult<Kind> {
        self.parse_kind_arrow()
    }

    fn parse_kind_arrow(&mut self) -> ParseResult<Kind> {
        let left = self.parse_kind_primary()?;
        if self.match_token(TokenKind::MinusGt) {
            let right = self.parse_kind_arrow()?;
            return Ok(Kind::Arrow {
                param: Box::new(left),
                result: Box::new(right),
            });
        }
        Ok(left)
    }

    fn parse_kind_primary(&mut self) -> ParseResult<Kind> {
        if self.check(TokenKind::Star) {
            self.advance();
            return Ok(Kind::Star);
        }
        if self.match_token(TokenKind::LParen) {
            let kind = self.parse_kind_arrow()?;
            let _ = self.expect(TokenKind::RParen, "expected ')'");
            return Ok(kind);
        }
        self.report_error("expected kind (* or arrow kind)")?;
        unreachable!()
    }

    impl_parse_comma_list!(parse_param_list, Param<'a>, parse_param, check(TokenKind::RParen));

    fn parse_param(&mut self) -> ParseResult<Param<'a>> {
        let name_tok = self.expect(TokenKind::Identifier, "expected parameter name")?;
        let type_annotation = if self.match_token(TokenKind::Colon) {
            Some(self.parse_type()?)
        } else {
            None
        };
        Ok(Param {
            name: name_tok.lexeme,
            type_annotation,
        })
    }

    impl_parse_comma_list!(parse_method_param_list, Param<'a>, parse_method_param, check(TokenKind::RParen));

    fn parse_method_param(&mut self) -> ParseResult<Param<'a>> {
        let is_ref_self = self.match_token(TokenKind::Ampersand);
        let name_tok = self.expect(TokenKind::Identifier, "expected parameter name")?;
        let type_annotation = if self.match_token(TokenKind::Colon) {
            Some(self.parse_type()?)
        } else if name_tok.lexeme == "self" {
            let self_ty = self.alloc_type(token_span(&name_tok), TypeNode::SelfType);
            if is_ref_self {
                Some(self.alloc_type(token_span(&name_tok), TypeNode::RefType { inner: self_ty }))
            } else {
                Some(self_ty)
            }
        } else if is_ref_self {
            self.report_error("'&' without type annotation is only allowed for 'self' parameter")?;
            unreachable!()
        } else {
            None
        };
        Ok(Param {
            name: name_tok.lexeme,
            type_annotation,
        })
    }

    fn parse_trait_bound_list(&mut self, bounds: &mut Vec<TraitBound<'a>>) -> ParseResult<()> {
        self.parse_trait_bound_list_inner(bounds)
    }

    impl_parse_comma_list!(parse_trait_bound_list_inner, TraitBound<'a>, parse_trait_bound, check(TokenKind::RParen));

    fn parse_trait_bound(&mut self) -> ParseResult<TraitBound<'a>> {
        let name_tok = self.expect(TokenKind::Identifier, "expected trait name")?;
        let mut type_args = Vec::new();
        if self.match_token(TokenKind::Lt) {
            self.parse_type_arg_list(&mut type_args)?;
            let _ = self.expect_close_angle("expected '>'");
        }
        Ok(TraitBound {
            trait_name: name_tok.lexeme,
            type_args,
        })
    }

    impl_parse_comma_list!(parse_type_constraints, TypeConstraint<'a>, parse_type_constraint, check(TokenKind::LBrace));

    fn parse_type_constraint(&mut self) -> ParseResult<TypeConstraint<'a>> {
        let type_param_tok = self.expect(TokenKind::Identifier, "expected type parameter name")?;
        self.expect(TokenKind::Colon, "expected ':' after type parameter")?;
        let concrete_type = self.parse_type()?;
        Ok(TypeConstraint {
            type_param: type_param_tok.lexeme,
            concrete_type,
        })
    }

    fn parse_method_block(&mut self, methods: &mut Vec<MethodDecl<'a>>) -> ParseResult<()> {
        while !self.check(TokenKind::RBrace) && !self.is_at_end() {
            methods.push(self.parse_method_decl()?);
        }
        Ok(())
    }

    impl_parse_comma_list!(parse_type_arg_list, TypeRef, parse_type, check_close_angle);

    // =====================================================================
    // 类型解析
    // =====================================================================

    /// 类型解析入口：处理前缀 &T / *T
    fn parse_type(&mut self) -> ParseResult<TypeRef> {
        if self.match_token(TokenKind::Ampersand) {
            let span = token_span(&self.previous());
            let inner = self.parse_type()?;
            return Ok(self.alloc_type(span, TypeNode::RefType { inner }));
        }
        if self.match_token(TokenKind::AmpAmp) {
            let span = token_span(&self.previous());
            let inner = self.parse_type()?;
            let inner_ref = self.alloc_type(span, TypeNode::RefType { inner });
            return Ok(self.alloc_type(span, TypeNode::RefType { inner: inner_ref }));
        }
        if self.match_token(TokenKind::Star) {
            let span = token_span(&self.previous());
            let inner = self.parse_type()?;
            return Ok(self.alloc_type(span, TypeNode::RawPtr { inner }));
        }
        self.parse_function_type()
    }

    /// 解析函数类型：(P1, P2) -> R 或 A -> C
    fn parse_function_type(&mut self) -> ParseResult<TypeRef> {
        if self.check(TokenKind::LParen) && self.paren_group_followed_by_arrow() {
            let span = token_span(&self.peek());
            self.advance(); // '('
            let mut params = Vec::new();
            if !self.check(TokenKind::RParen) {
                params.push(self.parse_type()?);
                while self.match_token(TokenKind::Comma) {
                    if self.check(TokenKind::RParen) {
                        break;
                    }
                    params.push(self.parse_type()?);
                }
            }
            let _ = self.expect(TokenKind::RParen, "expected ')'");
            let _ = self.expect(TokenKind::MinusGt, "expected '->'");
            let return_type = self.parse_type()?;
            return Ok(self.alloc_type(
                span,
                TypeNode::Function {
                    params,
                    return_type,
                },
            ));
        }
        let left = self.parse_nullable_type()?;
        if self.match_token(TokenKind::MinusGt) {
            let params = vec![left];
            let return_type = self.parse_type()?;
            let left_span = self.ast.ty(left).span;
            return Ok(self.alloc_type(
                left_span,
                TypeNode::Function {
                    params,
                    return_type,
                },
            ));
        }
        Ok(left)
    }

    /// 向前探测：圆括号组之后是否紧跟箭头
    fn paren_group_followed_by_arrow(&self) -> bool {
        let mut i = self.current;
        if i >= self.tokens.len() || self.tokens[i].kind != TokenKind::LParen {
            return false;
        }
        let mut depth: usize = 0;
        while i < self.tokens.len() {
            match self.tokens[i].kind {
                TokenKind::LParen => depth += 1,
                TokenKind::RParen => {
                    depth -= 1;
                    if depth == 0 {
                        let next = i + 1;
                        return next < self.tokens.len() && self.tokens[next].kind == TokenKind::MinusGt;
                    }
                }
                TokenKind::Eof => return false,
                _ => {}
            }
            i += 1;
        }
        false
    }

    /// 解析可空类型：T?（链式）
    fn parse_nullable_type(&mut self) -> ParseResult<TypeRef> {
        let mut ty = self.parse_primary_type()?;
        while self.match_token(TokenKind::Question) {
            let span = self.ast.ty(ty).span;
            ty = self.alloc_type(span, TypeNode::Nullable { inner: ty });
        }
        Ok(ty)
    }

    /// 解析基本类型：命名/泛型，后缀数组 [N]
    fn parse_primary_type(&mut self) -> ParseResult<TypeRef> {
        if self.check(TokenKind::LParen) {
            return self.parse_record_type();
        }
        let name_tok = self.expect(TokenKind::Identifier, "expected type name")?;
        let span = token_span(&name_tok);
        let mut ty = if self.match_token(TokenKind::Lt) {
            let mut args = vec![self.parse_type()?];
            while self.match_token(TokenKind::Comma) {
                if self.check_close_angle() {
                    break;
                }
                args.push(self.parse_type()?);
            }
            let _ = self.expect_close_angle("expected '>' to close type parameters");
            self.alloc_type(
                span,
                TypeNode::Generic {
                    name: name_tok.lexeme,
                    args,
                },
            )
        } else {
            self.alloc_type(span, TypeNode::Named { name: name_tok.lexeme })
        };
        // 后缀数组类型 T[N]
        while self.match_token(TokenKind::LBracket) {
            let mut size: Option<u64> = None;
            if !self.check(TokenKind::RBracket) {
                let size_tok = self.expect(TokenKind::IntLiteral, "expected array size")?;
                size = Some(parse_u64(size_tok.lexeme).ok_or_else(|| {
                    self.report_error_at(size_tok.line, size_tok.column, "array size must be a positive integer")
                })?);
            }
            let _ = self.expect(TokenKind::RBracket, "expected ']'");
            ty = self.alloc_type(span, TypeNode::Array {
                element_type: ty,
                size,
            });
        }
        Ok(ty)
    }

    /// 解析记录类型：(field: Type, ...)
    fn parse_record_type(&mut self) -> ParseResult<TypeRef> {
        let lparen = self.advance(); // '('
        let span = token_span(&lparen);
        let mut fields = Vec::new();
        if !self.check(TokenKind::RParen) {
            let name_tok = self.expect(TokenKind::Identifier, "expected field name")?;
            let _ = self.expect(TokenKind::Colon, "expected ':'");
            let ty = self.parse_type()?;
            fields.push(RecordFieldType {
                name: name_tok.lexeme,
                ty,
            });
            while self.match_token(TokenKind::Comma) {
                if self.check(TokenKind::RParen) {
                    break;
                }
                let field_name = self.expect(TokenKind::Identifier, "expected field name")?;
                let _ = self.expect(TokenKind::Colon, "expected ':'");
                let field_ty = self.parse_type()?;
                fields.push(RecordFieldType {
                    name: field_name.lexeme,
                    ty: field_ty,
                });
            }
        }
        let _ = self.expect(TokenKind::RParen, "expected ')'");
        if fields.is_empty() {
            return Ok(self.alloc_type(span, TypeNode::Named { name: "void" }));
        }
        Ok(self.alloc_type(span, TypeNode::Record { fields }))
    }

    // =====================================================================
    // 表达式解析
    // =====================================================================

    /// 表达式解析入口
    pub fn parse_expr(&mut self) -> ParseResult<ExprRef> {
        self.parse_binary(MIN_PREC)
    }

    /// 单一 Pratt 解析器
    fn parse_binary(&mut self, min_prec: u8) -> ParseResult<ExprRef> {
        let mut left = self.parse_unary()?;
        while let Some(mapping) = lookup_binary_op(self.peek().kind) {
            if mapping.precedence < min_prec {
                break;
            }
            // `*` 跨行时视为解引用
            if mapping.check_multiline_deref && self.current > 0 {
                let prev_tok = self.tokens[self.current - 1];
                if self.peek().line != prev_tok.line {
                    break;
                }
            }
            let op_tok = self.advance();
            let next_min = if mapping.right_assoc {
                mapping.precedence
            } else {
                mapping.precedence + 1
            };
            let right = self.parse_binary(next_min)?;
            left = self.alloc_expr(
                token_span(&op_tok),
                Expr::Binary {
                    op: mapping.op,
                    lhs: left,
                    rhs: right,
                },
            );
        }
        Ok(left)
    }

    /// 解析一元运算
    fn parse_unary(&mut self) -> ParseResult<ExprRef> {
        if self.match_token(TokenKind::Bang) {
            let op_tok = self.previous();
            let operand = self.parse_unary()?;
            return Ok(self.alloc_expr(token_span(&op_tok), Expr::Unary {
                op: UnaryOp::Not,
                operand,
            }));
        }
        if self.match_token(TokenKind::Tilde) {
            let op_tok = self.previous();
            let operand = self.parse_unary()?;
            return Ok(self.alloc_expr(token_span(&op_tok), Expr::Unary {
                op: UnaryOp::BitNot,
                operand,
            }));
        }
        if self.match_token(TokenKind::Ampersand) {
            let op_tok = self.previous();
            let operand = self.parse_unary()?;
            return Ok(self.alloc_expr(token_span(&op_tok), Expr::RefOf(operand)));
        }
        if self.match_token(TokenKind::AmpAmp) {
            let op_tok = self.previous();
            let operand = self.parse_unary()?;
            let inner = self.alloc_expr(token_span(&op_tok), Expr::RefOf(operand));
            return Ok(self.alloc_expr(token_span(&op_tok), Expr::RefOf(inner)));
        }
        if self.match_token(TokenKind::Star) {
            let op_tok = self.previous();
            let operand = self.parse_unary()?;
            return Ok(self.alloc_expr(token_span(&op_tok), Expr::Deref(operand)));
        }
        if self.match_token(TokenKind::Minus) {
            let op_tok = self.previous();
            // 负号紧跟数字字面量时直接合并
            if self.check(TokenKind::IntLiteral) {
                let lit_tok = self.advance();
                return self.parse_negative_int_literal(lit_tok);
            }
            if self.check(TokenKind::FloatLiteral) {
                let lit_tok = self.advance();
                return self.parse_negative_float_literal(lit_tok);
            }
            let operand = self.parse_unary()?;
            return Ok(self.alloc_expr(token_span(&op_tok), Expr::Unary {
                op: UnaryOp::Neg,
                operand,
            }));
        }
        self.parse_postfix()
    }

    /// 解析后缀运算
    fn parse_postfix(&mut self) -> ParseResult<ExprRef> {
        let mut expr = self.parse_primary()?;
        loop {
            if self.match_token(TokenKind::Question) {
                let op_tok = self.previous();
                // type_cast 后紧跟 ? → 安全转换：重新分配一个 safe=true 的 TypeCast 节点
                if let Expr::TypeCast { target, expr: inner, safe: false } = &self.ast.expr(expr).node {
                    let target = *target;
                    let inner = *inner;
                    expr = self.alloc_expr(
                        token_span(&op_tok),
                        Expr::TypeCast {
                            target,
                            expr: inner,
                            safe: true,
                        },
                    );
                    continue;
                }
                expr = self.alloc_expr(token_span(&op_tok), Expr::Propagate(expr));
            } else if self.match_token(TokenKind::Bang) {
                let op_tok = self.previous();
                expr = self.alloc_expr(token_span(&op_tok), Expr::NonNullAssert(expr));
            } else if self.match_token(TokenKind::QuestionDot) {
                let op_tok = self.previous();
                let field_tok = self.expect(TokenKind::Identifier, "expected field or method name")?;
                if self.check(TokenKind::LParen) {
                    let (args, type_args) = self.parse_call_args()?;
                    expr = self.alloc_expr(token_span(&op_tok), Expr::SafeMethodCall {
                        recv: expr,
                        method: field_tok.lexeme,
                        args,
                        type_args,
                    });
                } else {
                    expr = self.alloc_expr(token_span(&op_tok), Expr::SafeAccess {
                        recv: expr,
                        field: field_tok.lexeme,
                    });
                }
            } else if self.match_token(TokenKind::Dot) {
                let op_tok = self.previous();
                let field_tok = self.expect(TokenKind::Identifier, "expected field or method name")?;
                if self.check(TokenKind::LParen) {
                    let (args, type_args) = self.parse_call_args()?;
                    expr = self.alloc_expr(token_span(&op_tok), Expr::MethodCall {
                        recv: expr,
                        method: field_tok.lexeme,
                        args,
                        type_args,
                    });
                } else {
                    expr = self.alloc_expr(token_span(&op_tok), Expr::FieldAccess {
                        recv: expr,
                        field: field_tok.lexeme,
                    });
                }
            } else if self.check(TokenKind::LParen) {
                // 函数调用 f(args)
                if matches!(self.ast.expr(expr).node, Expr::Call { .. }) {
                    self.report_error(
                        "chained call f(a)(b) is not allowed; use default currying: bind the partial result to a variable first",
                    )?;
                    unreachable!()
                }
                let call_tok = self.peek();
                let (args, type_args) = self.parse_call_args()?;
                expr = self.alloc_expr(token_span(&call_tok), Expr::Call {
                    callee: expr,
                    args,
                    type_args,
                });
            } else if self.check(TokenKind::Lt) && self.is_turbofish_call() {
                // turbofish 调用 f<T>(args)
                self.advance(); // '<'
                let mut type_args = Vec::new();
                self.parse_type_arg_list(&mut type_args)?;
                let _ = self.expect_close_angle("expected '>'");
                if matches!(self.ast.expr(expr).node, Expr::Call { .. }) {
                    self.report_error(
                        "chained call f(a)(b) is not allowed; use default currying: bind the partial result to a variable first",
                    )?;
                    unreachable!()
                }
                let call_tok = self.peek();
                let _ = self.expect(TokenKind::LParen, "expected '('");
                let mut args = Vec::new();
                if !self.check(TokenKind::RParen) {
                    args.push(self.parse_expr()?);
                    while self.match_token(TokenKind::Comma) {
                        if self.check(TokenKind::RParen) {
                            break;
                        }
                        args.push(self.parse_expr()?);
                    }
                }
                let _ = self.expect(TokenKind::RParen, "expected ')'");
                expr = self.alloc_expr(token_span(&call_tok), Expr::Call {
                    callee: expr,
                    args,
                    type_args: Some(type_args),
                });
            } else if self.match_token(TokenKind::LBracket) {
                // 索引或切片
                let bracket_tok = self.previous();
                let start = self.parse_binary(ADDITION_PREC)?;
                if self.match_token(TokenKind::DotDotEq) || self.match_token(TokenKind::DotDot) {
                    let inclusive = self.previous().kind == TokenKind::DotDotEq;
                    let end = self.parse_binary(ADDITION_PREC)?;
                    let _ = self.expect(TokenKind::RBracket, "expected ']' after slice end");
                    expr = self.alloc_expr(token_span(&bracket_tok), Expr::Slice {
                        recv: expr,
                        start,
                        end,
                        inclusive,
                    });
                } else {
                    let _ = self.expect(TokenKind::RBracket, "expected ']'");
                    expr = self.alloc_expr(token_span(&bracket_tok), Expr::Index {
                        recv: expr,
                        index: start,
                    });
                }
            } else {
                break;
            }
        }
        Ok(expr)
    }

    /// 解析调用参数（已在 `(` 处）
    fn parse_call_args(&mut self) -> ParseResult<(Vec<ExprRef>, Option<Vec<TypeRef>>)> {
        // 可选 turbofish <T> 在 ( 之前
        let type_args = if self.match_token(TokenKind::Lt) {
            let mut ta = Vec::new();
            self.parse_type_arg_list(&mut ta)?;
            if self.match_token(TokenKind::Gt) {
                Some(ta)
            } else {
                // 回退
                self.current -= ta.len() + 1;
                None
            }
        } else {
            None
        };
        let _ = self.expect(TokenKind::LParen, "expected '('");
        let mut args = Vec::new();
        if !self.check(TokenKind::RParen) {
            args.push(self.parse_expr()?);
            while self.match_token(TokenKind::Comma) {
                if self.check(TokenKind::RParen) {
                    break;
                }
                args.push(self.parse_expr()?);
            }
        }
        let _ = self.expect(TokenKind::RParen, "expected ')'");
        Ok((args, type_args))
    }

    /// 探测 `f<T>(args)` 形式的 turbofish 调用
    fn is_turbofish_call(&self) -> bool {
        if !self.check(TokenKind::Lt) {
            return false;
        }
        let mut i = self.current + 1;
        let mut depth: usize = 1;
        let mut steps: usize = 0;
        while i < self.tokens.len() && steps < 256 {
            match self.tokens[i].kind {
                TokenKind::Lt => depth += 1,
                TokenKind::Gt => {
                    depth -= 1;
                    if depth == 0 {
                        return i + 1 < self.tokens.len() && self.tokens[i + 1].kind == TokenKind::LParen;
                    }
                }
                TokenKind::LBrace | TokenKind::RBrace | TokenKind::Eq | TokenKind::EqGt | TokenKind::Eof => {
                    return false
                }
                _ => {}
            }
            i += 1;
            steps += 1;
        }
        false
    }

    /// 解析基本表达式
    fn parse_primary(&mut self) -> ParseResult<ExprRef> {
        if self.match_token(TokenKind::IntLiteral) {
            let tok = self.previous();
            return Ok(self.parse_int_literal(tok));
        }
        if self.match_token(TokenKind::FloatLiteral) {
            let tok = self.previous();
            return Ok(self.parse_float_literal(tok));
        }
        if self.match_token(TokenKind::TrueLiteral) {
            let tok = self.previous();
            return Ok(self.alloc_expr(token_span(&tok), Expr::BoolLit(true)));
        }
        if self.match_token(TokenKind::FalseLiteral) {
            let tok = self.previous();
            return Ok(self.alloc_expr(token_span(&tok), Expr::BoolLit(false)));
        }
        if self.match_token(TokenKind::CharLiteral) {
            let tok = self.previous();
            return Ok(self.alloc_expr(token_span(&tok), Expr::CharLit(parse_char_value(tok.lexeme))));
        }
        if self.match_token(TokenKind::StringLiteral) {
            let tok = self.previous();
            return self.parse_string_literal(tok);
        }
        if self.match_token(TokenKind::NullLiteral) {
            let tok = self.previous();
            return Ok(self.alloc_expr(token_span(&tok), Expr::NullLit));
        }
        // fun(params) body → lambda
        if self.check(TokenKind::KwFun)
            && self.tokens.len() > self.current + 1
            && self.tokens[self.current + 1].kind == TokenKind::LParen
        {
            return self.parse_lambda_fun(false);
        }
        // async fun(params) body → async lambda
        if self.check(TokenKind::KwAsync)
            && self.tokens.len() > self.current + 1
            && self.tokens[self.current + 1].kind == TokenKind::KwFun
        {
            self.advance();
            return self.parse_lambda_fun(true);
        }
        if self.match_token(TokenKind::KwIf) {
            return self.parse_if_expr();
        }
        if self.match_token(TokenKind::KwMatch) {
            return self.parse_match_expr();
        }
        if self.match_token(TokenKind::KwLazy) {
            return self.parse_lazy_expr();
        }
        if self.match_token(TokenKind::KwAtomic) {
            return self.parse_atomic_expr();
        }
        if self.match_token(TokenKind::KwSelect) {
            return self.parse_select_expr();
        }
        if self.check_identifier("cast") {
            self.advance();
            return self.parse_cast_builder();
        }
        if self.check(TokenKind::KwTrait)
            && self.tokens.len() > self.current + 1
            && self.tokens[self.current + 1].kind == TokenKind::LBrace
        {
            return self.parse_inline_trait_value();
        }
        if self.match_token(TokenKind::LBracket) {
            return self.parse_array_literal();
        }
        if self.check(TokenKind::LBrace) {
            return self.parse_block_expr();
        }
        if self.match_token(TokenKind::LParen) {
            return self.parse_paren_or_record_or_lambda();
        }
        // `type` 关键字在表达式位置且后跟 `(` → 作为标识符
        if self.check(TokenKind::KwType)
            && self.tokens.len() > self.current + 1
            && self.tokens[self.current + 1].kind == TokenKind::LParen
        {
            let tok = self.advance();
            return Ok(self.alloc_expr(token_span(&tok), Expr::Ident(tok.lexeme)));
        }
        if matches!(
            self.peek().kind,
            TokenKind::Identifier | TokenKind::KwVal | TokenKind::KwVar | TokenKind::KwChannel
        ) {
            // void 在表达式位置表示单元值
            if self.check(TokenKind::Identifier) && self.peek().lexeme == "void" {
                let tok = self.advance();
                return Ok(self.alloc_expr(token_span(&tok), Expr::VoidLit));
            }
            // 内建类型名后跟 `(` → 类型转换
            if is_builtin_type(self.peek().lexeme)
                && self.tokens.len() > self.current + 1
                && self.tokens[self.current + 1].kind == TokenKind::LParen
            {
                return self.parse_type_cast();
            }
            let tok = self.advance();
            return Ok(self.alloc_expr(token_span(&tok), Expr::Ident(tok.lexeme)));
        }
        self.report_error("expected expression")?;
        unreachable!()
    }

    // =====================================================================
    // 字面量解析
    // =====================================================================

    /// 解析整数字面量，分离数字部分与类型后缀
    fn parse_int_literal(&mut self, tok: Token<'a>) -> ExprRef {
        let raw = tok.lexeme;
        let mut i: usize = 0;
        if raw.len() > 2 && raw.as_bytes()[0] == b'0' {
            let p = raw.as_bytes()[1];
            if p == b'x' || p == b'X' || p == b'o' || p == b'O' || p == b'b' || p == b'B' {
                i = 2;
            }
        }
        while i < raw.len() && is_digit_or_underscore(raw.as_bytes()[i]) {
            i += 1;
        }
        if i < raw.len() && raw.len() > 2 && raw.as_bytes()[0] == b'0' {
            let p = raw.as_bytes()[1];
            if p == b'x' || p == b'X' {
                while i < raw.len() && is_hex_or_underscore(raw.as_bytes()[i]) {
                    i += 1;
                }
            }
        }
        let suffix = if i < raw.len() { Some(&raw[i..]) } else { None };
        self.alloc_expr(token_span(&tok), Expr::IntLit {
            raw: &raw[..i],
            suffix,
        })
    }

    /// 解析负整数字面量，将负号合并进 raw
    fn parse_negative_int_literal(&mut self, lit_tok: Token<'a>) -> ParseResult<ExprRef> {
        let raw = lit_tok.lexeme;
        let mut i: usize = 0;
        if raw.len() > 2 && raw.as_bytes()[0] == b'0' {
            let p = raw.as_bytes()[1];
            if p == b'x' || p == b'X' || p == b'o' || p == b'O' || p == b'b' || p == b'B' {
                i = 2;
            }
        }
        while i < raw.len() && is_digit_or_underscore(raw.as_bytes()[i]) {
            i += 1;
        }
        if i < raw.len() && raw.len() > 2 && raw.as_bytes()[0] == b'0' {
            let p = raw.as_bytes()[1];
            if p == b'x' || p == b'X' {
                while i < raw.len() && is_hex_or_underscore(raw.as_bytes()[i]) {
                    i += 1;
                }
            }
        }
        let suffix = if i < raw.len() { Some(&raw[i..]) } else { None };
        // 在 arena 中分配 "-" + raw[..i]
        let mut s = bumpalo::collections::String::new_in(self.arena);
        s.push('-');
        s.push_str(&raw[..i]);
        let neg_raw: &'a str = s.into_bump_str();
        Ok(self.alloc_expr(token_span(&lit_tok), Expr::IntLit {
            raw: neg_raw,
            suffix,
        }))
    }

    /// 解析浮点字面量，分离数字部分与类型后缀
    fn parse_float_literal(&mut self, tok: Token<'a>) -> ExprRef {
        let raw = tok.lexeme;
        let bytes = raw.as_bytes();
        let mut i = raw.len();
        // 从末尾扫描数字
        while i > 0 && bytes[i - 1].is_ascii_digit() {
            i -= 1;
        }
        // 从末尾扫描字母（后缀）
        while i > 0 && bytes[i - 1].is_ascii_alphabetic() {
            i -= 1;
        }
        let (num_part, suffix) = if i < raw.len() && i > 0 && bytes[i].is_ascii_alphabetic() {
            (&raw[..i], Some(&raw[i..]))
        } else {
            (raw, None)
        };
        self.alloc_expr(token_span(&tok), Expr::FloatLit {
            raw: num_part,
            suffix,
        })
    }

    /// 解析负浮点字面量
    fn parse_negative_float_literal(&mut self, lit_tok: Token<'a>) -> ParseResult<ExprRef> {
        let raw = lit_tok.lexeme;
        let bytes = raw.as_bytes();
        let mut i = raw.len();
        while i > 0 && bytes[i - 1].is_ascii_digit() {
            i -= 1;
        }
        while i > 0 && bytes[i - 1].is_ascii_alphabetic() {
            i -= 1;
        }
        let (num_part, suffix) = if i < raw.len() && i > 0 && bytes[i].is_ascii_alphabetic() {
            (&raw[..i], Some(&raw[i..]))
        } else {
            (raw, None)
        };
        let mut s = bumpalo::collections::String::new_in(self.arena);
        s.push('-');
        s.push_str(num_part);
        let neg_raw: &'a str = s.into_bump_str();
        Ok(self.alloc_expr(token_span(&lit_tok), Expr::FloatLit {
            raw: neg_raw,
            suffix,
        }))
    }

    /// 解析字符串字面量（含插值处理）
    fn parse_string_literal(&mut self, tok: Token<'a>) -> ParseResult<ExprRef> {
        let raw = tok.lexeme;
        if !contains_interpolation(raw) {
            let content = &raw[1..raw.len() - 1];
            let value = self.unescape_string(content);
            return Ok(self.alloc_expr(token_span(&tok), Expr::StrLit(value)));
        }
        let content = &raw[1..raw.len() - 1];
        let mut parts = Vec::new();
        let bytes = content.as_bytes();
        let mut i: usize = 0;
        let mut literal_start: usize = 0;
        while i < content.len() {
            if bytes[i] == b'\\' {
                i += 2;
                continue;
            }
            if bytes[i] == b'{' {
                if i + 1 < content.len() && bytes[i + 1] == b'{' {
                    i += 2;
                    continue;
                }
                if i > literal_start {
                    let text = self.unescape_string(&content[literal_start..i]);
                    parts.push(InterpolationPart::Literal(text));
                }
                i += 1;
                let expr_start = i;
                let mut brace_depth: usize = 1;
                while i < content.len() && brace_depth > 0 {
                    if bytes[i] == b'{' {
                        brace_depth += 1;
                    } else if bytes[i] == b'}' {
                        brace_depth -= 1;
                    } else if bytes[i] == b'\\' {
                        i += 1;
                    }
                    i += 1;
                }
                let expr_text = &content[expr_start..i - 1];
                let expr = self.parse_interpolation_expr(expr_text)?;
                parts.push(InterpolationPart::Expression(expr));
                literal_start = i;
                continue;
            }
            i += 1;
        }
        if literal_start < content.len() {
            let text = self.unescape_string(&content[literal_start..]);
            parts.push(InterpolationPart::Literal(text));
        }
        Ok(self.alloc_expr(token_span(&tok), Expr::StrInterp(parts)))
    }

    /// 对插值表达式文本进行词法+语法分析
    fn parse_interpolation_expr(&mut self, text: &'a str) -> ParseResult<ExprRef> {
        let mut lexer = Lexer::new(text);
        let mut sink = TokenCollector::new();
        lexer.tokenize_into(&mut sink);
        let tokens = sink.into_tokens();
        let tokens_ref: &'a [Token<'a>] = self.arena.alloc_slice_copy(&tokens);

        let saved_tokens = self.tokens;
        let saved_current = self.current;
        let saved_pending_eq = self.pending_eq;
        let saved_pending_gt = self.pending_gt;
        let saved_pending_gt_eq = self.pending_gt_eq;
        let saved_error_count = self.handler.errors().len();

        self.tokens = tokens_ref;
        self.current = 0;
        self.pending_eq = false;
        self.pending_gt = false;
        self.pending_gt_eq = false;

        let result = self.parse_expr();
        // 恢复状态
        self.tokens = saved_tokens;
        self.current = saved_current;
        self.pending_eq = saved_pending_eq;
        self.pending_gt = saved_pending_gt;
        self.pending_gt_eq = saved_pending_gt_eq;
        if result.is_err() {
            self.handler.truncate_errors(saved_error_count);
        }
        result
    }

    /// 反转义字符串
    fn unescape_string(&self, text: &'a str) -> &'a str {
        // 快路径：无转义则零拷贝返回
        let bytes = text.as_bytes();
        let mut i = 0;
        while i < text.len() {
            if bytes[i] == b'\\' {
                break;
            }
            if bytes[i] == b'{' && i + 1 < text.len() && bytes[i + 1] == b'{' {
                break;
            }
            if bytes[i] == b'}' && i + 1 < text.len() && bytes[i + 1] == b'}' {
                break;
            }
            i += 1;
        }
        if i >= text.len() {
            return text;
        }
        // 慢路径
        let mut result = bumpalo::collections::String::new_in(self.arena);
        let mut j = 0;
        while j < text.len() {
            if bytes[j] == b'\\' && j + 1 < text.len() {
                match bytes[j + 1] {
                    b'n' => {
                        result.push('\n');
                        j += 2;
                    }
                    b't' => {
                        result.push('\t');
                        j += 2;
                    }
                    b'r' => {
                        result.push('\r');
                        j += 2;
                    }
                    b'\\' => {
                        result.push('\\');
                        j += 2;
                    }
                    b'"' => {
                        result.push('"');
                        j += 2;
                    }
                    b'{' => {
                        result.push('{');
                        j += 2;
                    }
                    b'}' => {
                        result.push('}');
                        j += 2;
                    }
                    _ => {
                        result.push(bytes[j] as char);
                        j += 1;
                    }
                }
            } else if bytes[j] == b'{' && j + 1 < text.len() && bytes[j + 1] == b'{' {
                result.push('{');
                j += 2;
            } else if bytes[j] == b'}' && j + 1 < text.len() && bytes[j + 1] == b'}' {
                result.push('}');
                j += 2;
            } else {
                result.push(bytes[j] as char);
                j += 1;
            }
        }
        result.into_bump_str()
    }

    // =====================================================================
    // 特殊表达式
    // =====================================================================

    /// 解析 fun 关键字开头的 lambda：fun(params) body
    fn parse_lambda_fun(&mut self, is_async: bool) -> ParseResult<ExprRef> {
        let fun_tok = self.advance(); // 'fun'
        let span = token_span(&fun_tok);
        let mut params = Vec::new();
        let _ = self.expect(TokenKind::LParen, "expected '('");
        if !self.check(TokenKind::RParen) {
            self.parse_param_list(&mut params)?;
        }
        let _ = self.expect(TokenKind::RParen, "expected ')'");
        let body_expr = self.parse_expr()?;
        Ok(self.alloc_expr(span, Expr::Lambda {
            params,
            body: LambdaBody::Block(body_expr),
            is_async,
            return_type: None,
        }))
    }

    /// 尝试解析 lambda：(params) => expr（失败时回退）
    fn try_parse_lambda(&mut self, saved: usize, span: Span) -> Option<ExprRef> {
        let saved_error_count = self.handler.errors().len();
        let mut params = Vec::new();
        if !self.check(TokenKind::RParen)
            && self.parse_lambda_param_list(&mut params).is_err()
        {
            self.handler.truncate_errors(saved_error_count);
            self.current = saved;
            return None;
        }
        if !self.check(TokenKind::RParen) {
            self.handler.truncate_errors(saved_error_count);
            self.current = saved;
            return None;
        }
        self.advance(); // ')'
        if !self.check(TokenKind::EqGt) {
            self.current = saved;
            self.handler.truncate_errors(saved_error_count);
            return None;
        }
        self.advance(); // '=>'
        let body_expr = match self.parse_expr() {
            Ok(e) => e,
            Err(_) => {
                self.current = saved;
                self.handler.truncate_errors(saved_error_count);
                return None;
            }
        };
        Some(self.alloc_expr(span, Expr::Lambda {
            params,
            body: LambdaBody::Expression(body_expr),
            is_async: false,
            return_type: None,
        }))
    }

    impl_parse_comma_list!(parse_lambda_param_list, Param<'a>, parse_lambda_param, check(TokenKind::RParen));

    fn parse_lambda_param(&mut self) -> ParseResult<Param<'a>> {
        let name_tok = self.expect(TokenKind::Identifier, "expected parameter name")?;
        let type_annotation = if self.match_token(TokenKind::Colon) {
            Some(self.parse_type()?)
        } else {
            None
        };
        Ok(Param {
            name: name_tok.lexeme,
            type_annotation,
        })
    }

    /// 解析圆括号表达式：单元值、lambda、记录字面量、记录扩展或分组
    fn parse_paren_or_record_or_lambda(&mut self) -> ParseResult<ExprRef> {
        let lparen_tok = self.previous();
        let span = token_span(&lparen_tok);
        if self.match_token(TokenKind::RParen) {
            return Ok(self.alloc_expr(span, Expr::VoidLit));
        }
        let saved = self.current;
        if let Some(lambda) = self.try_parse_lambda(saved, span) {
            return Ok(lambda);
        }
        self.current = saved;
        // 记录扩展：(...base, field: value)
        if self.peek().kind == TokenKind::Ellipsis {
            self.advance();
            let base_expr = self.parse_expr()?;
            let mut updates = Vec::new();
            while self.match_token(TokenKind::Comma) {
                if self.check(TokenKind::RParen) {
                    break;
                }
                let field_name = self.expect(TokenKind::Identifier, "expected field name")?;
                let _ = self.expect(TokenKind::Colon, "expected ':'");
                let field_value = self.parse_expr()?;
                updates.push(RecordFieldExpr {
                    name: field_name.lexeme,
                    value: field_value,
                });
            }
            let _ = self.expect(TokenKind::RParen, "expected ')'");
            return Ok(self.alloc_expr(span, Expr::RecordExtend {
                base: base_expr,
                updates,
            }));
        }
        // 记录字面量：(field: value, ...)
        if self.peek().kind == TokenKind::Identifier {
            let name_tok = self.advance();
            if self.check(TokenKind::Colon) {
                self.advance();
                let value = self.parse_expr()?;
                let mut fields = vec![RecordFieldExpr {
                    name: name_tok.lexeme,
                    value,
                }];
                while self.match_token(TokenKind::Comma) {
                    if self.check(TokenKind::RParen) {
                        break;
                    }
                    if self.check(TokenKind::Ellipsis) {
                        // (field: value, ...base, more: value)
                        self.advance();
                        let base_expr = self.parse_expr()?;
                        let mut updates = fields.clone();
                        while self.match_token(TokenKind::Comma) {
                            if self.check(TokenKind::RParen) {
                                break;
                            }
                            let field_name = self.expect(TokenKind::Identifier, "expected field name")?;
                            let _ = self.expect(TokenKind::Colon, "expected ':'");
                            let field_value = self.parse_expr()?;
                            updates.push(RecordFieldExpr {
                                name: field_name.lexeme,
                                value: field_value,
                            });
                        }
                        let _ = self.expect(TokenKind::RParen, "expected ')'");
                        return Ok(self.alloc_expr(span, Expr::RecordExtend {
                            base: base_expr,
                            updates,
                        }));
                    }
                    let field_name = self.expect(TokenKind::Identifier, "expected field name")?;
                    let _ = self.expect(TokenKind::Colon, "expected ':'");
                    let field_value = self.parse_expr()?;
                    fields.push(RecordFieldExpr {
                        name: field_name.lexeme,
                        value: field_value,
                    });
                }
                let _ = self.expect(TokenKind::RParen, "expected ')'");
                return Ok(self.alloc_expr(span, Expr::RecordLit(fields)));
            }
            self.current = saved;
        }
        // 普通分组表达式
        let first_expr = self.parse_expr()?;
        if self.match_token(TokenKind::Comma) {
            // 匿名元组不被允许
            self.report_error_at(
                lparen_tok.line,
                lparen_tok.column,
                "anonymous tuples are not allowed; use named record fields like (name: value, ...)",
            );
            return Ok(self.alloc_expr(token_span(&lparen_tok), Expr::VoidLit));
        }
        let _ = self.expect(TokenKind::RParen, "expected ')'");
        Ok(first_expr)
    }

    /// 解析类型转换：BuiltinType(expr)
    fn parse_type_cast(&mut self) -> ParseResult<ExprRef> {
        let name_tok = self.advance();
        let span = token_span(&name_tok);
        let target = self.alloc_type(span, TypeNode::Named { name: name_tok.lexeme });
        let _ = self.expect(TokenKind::LParen, "expected '('");
        let expr = self.parse_expr()?;
        let _ = self.expect(TokenKind::RParen, "expected ')'");
        Ok(self.alloc_expr(span, Expr::TypeCast {
            target,
            expr,
            safe: false,
        }))
    }

    /// 解析 cast builder：cast(expr).to(T) / cast(expr).try_to(T)
    fn parse_cast_builder(&mut self) -> ParseResult<ExprRef> {
        let cast_tok = self.previous();
        let span = token_span(&cast_tok);
        let _ = self.expect(TokenKind::LParen, "expected '(' after 'cast'");
        let expr = self.parse_expr()?;
        let _ = self.expect(TokenKind::RParen, "expected ')' after cast expression");
        let _ = self.expect(TokenKind::Dot, "expected '.to(...)' or '.try_to(...)' after cast(...)");
        if !self.check(TokenKind::Identifier) {
            self.report_error("expected 'to' or 'try_to' after cast(...).")?;
            unreachable!()
        }
        let method_tok = self.advance();
        let mode = match method_tok.lexeme {
            "to" => CastMode::To,
            "try_to" => CastMode::TryTo,
            _ => {
                self.report_error("expected 'to' or 'try_to' after cast(...).")?;
                unreachable!()
            }
        };
        let _ = self.expect(TokenKind::LParen, "expected '(' after cast method");
        if !self.check(TokenKind::Identifier) {
            self.report_error("expected type name as cast target")?;
            unreachable!()
        }
        let type_tok = self.advance();
        if !is_builtin_type(type_tok.lexeme) {
            self.report_error(
                "cast target must be a builtin type (i8/i16/.../isize/usize/.../bool/char/str)",
            )?;
            unreachable!()
        }
        let target = self.alloc_type(token_span(&type_tok), TypeNode::Named { name: type_tok.lexeme });
        let _ = self.expect(TokenKind::RParen, "expected ')' after cast target type");
        Ok(self.alloc_expr(span, Expr::CastBuilder {
            expr,
            target,
            mode,
        }))
    }

    /// 解析 if 表达式
    fn parse_if_expr(&mut self) -> ParseResult<ExprRef> {
        let if_tok = self.previous();
        let span = token_span(&if_tok);
        self.reject_paren_condition("if")?;
        let cond = self.parse_expr()?;
        let then_branch = self.parse_expr()?;
        let else_branch = if self.match_token(TokenKind::KwElse) {
            Some(self.parse_expr()?)
        } else {
            None
        };
        Ok(self.alloc_expr(span, Expr::If {
            cond,
            then_branch,
            else_branch,
        }))
    }

    /// 解析 match 表达式
    fn parse_match_expr(&mut self) -> ParseResult<ExprRef> {
        let match_tok = self.previous();
        let span = token_span(&match_tok);
        self.reject_paren_condition("match")?;
        let scrutinee = self.parse_expr()?;
        let _ = self.expect(TokenKind::LBrace, "expected '{'");
        let mut arms = Vec::new();
        while !self.check(TokenKind::RBrace) && !self.is_at_end() {
            let arm = match self.parse_match_arm() {
                Ok(a) => a,
                Err(_) => {
                    while !self.check(TokenKind::Comma) && !self.check(TokenKind::RBrace) && !self.is_at_end() {
                        self.advance();
                    }
                    if self.match_token(TokenKind::Comma) {
                        continue;
                    }
                    break;
                }
            };
            arms.push(arm);
            self.match_token(TokenKind::Comma);
        }
        let _ = self.expect(TokenKind::RBrace, "expected '}'");
        Ok(self.alloc_expr(span, Expr::Match { scrutinee, arms }))
    }

    /// 解析 match 分支
    fn parse_match_arm(&mut self) -> ParseResult<MatchArm> {
        let pattern = self.parse_pattern()?;
        let guard = if self.match_token(TokenKind::KwIf) {
            self.reject_paren_condition("if guard")?;
            Some(self.parse_expr()?)
        } else {
            None
        };
        let _ = self.expect(TokenKind::EqGt, "expected '=>'");
        // 控制流语句作为分支体时包装为块表达式
        let body = if matches!(
            self.peek().kind,
            TokenKind::KwThrow | TokenKind::KwReturn | TokenKind::KwBreak | TokenKind::KwContinue
        ) {
            let stmt_tok = self.peek();
            let stmt = self.parse_stmt()?;
            let span = token_span(&stmt_tok);
            self.alloc_expr(span, Expr::Block {
                stmts: vec![stmt],
                trailing: None,
            })
        } else {
            self.parse_expr()?
        };
        Ok(MatchArm {
            pattern,
            guard,
            body,
        })
    }

    fn parse_lazy_expr(&mut self) -> ParseResult<ExprRef> {
        let lazy_tok = self.previous();
        let expr = self.parse_expr()?;
        Ok(self.alloc_expr(token_span(&lazy_tok), Expr::Lazy(expr)))
    }

    fn parse_atomic_expr(&mut self) -> ParseResult<ExprRef> {
        let atomic_tok = self.previous();
        let value = self.parse_primary()?;
        Ok(self.alloc_expr(token_span(&atomic_tok), Expr::Atomic(value)))
    }

    fn parse_select_expr(&mut self) -> ParseResult<ExprRef> {
        let select_tok = self.previous();
        let span = token_span(&select_tok);
        let _ = self.expect(TokenKind::LBrace, "expected '{'");
        let mut arms = Vec::new();
        while !self.check(TokenKind::RBrace) && !self.is_at_end() {
            arms.push(self.parse_select_arm()?);
            self.match_token(TokenKind::Comma);
        }
        let _ = self.expect(TokenKind::RBrace, "expected '}'");
        Ok(self.alloc_expr(span, Expr::Select(arms)))
    }

    fn parse_select_arm(&mut self) -> ParseResult<SelectArm<'a>> {
        if self.check_identifier("timeout") {
            let _timeout_tok = self.advance();
            let _ = self.expect(TokenKind::LParen, "expected '('");
            let duration = self.parse_expr()?;
            let _ = self.expect(TokenKind::RParen, "expected ')'");
            let _ = self.expect(TokenKind::EqGt, "expected '=>'");
            let body = self.parse_expr()?;
            return Ok(SelectArm::Timeout { duration, body });
        }
        let channel_expr = self.parse_expr()?;
        let _ = self.expect(TokenKind::EqGt, "expected '=>'");
        let binding = if self.check(TokenKind::Identifier)
            && self.current + 1 < self.tokens.len()
            && self.tokens[self.current + 1].kind == TokenKind::EqGt
        {
            let name_tok = self.advance();
            self.advance(); // '=>'
            Some(name_tok.lexeme)
        } else {
            None
        };
        let body = self.parse_expr()?;
        Ok(SelectArm::Receive {
            channel_expr,
            binding,
            body,
        })
    }

    fn parse_inline_trait_value(&mut self) -> ParseResult<ExprRef> {
        let trait_tok = self.advance(); // 'trait'
        let span = token_span(&trait_tok);
        let _ = self.expect(TokenKind::LBrace, "expected '{'");
        let mut methods = Vec::new();
        while !self.check(TokenKind::RBrace) && !self.is_at_end() {
            methods.push(self.parse_method_decl()?);
        }
        let _ = self.expect(TokenKind::RBrace, "expected '}'");
        Ok(self.alloc_expr(span, Expr::InlineTrait(methods)))
    }

    /// 解析数组字面量
    fn parse_array_literal(&mut self) -> ParseResult<ExprRef> {
        let bracket_tok = self.previous();
        let span = token_span(&bracket_tok);
        let mut elements = Vec::new();
        if !self.check(TokenKind::RBracket) {
            elements.push(self.parse_expr()?);
            // 数组填充语法 [value, ..count]
            if self.match_token(TokenKind::Comma) {
                if self.match_token(TokenKind::DotDot) {
                    let count = self.parse_expr()?;
                    let _ = self.expect(TokenKind::RBracket, "expected ']' after array fill count");
                    let value = elements[0];
                    return Ok(self.alloc_expr(span, Expr::ArrayLit {
                        elements,
                        fill: Some((value, count)),
                    }));
                }
                // 普通多元素
                if !self.check(TokenKind::RBracket) {
                    elements.push(self.parse_expr()?);
                    while self.match_token(TokenKind::Comma) {
                        if self.check(TokenKind::RBracket) {
                            break;
                        }
                        elements.push(self.parse_expr()?);
                    }
                }
            }
        }
        let _ = self.expect(TokenKind::RBracket, "expected ']'");
        Ok(self.alloc_expr(span, Expr::ArrayLit {
            elements,
            fill: None,
        }))
    }

    /// 解析块表达式
    fn parse_block_expr(&mut self) -> ParseResult<ExprRef> {
        let brace_tok = self.advance(); // '{'
        let span = token_span(&brace_tok);
        let mut stmts = Vec::new();
        let mut trailing = None;
        while !self.check(TokenKind::RBrace) && !self.is_at_end() {
            if self.is_stmt_start() {
                let stmt = self.parse_stmt()?;
                if matches!(self.ast.stmt(stmt).node, Stmt::Expression { .. }) && self.check(TokenKind::RBrace) {
                    if let Stmt::Expression { expr } = &self.ast.stmt(stmt).node {
                        trailing = Some(*expr);
                        break;
                    }
                }
                stmts.push(stmt);
            } else {
                let stmt = self.parse_expr_or_assignment_stmt()?;
                if matches!(self.ast.stmt(stmt).node, Stmt::Expression { .. }) && self.check(TokenKind::RBrace) {
                    if let Stmt::Expression { expr } = &self.ast.stmt(stmt).node {
                        trailing = Some(*expr);
                        break;
                    }
                }
                stmts.push(stmt);
            }
        }
        let _ = self.expect(TokenKind::RBrace, "expected '}'");
        Ok(self.alloc_expr(span, Expr::Block { stmts, trailing }))
    }

    // =====================================================================
    // 语句解析
    // =====================================================================

    fn is_stmt_start(&self) -> bool {
        matches!(
            self.peek().kind,
            TokenKind::KwVal
                | TokenKind::KwVar
                | TokenKind::KwFun
                | TokenKind::KwReturn
                | TokenKind::KwDefer
                | TokenKind::KwThrow
                | TokenKind::KwBreak
                | TokenKind::KwContinue
                | TokenKind::KwFor
                | TokenKind::KwWhile
                | TokenKind::KwLoop
        )
    }

    /// 语句解析入口
    fn parse_stmt(&mut self) -> ParseResult<StmtRef> {
        if self.match_token(TokenKind::KwVal) {
            return self.parse_val_decl();
        }
        if self.match_token(TokenKind::KwVar) {
            return self.parse_var_decl();
        }
        if self.match_token(TokenKind::KwFun) {
            return self.parse_fun_stmt();
        }
        if self.match_token(TokenKind::KwReturn) {
            return self.parse_return_stmt();
        }
        if self.match_token(TokenKind::KwDefer) {
            return self.parse_defer_stmt();
        }
        if self.match_token(TokenKind::KwThrow) {
            return self.parse_throw_stmt();
        }
        if self.match_token(TokenKind::KwBreak) {
            let tok = self.previous();
            return Ok(self.alloc_stmt(token_span(&tok), Stmt::Break));
        }
        if self.match_token(TokenKind::KwContinue) {
            let tok = self.previous();
            return Ok(self.alloc_stmt(token_span(&tok), Stmt::Continue));
        }
        if self.match_token(TokenKind::KwFor) {
            return self.parse_for_stmt();
        }
        if self.match_token(TokenKind::KwWhile) {
            return self.parse_while_stmt();
        }
        if self.match_token(TokenKind::KwLoop) {
            return self.parse_loop_stmt();
        }
        self.parse_expr_or_assignment_stmt()
    }

    /// 解析 fun 语句
    fn parse_fun_stmt(&mut self) -> ParseResult<StmtRef> {
        let fun_tok = self.previous();
        let span = token_span(&fun_tok);
        if self.check(TokenKind::Identifier) && !self.check_identifier("in") {
            let name_tok = self.advance();
            let mut params = Vec::new();
            let _ = self.expect(TokenKind::LParen, "expected '('");
            if !self.check(TokenKind::RParen) {
                self.parse_param_list(&mut params)?;
            }
            let _ = self.expect(TokenKind::RParen, "expected ')'");
            let return_type = if self.match_token(TokenKind::Colon) {
                Some(self.parse_type()?)
            } else {
                None
            };
            let body_expr = self.parse_expr()?;
            let lambda = self.alloc_expr(span, Expr::Lambda {
                params,
                body: LambdaBody::Block(body_expr),
                is_async: false,
                return_type,
            });
            return Ok(self.alloc_stmt(span, Stmt::ValDecl {
                name: name_tok.lexeme,
                type_annotation: None,
                value: lambda,
                visibility: Visibility::Private,
            }));
        }
        // 匿名 lambda
        let mut params = Vec::new();
        let _ = self.expect(TokenKind::LParen, "expected '('");
        if !self.check(TokenKind::RParen) {
            self.parse_param_list(&mut params)?;
        }
        let _ = self.expect(TokenKind::RParen, "expected ')'");
        let body_expr = self.parse_expr()?;
        let lambda = self.alloc_expr(span, Expr::Lambda {
            params,
            body: LambdaBody::Block(body_expr),
            is_async: false,
            return_type: None,
        });
        Ok(self.alloc_stmt(span, Stmt::Expression { expr: lambda }))
    }

    fn parse_val_decl(&mut self) -> ParseResult<StmtRef> {
        let val_tok = self.previous();
        let name_tok = self.expect(TokenKind::Identifier, "expected variable name")?;
        let type_annotation = if self.match_token(TokenKind::Colon) {
            Some(self.parse_type()?)
        } else {
            None
        };
        let _ = self.expect(TokenKind::Eq, "expected '='");
        let value = self.parse_expr()?;
        Ok(self.alloc_stmt(token_span(&val_tok), Stmt::ValDecl {
            name: name_tok.lexeme,
            type_annotation,
            value,
            visibility: Visibility::Private,
        }))
    }

    fn parse_var_decl(&mut self) -> ParseResult<StmtRef> {
        let var_tok = self.previous();
        let name_tok = self.expect(TokenKind::Identifier, "expected variable name")?;
        let type_annotation = if self.match_token(TokenKind::Colon) {
            Some(self.parse_type()?)
        } else {
            None
        };
        let _ = self.expect(TokenKind::Eq, "expected '='");
        let value = self.parse_expr()?;
        Ok(self.alloc_stmt(token_span(&var_tok), Stmt::VarDecl {
            name: name_tok.lexeme,
            type_annotation,
            value,
            visibility: Visibility::Private,
        }))
    }

    fn parse_return_stmt(&mut self) -> ParseResult<StmtRef> {
        let return_tok = self.previous();
        let value = if !self.check(TokenKind::RBrace) && !self.is_stmt_start() && !self.is_at_end() {
            Some(self.parse_expr()?)
        } else {
            None
        };
        Ok(self.alloc_stmt(token_span(&return_tok), Stmt::Return { value }))
    }

    fn parse_defer_stmt(&mut self) -> ParseResult<StmtRef> {
        let defer_tok = self.previous();
        let span = token_span(&defer_tok);
        let expr = self.parse_expr()?;
        if self.match_token(TokenKind::Eq) {
            let value = self.parse_expr()?;
            let expr_span = self.ast.expr(expr).span;
            let assign_expr = self.alloc_expr(expr_span, Expr::Assign {
                target: expr,
                value,
            });
            return Ok(self.alloc_stmt(span, Stmt::Defer {
                expr: assign_expr,
            }));
        }
        Ok(self.alloc_stmt(span, Stmt::Defer { expr }))
    }

    fn parse_throw_stmt(&mut self) -> ParseResult<StmtRef> {
        let throw_tok = self.previous();
        let expr = self.parse_expr()?;
        Ok(self.alloc_stmt(token_span(&throw_tok), Stmt::Throw { expr }))
    }

    fn parse_for_stmt(&mut self) -> ParseResult<StmtRef> {
        let for_tok = self.previous();
        let span = token_span(&for_tok);
        let name_tok = self.expect(TokenKind::Identifier, "expected iterator variable name")?;
        let _ = self.expect(TokenKind::KwIn, "expected 'in'");
        self.reject_paren_condition("for")?;
        let iterable = self.parse_expr()?;
        let body = self.parse_expr()?;
        Ok(self.alloc_stmt(span, Stmt::For {
            name: name_tok.lexeme,
            iterable,
            body,
        }))
    }

    fn parse_while_stmt(&mut self) -> ParseResult<StmtRef> {
        let while_tok = self.previous();
        let span = token_span(&while_tok);
        self.reject_paren_condition("while")?;
        let condition = self.parse_expr()?;
        let body = self.parse_expr()?;
        Ok(self.alloc_stmt(span, Stmt::While { condition, body }))
    }

    fn parse_loop_stmt(&mut self) -> ParseResult<StmtRef> {
        let loop_tok = self.previous();
        let body = self.parse_expr()?;
        Ok(self.alloc_stmt(token_span(&loop_tok), Stmt::Loop { body }))
    }

    fn parse_expr_or_assignment_stmt(&mut self) -> ParseResult<StmtRef> {
        let expr = self.parse_expr()?;
        if self.match_token(TokenKind::Eq) {
            let eq_tok = self.previous();
            let value = self.parse_expr()?;
            // 先从 arena 复制出节点信息，避免与 alloc_stmt 的 &mut self 借用冲突
            let expr_span = self.ast.expr(expr).span;
            let (is_ident, field_info): (bool, Option<(ExprRef, &'a str)>) =
                match &self.ast.expr(expr).node {
                    Expr::Ident(_) => (true, None),
                    Expr::FieldAccess { recv, field, .. } => (false, Some((*recv, *field))),
                    _ => (false, None),
                };
            return Ok(if is_ident {
                self.alloc_stmt(expr_span, Stmt::Assignment {
                    target: expr,
                    value,
                })
            } else if let Some((recv, field)) = field_info {
                self.alloc_stmt(token_span(&eq_tok), Stmt::FieldAssignment {
                    object: recv,
                    field,
                    value,
                })
            } else {
                self.alloc_stmt(token_span(&eq_tok), Stmt::Assignment {
                    target: expr,
                    value,
                })
            });
        }
        if let Some(op) = self.peek_compound_assign() {
            self.advance();
            let op_tok = self.previous();
            let value = self.parse_expr()?;
            return Ok(self.alloc_stmt(token_span(&op_tok), Stmt::CompoundAssignment {
                target: expr,
                op,
                value,
            }));
        }
        let expr_span = self.ast.expr(expr).span;
        Ok(self.alloc_stmt(expr_span, Stmt::Expression { expr }))
    }

    fn peek_compound_assign(&self) -> Option<CompoundAssignOp> {
        match self.peek().kind {
            TokenKind::PlusEq => Some(CompoundAssignOp::AddAssign),
            TokenKind::MinusEq => Some(CompoundAssignOp::SubAssign),
            TokenKind::StarEq => Some(CompoundAssignOp::MulAssign),
            TokenKind::SlashEq => Some(CompoundAssignOp::DivAssign),
            TokenKind::PercentEq => Some(CompoundAssignOp::ModAssign),
            TokenKind::AmpEq => Some(CompoundAssignOp::BitAndAssign),
            TokenKind::PipeEq => Some(CompoundAssignOp::BitOrAssign),
            TokenKind::CaretEq => Some(CompoundAssignOp::BitXorAssign),
            TokenKind::LtLtEq => Some(CompoundAssignOp::ShlAssign),
            TokenKind::GtGtEq => Some(CompoundAssignOp::ShrAssign),
            _ => None,
        }
    }

    // =====================================================================
    // 模式解析
    // =====================================================================

    fn parse_pattern(&mut self) -> ParseResult<PatternRef> {
        self.parse_or_pattern()
    }

    fn parse_or_pattern(&mut self) -> ParseResult<PatternRef> {
        let mut left = self.parse_primary_pattern()?;
        while self.match_token(TokenKind::Pipe) {
            let pipe_tok = self.previous();
            let right = self.parse_primary_pattern()?;
            left = self.alloc_pattern(token_span(&pipe_tok), Pattern::OrPattern {
                left,
                right,
            });
        }
        Ok(left)
    }

    fn parse_primary_pattern(&mut self) -> ParseResult<PatternRef> {
        if self.check(TokenKind::Identifier) && self.peek().lexeme == "_" {
            let tok = self.advance();
            return Ok(self.alloc_pattern(token_span(&tok), Pattern::Wildcard));
        }
        if self.match_token(TokenKind::NullLiteral) {
            let tok = self.previous();
            return Ok(self.alloc_pattern(token_span(&tok), Pattern::Literal(PatternLiteral::Null)));
        }
        if self.match_token(TokenKind::TrueLiteral) {
            let tok = self.previous();
            return Ok(self.alloc_pattern(token_span(&tok), Pattern::Literal(PatternLiteral::Bool(true))));
        }
        if self.match_token(TokenKind::FalseLiteral) {
            let tok = self.previous();
            return Ok(self.alloc_pattern(token_span(&tok), Pattern::Literal(PatternLiteral::Bool(false))));
        }
        if self.match_token(TokenKind::IntLiteral) {
            let tok = self.previous();
            return Ok(self.alloc_pattern(token_span(&tok), Pattern::Literal(PatternLiteral::Int(tok.lexeme))));
        }
        if self.match_token(TokenKind::FloatLiteral) {
            let tok = self.previous();
            return Ok(self.alloc_pattern(token_span(&tok), Pattern::Literal(PatternLiteral::Float(tok.lexeme))));
        }
        if self.match_token(TokenKind::CharLiteral) {
            let tok = self.previous();
            return Ok(self.alloc_pattern(token_span(&tok), Pattern::Literal(PatternLiteral::Char(parse_char_value(tok.lexeme)))));
        }
        if self.match_token(TokenKind::StringLiteral) {
            let tok = self.previous();
            let value = &tok.lexeme[1..tok.lexeme.len() - 1];
            return Ok(self.alloc_pattern(token_span(&tok), Pattern::Literal(PatternLiteral::String(value))));
        }
        if self.match_token(TokenKind::LParen) {
            return self.parse_record_pattern();
        }
        if self.check(TokenKind::KwVal) || self.check(TokenKind::KwVar) {
            let name_tok = self.advance();
            if self.check(TokenKind::LParen) {
                return self.parse_constructor_pattern(name_tok);
            }
            return Ok(self.alloc_pattern(token_span(&name_tok), Pattern::Variable {
                name: name_tok.lexeme,
            }));
        }
        if self.check(TokenKind::Identifier) {
            let name_tok = self.advance();
            if self.check(TokenKind::LParen) {
                return self.parse_constructor_pattern(name_tok);
            }
            return Ok(self.alloc_pattern(token_span(&name_tok), Pattern::Variable {
                name: name_tok.lexeme,
            }));
        }
        self.report_error("expected pattern")?;
        unreachable!()
    }

    /// 解析构造器模式
    fn parse_constructor_pattern(&mut self, name_tok: Token<'a>) -> ParseResult<PatternRef> {
        self.advance(); // '('
        let mut patterns = Vec::new();
        if !self.check(TokenKind::RParen) {
            patterns.push(self.parse_pattern()?);
            while self.match_token(TokenKind::Comma) {
                if self.check(TokenKind::RParen) {
                    break;
                }
                patterns.push(self.parse_pattern()?);
            }
        }
        let _ = self.expect(TokenKind::RParen, "expected ')'");
        Ok(self.alloc_pattern(token_span(&name_tok), Pattern::Constructor {
            name: name_tok.lexeme,
            patterns,
        }))
    }

    /// 解析记录模式
    fn parse_record_pattern(&mut self) -> ParseResult<PatternRef> {
        let lparen = self.previous();
        let span = token_span(&lparen);
        let mut fields = Vec::new();
        if !self.check(TokenKind::RParen) {
            if self.peek().kind == TokenKind::Identifier {
                let saved = self.current;
                let name_tok = self.advance();
                if self.check(TokenKind::Colon) {
                    // 命名字段模式
                    self.advance();
                    let pattern = self.parse_pattern()?;
                    fields.push(PatternRecordField {
                        name: name_tok.lexeme,
                        pattern,
                    });
                    while self.match_token(TokenKind::Comma) {
                        if self.check(TokenKind::RParen) {
                            break;
                        }
                        let field_name = self.expect(TokenKind::Identifier, "expected field name")?;
                        let _ = self.expect(TokenKind::Colon, "expected ':'");
                        let field_pattern = self.parse_pattern()?;
                        fields.push(PatternRecordField {
                            name: field_name.lexeme,
                            pattern: field_pattern,
                        });
                    }
                    let _ = self.expect(TokenKind::RParen, "expected ')'");
                    return Ok(self.alloc_pattern(span, Pattern::Record { fields }));
                }
                self.current = saved;
            }
            // 位置模式
            let first = self.parse_pattern()?;
            fields.push(PatternRecordField {
                name: int_to_key(self.arena, 0),
                pattern: first,
            });
            let mut idx: usize = 1;
            while self.match_token(TokenKind::Comma) {
                if self.check(TokenKind::RParen) {
                    break;
                }
                let p = self.parse_pattern()?;
                fields.push(PatternRecordField {
                    name: int_to_key(self.arena, idx),
                    pattern: p,
                });
                idx += 1;
            }
        }
        let _ = self.expect(TokenKind::RParen, "expected ')'");
        Ok(self.alloc_pattern(span, Pattern::Record { fields }))
    }
}

// =========================================================================
// 辅助函数
// =========================================================================

fn token_span(tok: &Token<'_>) -> Span {
    Span::new(tok.line, tok.column)
}

fn is_builtin_type(name: &str) -> bool {
    matches!(
        name,
        "i8" | "i16" | "i32" | "i64" | "i128" | "u8" | "u16" | "u32" | "u64" | "u128" | "isize"
            | "usize" | "f16" | "f32" | "f64" | "f128" | "bool" | "char" | "str"
    )
}

fn parse_char_value(lexeme: &str) -> u32 {
    if lexeme.len() < 3 {
        return 0;
    }
    let content = &lexeme[1..lexeme.len() - 1];
    if content.is_empty() {
        return 0;
    }
    let bytes = content.as_bytes();
    if bytes[0] == b'\\' {
        if content.len() < 2 {
            return 0;
        }
        return match bytes[1] {
            b'n' => b'\n' as u32,
            b't' => b'\t' as u32,
            b'r' => b'\r' as u32,
            b'\\' => b'\\' as u32,
            b'\'' => b'\'' as u32,
            b'0' => 0,
            _ => bytes[1] as u32,
        };
    }
    bytes[0] as u32
}

fn contains_interpolation(raw: &str) -> bool {
    if raw.len() < 2 {
        return false;
    }
    let bytes = raw.as_bytes();
    let mut i = 1;
    while i < raw.len() - 1 {
        if bytes[i] == b'\\' {
            i += 2;
            continue;
        }
        if bytes[i] == b'{' {
            if i + 1 < raw.len() - 1 && bytes[i + 1] == b'{' {
                i += 2;
                continue;
            }
            return true;
        }
        i += 1;
    }
    false
}

fn is_digit_or_underscore(ch: u8) -> bool {
    ch.is_ascii_digit() || ch == b'_'
}

fn is_hex_or_underscore(ch: u8) -> bool {
    is_digit_or_underscore(ch) || (b'a'..=b'f').contains(&ch) || (b'A'..=b'F').contains(&ch)
}

fn int_to_key(arena: &Bump, idx: usize) -> &str {
    let s = idx.to_string();
    arena.alloc_str(&s)
}

fn parse_u64(s: &str) -> Option<u64> {
    s.parse::<u64>().ok()
}

// =========================================================================
// 测试
// =========================================================================

#[cfg(test)]
mod parser_tests {
    use super::*;

    fn parse_module<'a>(src: &'a str, arena: &'a Bump) -> ParseResult<Module<'a>> {
        let mut lexer = Lexer::new(src);
        let mut sink = TokenCollector::new();
        lexer.tokenize_into(&mut sink);
        let tokens = sink.into_tokens();
        let tokens_ref: &[Token<'a>] = arena.alloc_slice_copy(&tokens);
        let mut parser = Parser::new(tokens_ref, arena, ErrorCollector::new());
        parser.parse_module("test")
    }

    #[test]
    fn test_parse_empty() {
        let arena = Bump::new();
        let module = parse_module("", &arena).unwrap();
        assert!(module.declarations.is_empty());
    }

    #[test]
    fn test_parse_pack() {
        let arena = Bump::new();
        let module = parse_module("pack Main", &arena).unwrap();
        assert_eq!(module.declarations.len(), 1);
        match &module.declarations[0].node {
            Decl::PackDecl { name, .. } => assert_eq!(*name, "Main"),
            _ => panic!("expected pack decl"),
        }
    }

    #[test]
    fn test_parse_simple_fun() {
        let arena = Bump::new();
        let src = "fun main(): void { println(\"hello\") }";
        let module = parse_module(src, &arena).unwrap();
        assert_eq!(module.declarations.len(), 1);
        match &module.declarations[0].node {
            Decl::FunDecl {
                name,
                is_entry,
                return_type,
                ..
            } => {
                assert_eq!(*name, "main");
                assert!(*is_entry);
                assert!(return_type.is_some());
            }
            _ => panic!("expected fun decl"),
        }
    }

    #[test]
    fn test_parse_val_decl() {
        let arena = Bump::new();
        let src = "fun f(): void { val x = 42 }";
        let module = parse_module(src, &arena).unwrap();
        match &module.declarations[0].node {
            Decl::FunDecl { body, .. } => {
                match &module.arena.expr(*body).node {
                    Expr::Block { stmts, .. } => {
                        assert_eq!(stmts.len(), 1);
                        match &module.arena.stmt(stmts[0]).node {
                            Stmt::ValDecl { name, .. } => assert_eq!(*name, "x"),
                            _ => panic!("expected val decl"),
                        }
                    }
                    _ => panic!("expected block"),
                }
            }
            _ => panic!("expected fun decl"),
        }
    }

    #[test]
    fn test_parse_binary_expr() {
        let arena = Bump::new();
        let src = "fun f(): void { val x = 1 + 2 * 3 }";
        let module = parse_module(src, &arena).unwrap();
        match &module.declarations[0].node {
            Decl::FunDecl { body, .. } => match &module.arena.expr(*body).node {
                Expr::Block { stmts, .. } => match &module.arena.stmt(stmts[0]).node {
                    Stmt::ValDecl { value, .. } => match &module.arena.expr(*value).node {
                        Expr::Binary {
                            op: BinaryOp::Add,
                            ..
                        } => {}
                        _ => panic!("expected add"),
                    },
                    _ => panic!("expected val decl"),
                },
                _ => panic!("expected block"),
            },
            _ => panic!("expected fun decl"),
        }
    }

    #[test]
    fn test_parse_negative_literal() {
        let arena = Bump::new();
        let src = "fun f(): void { val x = -42 }";
        let module = parse_module(src, &arena).unwrap();
        match &module.declarations[0].node {
            Decl::FunDecl { body, .. } => match &module.arena.expr(*body).node {
                Expr::Block { stmts, .. } => match &module.arena.stmt(stmts[0]).node {
                    Stmt::ValDecl { value, .. } => match &module.arena.expr(*value).node {
                        Expr::IntLit { raw, .. } => assert_eq!(*raw, "-42"),
                        _ => panic!("expected int lit"),
                    },
                    _ => panic!("expected val decl"),
                },
                _ => panic!("expected block"),
            },
            _ => panic!("expected fun decl"),
        }
    }

    #[test]
    fn test_parse_lambda_arrow() {
        let arena = Bump::new();
        let src = "fun f(): void { val g = (x: i32) => x + 1 }";
        let module = parse_module(src, &arena).unwrap();
        match &module.declarations[0].node {
            Decl::FunDecl { body, .. } => match &module.arena.expr(*body).node {
                Expr::Block { stmts, .. } => match &module.arena.stmt(stmts[0]).node {
                    Stmt::ValDecl { value, .. } => match &module.arena.expr(*value).node {
                        Expr::Lambda {
                            body: LambdaBody::Expression(_),
                            ..
                        } => {}
                        _ => panic!("expected lambda"),
                    },
                    _ => panic!("expected val decl"),
                },
                _ => panic!("expected block"),
            },
            _ => panic!("expected fun decl"),
        }
    }

    #[test]
    fn test_parse_type_decl_adt() {
        let arena = Bump::new();
        let src = "type Color = | Red | Green | Blue";
        let module = parse_module(src, &arena).unwrap();
        match &module.declarations[0].node {
            Decl::TypeDecl { def, .. } => match def {
                TypeDef::Adt { constructors } => {
                    assert_eq!(constructors.len(), 3);
                    assert_eq!(constructors[0].name, "Red");
                }
                _ => panic!("expected adt"),
            },
            _ => panic!("expected type decl"),
        }
    }

    #[test]
    fn test_parse_import() {
        let arena = Bump::new();
        // `pack` 是关键字，不能作为模块路径段；使用非关键字路径
        let src = "import main.foo.{ bar, baz as qux }";
        let module = parse_module(src, &arena).unwrap();
        match &module.declarations[0].node {
            Decl::ImportDecl {
                module_path,
                items,
                ..
            } => {
                assert_eq!(module_path, &vec!["main", "foo"]);
                assert!(items.is_some());
                let items = items.as_ref().unwrap();
                assert_eq!(items.len(), 2);
                assert_eq!(items[0].name, "bar");
                assert_eq!(items[1].alias, Some("qux"));
            }
            _ => panic!("expected import decl"),
        }
    }

    #[test]
    fn test_parse_nested_generics() {
        let arena = Bump::new();
        let src = "type Foo = List<List<i32>>";
        let module = parse_module(src, &arena).unwrap();
        match &module.declarations[0].node {
            Decl::TypeDecl { def, .. } => match def {
                TypeDef::Alias { target } => match &module.arena.ty(*target).node {
                    TypeNode::Generic { name, args } => {
                        assert_eq!(*name, "List");
                        assert_eq!(args.len(), 1);
                        match &module.arena.ty(args[0]).node {
                            TypeNode::Generic { name, .. } => assert_eq!(*name, "List"),
                            _ => panic!("expected nested generic"),
                        }
                    }
                    _ => panic!("expected generic"),
                },
                _ => panic!("expected alias"),
            },
            _ => panic!("expected type decl"),
        }
    }

    #[test]
    fn test_parse_string_interpolation() {
        let arena = Bump::new();
        let src = "fun f(): void { println(\"hello {name}!\") }";
        let module = parse_module(src, &arena).unwrap();
        match &module.declarations[0].node {
            Decl::FunDecl { body, .. } => match &module.arena.expr(*body).node {
                // 单表达式块：println 调用作为 trailing 表达式
                Expr::Block { trailing, .. } => {
                    let expr = trailing.as_ref().expect("expected trailing expr");
                    match &module.arena.expr(*expr).node {
                        Expr::Call { args, .. } => match &module.arena.expr(args[0]).node {
                            Expr::StrInterp(parts) => {
                                assert_eq!(parts.len(), 3);
                            }
                            _ => panic!("expected string interp"),
                        },
                        _ => panic!("expected call"),
                    }
                }
                _ => panic!("expected block"),
            },
            _ => panic!("expected fun decl"),
        }
    }

    #[test]
    fn test_parse_multiline_deref() {
        // `*` 跨行时应视解引用，而非乘法
        let arena = Bump::new();
        let src = "fun f(): void { val x = a\n*b }";
        let module = parse_module(src, &arena).unwrap();
        match &module.declarations[0].node {
            Decl::FunDecl { body, .. } => match &module.arena.expr(*body).node {
                Expr::Block { stmts, trailing, .. } => {
                    // val x = a 是语句；*b 跨行视为解引用，作为 trailing 表达式
                    assert_eq!(stmts.len(), 1);
                    let trailing = trailing.as_ref().expect("expected trailing deref");
                    match &module.arena.expr(*trailing).node {
                        Expr::Deref(_) => {}
                        _ => panic!("expected deref expr"),
                    }
                }
                _ => panic!("expected block"),
            },
            _ => panic!("expected fun decl"),
        }
    }

    #[test]
    fn test_parse_record_literal() {
        let arena = Bump::new();
        let src = "fun f(): void { val r = (x: 1, y: 2) }";
        let module = parse_module(src, &arena).unwrap();
        match &module.declarations[0].node {
            Decl::FunDecl { body, .. } => match &module.arena.expr(*body).node {
                Expr::Block { stmts, .. } => match &module.arena.stmt(stmts[0]).node {
                    Stmt::ValDecl { value, .. } => match &module.arena.expr(*value).node {
                        Expr::RecordLit(fields) => {
                            assert_eq!(fields.len(), 2);
                            assert_eq!(fields[0].name, "x");
                        }
                        _ => panic!("expected record lit"),
                    },
                    _ => panic!("expected val decl"),
                },
                _ => panic!("expected block"),
            },
            _ => panic!("expected fun decl"),
        }
    }

    #[test]
    fn test_parse_array_fill() {
        let arena = Bump::new();
        let src = "fun f(): void { val a = [0, ..10] }";
        let module = parse_module(src, &arena).unwrap();
        match &module.declarations[0].node {
            Decl::FunDecl { body, .. } => match &module.arena.expr(*body).node {
                Expr::Block { stmts, .. } => match &module.arena.stmt(stmts[0]).node {
                    Stmt::ValDecl { value, .. } => match &module.arena.expr(*value).node {
                        Expr::ArrayLit { fill, .. } => assert!(fill.is_some()),
                        _ => panic!("expected array lit"),
                    },
                    _ => panic!("expected val decl"),
                },
                _ => panic!("expected block"),
            },
            _ => panic!("expected fun decl"),
        }
    }

    #[test]
    fn test_parse_match_expr() {
        let arena = Bump::new();
        let src = "fun f(x: i32): i32 { match x { _ => 0 } }";
        let module = parse_module(src, &arena).unwrap();
        match &module.declarations[0].node {
            Decl::FunDecl { body, .. } => match &module.arena.expr(*body).node {
                // match 作为块中唯一的表达式，成为 trailing
                Expr::Block { trailing, .. } => {
                    let m = trailing.as_ref().expect("expected trailing match");
                    match &module.arena.expr(*m).node {
                        Expr::Match { arms, .. } => assert_eq!(arms.len(), 1),
                        _ => panic!("expected match"),
                    }
                }
                _ => panic!("expected block"),
            },
            _ => panic!("expected fun decl"),
        }
    }

    #[test]
    fn test_parse_trait_decl() {
        let arena = Bump::new();
        let src = "trait Drawable { fun draw(): void }";
        let module = parse_module(src, &arena).unwrap();
        match &module.declarations[0].node {
            Decl::TraitDecl { name, methods, .. } => {
                assert_eq!(*name, "Drawable");
                assert_eq!(methods.len(), 1);
            }
            _ => panic!("expected trait decl"),
        }
    }
}

// AST 打印器
//
// 将 AST 序列化为规范的 S-表达式文本，用于：
// - 调试：可视化解析结果
// - 验证：与 Zig 原版 ast_printer 输出做 diff，确保语义一致
//
// 格式约定：
// - 每个节点一行，`(node_type field1 field2 ...)`
// - 嵌套节点缩进 2 空格
// - 字符串字面量用双引号包裹，内部转义 `"` `\` `\n`
// - 空列表输出 `()`，可选值缺失输出 `(none)`
// - 标识符/名称裸输出（不加引号），与字符串字面量区分


/// AST 打印器：累积输出文本与缩进层级
pub struct Printer<'a> {
    buf: String,
    indent: usize,
    arena: &'a AstArena<'a>,
}

// --- 打印辅助宏 ---

/// 为运算符类型生成 `(op <name>)` 打印方法
macro_rules! impl_print_op {
    ($method:ident, $op:ty, $conv:ident) => {
        fn $method(&mut self, op: $op) {
            self.write_line(&format!("(op {})", $conv(op)));
        }
    };
}

/// 生成带标签的列表打印方法：空列表输出 `(label ())`，否则逐项打印。
/// 列表元素为 NodeId（Copy），逐项解引用后调用对应 visit_*。
macro_rules! impl_print_list {
    ($method:ident, $item:ty, $print_fn:ident) => {
        fn $method(&mut self, label: &str, items: &[$item]) {
            if items.is_empty() {
                self.write_line(&format!("({} ())", label));
                return;
            }
            self.write_line(&format!("({}", label));
            self.indent();
            for e in items {
                self.$print_fn(*e);
            }
            self.dedent();
            self.write_line(")");
        }
    };
}

impl<'a> Printer<'a> {
    /// 创建打印器，需传入模块的 AST arena 用于解引用节点
    pub fn new(arena: &'a AstArena<'a>) -> Self {
        Self {
            buf: String::new(),
            indent: 0,
            arena,
        }
    }

    /// 将 `&ExprId` 解引用并访问
    fn ve(&mut self, id: &ExprId) {
        self.visit_expr(*id);
    }
    /// 将 `&TypeId` 解引用并访问
    fn vt(&mut self, id: &TypeId) {
        self.visit_type(*id);
    }
    /// 将 `&StmtId` 解引用并访问
    fn vs(&mut self, id: &StmtId) {
        self.visit_stmt(*id);
    }
    /// 将 `&PatternId` 解引用并访问
    fn vp(&mut self, id: &PatternId) {
        self.visit_pattern(*id);
    }

    /// 将模块打印为规范文本
    pub fn print_module(&mut self, module: &'a Module<'a>) -> &str {
        self.write_line(&format!("(module \"{}\"", escape_str(module.name)));
        self.indent();
        if let Some(path) = module.source_path {
            self.write_line(&format!("(source_path \"{}\")", escape_str(path)));
        }
        for decl in &module.declarations {
            self.visit_decl(decl);
        }
        self.dedent();
        self.write_line(")");
        &self.buf
    }

    // --- 缩进辅助 ---

    fn indent(&mut self) {
        self.indent += 1;
    }

    fn dedent(&mut self) {
        if self.indent > 0 {
            self.indent -= 1;
        }
    }

    fn write_line(&mut self, text: &str) {
        for _ in 0..self.indent {
            self.buf.push_str("  ");
        }
        self.buf.push_str(text);
        self.buf.push('\n');
    }
}

impl<'a> AstVisitor<'a> for Printer<'a> {
    // --- 声明 ---

    fn visit_decl(&mut self, decl: &'a Spanned<Decl<'a>>) {
        match &decl.node {
            Decl::FunDecl {
                visibility,
                name,
                type_params,
                params,
                return_type,
                bounds,
                body,
                is_async,
                is_entry,
                attributes,
                extern_c_body,
            } => {
                self.write_line(&format!("(fun_decl \"{}\"", name));
                self.indent();
                for attr in attributes {
                    if attr.args.is_empty() {
                        self.write_line(&format!("(attribute \"{}\")", attr.name));
                    } else {
                        let args_str = attr.args.iter().map(|a| format!("\"{}\"", a)).collect::<Vec<_>>().join(" ");
                        self.write_line(&format!("(attribute \"{}\" (args {}))", attr.name, args_str));
                    }
                }
                self.print_visibility(*visibility);
                self.print_type_params(type_params);
                self.print_params(params);
                self.print_return_type(return_type);
                self.print_bounds(bounds);
                self.write_line(&format!("(is_async {})(is_entry {})", is_async, is_entry));
                self.write_line("(body");
                self.indent();
                self.ve(body);
                self.dedent();
                self.write_line(")");
                if let Some(c_body) = extern_c_body {
                    self.write_line("(extern_c_body");
                    self.indent();
                    self.write_line(&format!("\"{}\"", c_body.escape_default()));
                    self.dedent();
                    self.write_line(")");
                }
                self.dedent();
                self.write_line(")");
            }
            Decl::TypeDecl {
                visibility,
                name,
                type_params,
                implemented_traits,
                type_constraints,
                def,
                methods,
            } => {
                self.write_line(&format!("(type_decl \"{}\"", name));
                self.indent();
                self.print_visibility(*visibility);
                self.print_type_params(type_params);
                self.print_bounds(implemented_traits);
                self.print_type_constraints(type_constraints);
                self.visit_type_def(def);
                self.print_methods(methods);
                self.dedent();
                self.write_line(")");
            }
            Decl::TraitDecl {
                visibility,
                name,
                type_params,
                parents,
                associated_types,
                methods,
            } => {
                self.write_line(&format!("(trait_decl \"{}\"", name));
                self.indent();
                self.print_visibility(*visibility);
                self.print_type_params(type_params);
                self.print_bounds(parents);
                self.print_associated_types(associated_types);
                self.print_methods(methods);
                self.dedent();
                self.write_line(")");
            }
            Decl::ImportDecl {
                module_path,
                items,
                visibility,
            } => {
                let path_str = module_path.join(".");
                self.write_line(&format!("(import_decl \"{}\"", path_str));
                self.indent();
                self.print_visibility(*visibility);
                match items {
                    Some(item_list) => {
                        self.write_line("(items");
                        self.indent();
                        for item in item_list {
                            match item.alias {
                                Some(alias) => {
                                    self.write_line(&format!(
                                        "(item \"{}\" (alias \"{}\"))",
                                        item.name, alias
                                    ));
                                }
                                None => {
                                    self.write_line(&format!("(item \"{}\")", item.name));
                                }
                            }
                        }
                        self.dedent();
                        self.write_line(")");
                    }
                    None => self.write_line("(items (none))"),
                }
                self.dedent();
                self.write_line(")");
            }
            Decl::PackDecl { visibility, name } => {
                self.write_line(&format!("(pack_decl \"{}\"", name));
                self.indent();
                self.print_visibility(*visibility);
                self.dedent();
                self.write_line(")");
            }
            Decl::ExprDecl { expr, stmt } => {
                self.write_line("(expr_decl");
                self.indent();
                self.ve(expr);
                if let Some(s) = stmt {
                    self.write_line("(stmt");
                    self.indent();
                    self.vs(s);
                    self.dedent();
                    self.write_line(")");
                } else {
                    self.write_line("(stmt (none))");
                }
                self.dedent();
                self.write_line(")");
            }
        }
    }

    // --- 类型定义 ---

    fn visit_type_def(&mut self, def: &'a TypeDef<'a>) {
        match def {
            TypeDef::Adt { constructors } => {
                self.write_line("(adt");
                self.indent();
                for ctor in constructors {
                    self.write_line(&format!("(constructor \"{}\"", ctor.name));
                    self.indent();
                    if ctor.fields.is_empty() {
                        self.write_line("(fields ())");
                    } else {
                        self.write_line("(fields");
                        self.indent();
                        for field in &ctor.fields {
                            match field.name {
                                Some(fname) => {
                                    self.write_line(&format!("(field \"{}\"", fname));
                                    self.indent();
                                    self.vt(&field.ty);
                                    self.dedent();
                                    self.write_line(")");
                                }
                                None => {
                                    self.write_line("(positional_field");
                                    self.indent();
                                    self.vt(&field.ty);
                                    self.dedent();
                                    self.write_line(")");
                                }
                            }
                        }
                        self.dedent();
                        self.write_line(")");
                    }
                    if let Some(rt) = &ctor.return_type {
                        self.write_line("(return_type");
                        self.indent();
                        self.vt(rt);
                        self.dedent();
                        self.write_line(")");
                    } else {
                        self.write_line("(return_type (none))");
                    }
                    self.dedent();
                    self.write_line(")");
                }
                self.dedent();
                self.write_line(")");
            }
            TypeDef::Record { fields } => {
                self.write_line("(record");
                self.indent();
                if fields.is_empty() {
                    self.write_line("(fields ())");
                } else {
                    self.write_line("(fields");
                    self.indent();
                    for field in fields {
                        self.write_line(&format!("(field \"{}\"", field.name));
                        self.indent();
                        self.vt(&field.ty);
                        self.dedent();
                        self.write_line(")");
                    }
                    self.dedent();
                    self.write_line(")");
                }
                self.dedent();
                self.write_line(")");
            }
            TypeDef::Alias { target } => {
                self.write_line("(alias");
                self.indent();
                self.vt(target);
                self.dedent();
                self.write_line(")");
            }
            TypeDef::Newtype { name, inner } => {
                self.write_line(&format!("(newtype \"{}\"", name));
                self.indent();
                self.vt(inner);
                self.dedent();
                self.write_line(")");
            }
            TypeDef::ErrorNewtype { name, params } => {
                self.write_line(&format!("(error_newtype \"{}\"", name));
                self.indent();
                self.print_params(params);
                self.dedent();
                self.write_line(")");
            }
        }
    }
    // --- 类型节点 ---

    fn visit_type(&mut self, ty: TypeId) {
        match &self.arena.ty(ty).node {
            TypeNode::Named { name } => {
                self.write_line(&format!("(type_named \"{}\")", name));
            }
            TypeNode::SelfType => {
                self.write_line("(type_self)");
            }
            TypeNode::Generic { name, args } => {
                self.write_line(&format!("(type_generic \"{}\"", name));
                self.indent();
                self.print_type_list("type_args", args);
                self.dedent();
                self.write_line(")");
            }
            TypeNode::Nullable { inner } => {
                self.write_line("(type_nullable");
                self.indent();
                self.vt(inner);
                self.dedent();
                self.write_line(")");
            }
            TypeNode::RefType { inner } => {
                self.write_line("(type_ref");
                self.indent();
                self.vt(inner);
                self.dedent();
                self.write_line(")");
            }
            TypeNode::RawPtr { inner } => {
                self.write_line("(type_raw_ptr");
                self.indent();
                self.vt(inner);
                self.dedent();
                self.write_line(")");
            }
            TypeNode::Function {
                params,
                return_type,
            } => {
                self.write_line("(type_function");
                self.indent();
                self.print_type_list("params", params);
                self.write_line("(return_type");
                self.indent();
                self.vt(return_type);
                self.dedent();
                self.write_line(")");
                self.dedent();
                self.write_line(")");
            }
            TypeNode::Record { fields } => {
                self.write_line("(type_record");
                self.indent();
                if fields.is_empty() {
                    self.write_line("(fields ())");
                } else {
                    self.write_line("(fields");
                    self.indent();
                    for field in fields {
                        self.write_line(&format!("(field \"{}\"", field.name));
                        self.indent();
                        self.vt(&field.ty);
                        self.dedent();
                        self.write_line(")");
                    }
                    self.dedent();
                    self.write_line(")");
                }
                self.dedent();
                self.write_line(")");
            }
            TypeNode::Array {
                element_type,
                size,
            } => {
                self.write_line("(type_array");
                self.indent();
                self.write_line("(element_type");
                self.indent();
                self.vt(element_type);
                self.dedent();
                self.write_line(")");
                match size {
                    Some(n) => self.write_line(&format!("(size {})", n)),
                    None => self.write_line("(size (none))"),
                }
                self.dedent();
                self.write_line(")");
            }
            TypeNode::KindAnnotated { inner, kind } => {
                self.write_line("(type_kind_annotated");
                self.indent();
                self.vt(inner);
                self.write_line("(kind");
                self.indent();
                self.visit_kind(kind);
                self.dedent();
                self.write_line(")");
                self.dedent();
                self.write_line(")");
            }
        }
    }

    fn visit_kind(&mut self, kind: &'a Kind) {
        match kind {
            Kind::Star => self.write_line("(kind_star)"),
            Kind::Arrow { param, result } => {
                self.write_line("(kind_arrow");
                self.indent();
                self.write_line("(param");
                self.indent();
                self.visit_kind(param);
                self.dedent();
                self.write_line(")");
                self.write_line("(result");
                self.indent();
                self.visit_kind(result);
                self.dedent();
                self.write_line(")");
                self.dedent();
                self.write_line(")");
            }
        }
    }

    // --- 表达式 ---

    fn visit_expr(&mut self, expr: ExprId) {
        match &self.arena.expr(expr).node {
            Expr::IntLit { raw, suffix } => match suffix {
                Some(s) => self.write_line(&format!("(int_lit \"{}\" (suffix \"{}\"))", raw, s)),
                None => self.write_line(&format!("(int_lit \"{}\" (suffix (none)))", raw)),
            },
            Expr::FloatLit { raw, suffix } => match suffix {
                Some(s) => self.write_line(&format!("(float_lit \"{}\" (suffix \"{}\"))", raw, s)),
                None => self.write_line(&format!("(float_lit \"{}\" (suffix (none)))", raw)),
            },
            Expr::BoolLit(b) => self.write_line(&format!("(bool_lit {})", b)),
            Expr::CharLit(c) => self.write_line(&format!("(char_lit {})", c)),
            Expr::StrLit(s) => {
                self.write_line(&format!("(str_lit \"{}\")", escape_str(s)));
            }
            Expr::StrInterp(parts) => {
                self.write_line("(str_interp");
                self.indent();
                for part in parts {
                    match part {
                        InterpolationPart::Literal(text) => {
                            self.write_line(&format!("(literal \"{}\")", escape_str(text)));
                        }
                        InterpolationPart::Expression(e) => {
                            self.write_line("(expression");
                            self.indent();
                            self.ve(e);
                            self.dedent();
                            self.write_line(")");
                        }
                    }
                }
                self.dedent();
                self.write_line(")");
            }
            Expr::NullLit => self.write_line("(null_lit)"),
            Expr::VoidLit => self.write_line("(void_lit)"),
            Expr::Ident(name) => self.write_line(&format!("(ident \"{}\")", name)),
            Expr::Assign { target, value } => {
                self.write_line("(assign");
                self.indent();
                self.write_line("(target");
                self.indent();
                self.ve(target);
                self.dedent();
                self.write_line(")");
                self.write_line("(value");
                self.indent();
                self.ve(value);
                self.dedent();
                self.write_line(")");
                self.dedent();
                self.write_line(")");
            }
            Expr::CompoundAssign { op, target, value } => {
                self.write_line("(compound_assign");
                self.indent();
                self.print_compound_assign_op(*op);
                self.write_line("(target");
                self.indent();
                self.ve(target);
                self.dedent();
                self.write_line(")");
                self.write_line("(value");
                self.indent();
                self.ve(value);
                self.dedent();
                self.write_line(")");
                self.dedent();
                self.write_line(")");
            }
            Expr::Binary { op, lhs, rhs } => {
                self.write_line("(binary");
                self.indent();
                self.print_binary_op(*op);
                self.write_line("(lhs");
                self.indent();
                self.ve(lhs);
                self.dedent();
                self.write_line(")");
                self.write_line("(rhs");
                self.indent();
                self.ve(rhs);
                self.dedent();
                self.write_line(")");
                self.dedent();
                self.write_line(")");
            }
            Expr::Unary { op, operand } => {
                self.write_line("(unary");
                self.indent();
                self.print_unary_op(*op);
                self.write_line("(operand");
                self.indent();
                self.ve(operand);
                self.dedent();
                self.write_line(")");
                self.dedent();
                self.write_line(")");
            }
            Expr::RefOf(inner) => {
                self.write_line("(ref_of");
                self.indent();
                self.ve(inner);
                self.dedent();
                self.write_line(")");
            }
            Expr::Deref(inner) => {
                self.write_line("(deref");
                self.indent();
                self.ve(inner);
                self.dedent();
                self.write_line(")");
            }
            Expr::Call {
                callee,
                args,
                type_args,
            } => {
                self.write_line("(call");
                self.indent();
                self.write_line("(callee");
                self.indent();
                self.ve(callee);
                self.dedent();
                self.write_line(")");
                self.print_type_args_option(type_args);
                self.print_expr_list("args", args);
                self.dedent();
                self.write_line(")");
            }
            Expr::MethodCall {
                recv,
                method,
                args,
                type_args,
            } => {
                self.write_line(&format!("(method_call \"{}\"", method));
                self.indent();
                self.write_line("(recv");
                self.indent();
                self.ve(recv);
                self.dedent();
                self.write_line(")");
                self.print_type_args_option(type_args);
                self.print_expr_list("args", args);
                self.dedent();
                self.write_line(")");
            }
            Expr::FieldAccess { recv, field } => {
                self.write_line(&format!("(field_access \"{}\"", field));
                self.indent();
                self.ve(recv);
                self.dedent();
                self.write_line(")");
            }
            Expr::Index { recv, index } => {
                self.write_line("(index");
                self.indent();
                self.write_line("(recv");
                self.indent();
                self.ve(recv);
                self.dedent();
                self.write_line(")");
                self.write_line("(index");
                self.indent();
                self.ve(index);
                self.dedent();
                self.write_line(")");
                self.dedent();
                self.write_line(")");
            }
            Expr::Slice {
                recv,
                start,
                end,
                inclusive,
            } => {
                self.write_line(&format!("(slice (inclusive {})", inclusive));
                self.indent();
                self.write_line("(recv");
                self.indent();
                self.ve(recv);
                self.dedent();
                self.write_line(")");
                self.write_line("(start");
                self.indent();
                self.ve(start);
                self.dedent();
                self.write_line(")");
                self.write_line("(end");
                self.indent();
                self.ve(end);
                self.dedent();
                self.write_line(")");
                self.dedent();
                self.write_line(")");
            }
            Expr::SafeAccess { recv, field } => {
                self.write_line(&format!("(safe_access \"{}\"", field));
                self.indent();
                self.ve(recv);
                self.dedent();
                self.write_line(")");
            }
            Expr::SafeMethodCall {
                recv,
                method,
                args,
                type_args,
            } => {
                self.write_line(&format!("(safe_method_call \"{}\"", method));
                self.indent();
                self.write_line("(recv");
                self.indent();
                self.ve(recv);
                self.dedent();
                self.write_line(")");
                self.print_type_args_option(type_args);
                self.print_expr_list("args", args);
                self.dedent();
                self.write_line(")");
            }
            Expr::Propagate(inner) => {
                self.write_line("(propagate");
                self.indent();
                self.ve(inner);
                self.dedent();
                self.write_line(")");
            }
            Expr::NonNullAssert(inner) => {
                self.write_line("(non_null_assert");
                self.indent();
                self.ve(inner);
                self.dedent();
                self.write_line(")");
            }
            Expr::Elvis { lhs, rhs } => {
                self.write_line("(elvis");
                self.indent();
                self.write_line("(lhs");
                self.indent();
                self.ve(lhs);
                self.dedent();
                self.write_line(")");
                self.write_line("(rhs");
                self.indent();
                self.ve(rhs);
                self.dedent();
                self.write_line(")");
                self.dedent();
                self.write_line(")");
            }
            Expr::ArrayLit { elements, fill } => {
                self.write_line("(array_lit");
                self.indent();
                self.print_expr_list("elements", elements);
                match fill {
                    Some((value, count)) => {
                        self.write_line("(fill");
                        self.indent();
                        self.write_line("(value");
                        self.indent();
                        self.ve(value);
                        self.dedent();
                        self.write_line(")");
                        self.write_line("(count");
                        self.indent();
                        self.ve(count);
                        self.dedent();
                        self.write_line(")");
                        self.dedent();
                        self.write_line(")");
                    }
                    None => self.write_line("(fill (none))"),
                }
                self.dedent();
                self.write_line(")");
            }
            Expr::RecordLit(fields) => {
                self.write_line("(record_lit");
                self.indent();
                if fields.is_empty() {
                    self.write_line("(fields ())");
                } else {
                    self.write_line("(fields");
                    self.indent();
                    for f in fields {
                        self.write_line(&format!("(field \"{}\"", f.name));
                        self.indent();
                        self.ve(&f.value);
                        self.dedent();
                        self.write_line(")");
                    }
                    self.dedent();
                    self.write_line(")");
                }
                self.dedent();
                self.write_line(")");
            }
            Expr::RecordExtend { base, updates } => {
                self.write_line("(record_extend");
                self.indent();
                self.write_line("(base");
                self.indent();
                self.ve(base);
                self.dedent();
                self.write_line(")");
                if updates.is_empty() {
                    self.write_line("(updates ())");
                } else {
                    self.write_line("(updates");
                    self.indent();
                    for f in updates {
                        self.write_line(&format!("(field \"{}\"", f.name));
                        self.indent();
                        self.ve(&f.value);
                        self.dedent();
                        self.write_line(")");
                    }
                    self.dedent();
                    self.write_line(")");
                }
                self.dedent();
                self.write_line(")");
            }
            Expr::Lambda {
                params,
                body,
                is_async,
                return_type,
            } => {
                self.write_line(&format!("(lambda (is_async {})", is_async));
                self.indent();
                self.print_params(params);
                self.print_return_type(return_type);
                match body {
                    LambdaBody::Block(b) => {
                        self.write_line("(body_block");
                        self.indent();
                        self.ve(b);
                        self.dedent();
                        self.write_line(")");
                    }
                    LambdaBody::Expression(b) => {
                        self.write_line("(body_expr");
                        self.indent();
                        self.ve(b);
                        self.dedent();
                        self.write_line(")");
                    }
                }
                self.dedent();
                self.write_line(")");
            }
            Expr::If {
                cond,
                then_branch,
                else_branch,
            } => {
                self.write_line("(if");
                self.indent();
                self.write_line("(cond");
                self.indent();
                self.ve(cond);
                self.dedent();
                self.write_line(")");
                self.write_line("(then");
                self.indent();
                self.ve(then_branch);
                self.dedent();
                self.write_line(")");
                match else_branch {
                    Some(e) => {
                        self.write_line("(else");
                        self.indent();
                        self.ve(e);
                        self.dedent();
                        self.write_line(")");
                    }
                    None => self.write_line("(else (none))"),
                }
                self.dedent();
                self.write_line(")");
            }
            Expr::Block { stmts, trailing } => {
                self.write_line("(block");
                self.indent();
                if stmts.is_empty() {
                    self.write_line("(stmts ())");
                } else {
                    self.write_line("(stmts");
                    self.indent();
                    for s in stmts {
                        self.vs(s);
                    }
                    self.dedent();
                    self.write_line(")");
                }
                match trailing {
                    Some(e) => {
                        self.write_line("(trailing");
                        self.indent();
                        self.ve(e);
                        self.dedent();
                        self.write_line(")");
                    }
                    None => self.write_line("(trailing (none))"),
                }
                self.dedent();
                self.write_line(")");
            }
            Expr::Match { scrutinee, arms } => {
                self.write_line("(match");
                self.indent();
                self.write_line("(scrutinee");
                self.indent();
                self.ve(scrutinee);
                self.dedent();
                self.write_line(")");
                if arms.is_empty() {
                    self.write_line("(arms ())");
                } else {
                    self.write_line("(arms");
                    self.indent();
                    for arm in arms {
                        self.write_line("(arm");
                        self.indent();
                        self.write_line("(pattern");
                        self.indent();
                        self.vp(&arm.pattern);
                        self.dedent();
                        self.write_line(")");
                        match &arm.guard {
                            Some(g) => {
                                self.write_line("(guard");
                                self.indent();
                                self.ve(g);
                                self.dedent();
                                self.write_line(")");
                            }
                            None => self.write_line("(guard (none))"),
                        }
                        self.write_line("(body");
                        self.indent();
                        self.ve(&arm.body);
                        self.dedent();
                        self.write_line(")");
                        self.dedent();
                        self.write_line(")");
                    }
                    self.dedent();
                    self.write_line(")");
                }
                self.dedent();
                self.write_line(")");
            }
            Expr::TypeCast { target, expr, safe } => {
                self.write_line(&format!("(type_cast (safe {})", safe));
                self.indent();
                self.write_line("(target");
                self.indent();
                self.vt(target);
                self.dedent();
                self.write_line(")");
                self.write_line("(expr");
                self.indent();
                self.ve(expr);
                self.dedent();
                self.write_line(")");
                self.dedent();
                self.write_line(")");
            }
            Expr::CastBuilder { expr, target, mode } => {
                self.write_line(&format!("(cast_builder (mode {})", cast_mode_str(*mode)));
                self.indent();
                self.write_line("(expr");
                self.indent();
                self.ve(expr);
                self.dedent();
                self.write_line(")");
                self.write_line("(target");
                self.indent();
                self.vt(target);
                self.dedent();
                self.write_line(")");
                self.dedent();
                self.write_line(")");
            }
            Expr::Atomic(inner) => {
                self.write_line("(atomic");
                self.indent();
                self.ve(inner);
                self.dedent();
                self.write_line(")");
            }
            Expr::Lazy(inner) => {
                self.write_line("(lazy");
                self.indent();
                self.ve(inner);
                self.dedent();
                self.write_line(")");
            }
            Expr::Select(arms) => {
                self.write_line("(select");
                self.indent();
                if arms.is_empty() {
                    self.write_line("(arms ())");
                } else {
                    self.write_line("(arms");
                    self.indent();
                    for arm in arms {
                        match arm {
                            SelectArm::Receive {
                                channel_expr,
                                binding,
                                body,
                            } => {
                                self.write_line("(receive");
                                self.indent();
                                self.write_line("(channel");
                                self.indent();
                                self.ve(channel_expr);
                                self.dedent();
                                self.write_line(")");
                                match binding {
                                    Some(name) => {
                                        self.write_line(&format!("(binding \"{}\")", name));
                                    }
                                    None => self.write_line("(binding (none))"),
                                }
                                self.write_line("(body");
                                self.indent();
                                self.ve(body);
                                self.dedent();
                                self.write_line(")");
                                self.dedent();
                                self.write_line(")");
                            }
                            SelectArm::Timeout { duration, body } => {
                                self.write_line("(timeout");
                                self.indent();
                                self.write_line("(duration");
                                self.indent();
                                self.ve(duration);
                                self.dedent();
                                self.write_line(")");
                                self.write_line("(body");
                                self.indent();
                                self.ve(body);
                                self.dedent();
                                self.write_line(")");
                                self.dedent();
                                self.write_line(")");
                            }
                        }
                    }
                    self.dedent();
                    self.write_line(")");
                }
                self.dedent();
                self.write_line(")");
            }
            Expr::InlineTrait(methods) => {
                self.write_line("(inline_trait");
                self.indent();
                self.print_methods(methods);
                self.dedent();
                self.write_line(")");
            }
        }
    }

    // --- 语句 ---

    fn visit_stmt(&mut self, stmt: StmtId) {
        match &self.arena.stmt(stmt).node {
            Stmt::ValDecl {
                name,
                type_annotation,
                value,
                visibility,
            } => {
                self.write_line(&format!("(val_decl \"{}\"", name));
                self.indent();
                self.print_visibility(*visibility);
                match type_annotation {
                    Some(ty) => {
                        self.write_line("(type");
                        self.indent();
                        self.vt(ty);
                        self.dedent();
                        self.write_line(")");
                    }
                    None => self.write_line("(type (none))"),
                }
                self.write_line("(value");
                self.indent();
                self.ve(value);
                self.dedent();
                self.write_line(")");
                self.dedent();
                self.write_line(")");
            }
            Stmt::VarDecl {
                name,
                type_annotation,
                value,
                visibility,
            } => {
                self.write_line(&format!("(var_decl \"{}\"", name));
                self.indent();
                self.print_visibility(*visibility);
                match type_annotation {
                    Some(ty) => {
                        self.write_line("(type");
                        self.indent();
                        self.vt(ty);
                        self.dedent();
                        self.write_line(")");
                    }
                    None => self.write_line("(type (none))"),
                }
                self.write_line("(value");
                self.indent();
                self.ve(value);
                self.dedent();
                self.write_line(")");
                self.dedent();
                self.write_line(")");
            }
            Stmt::Assignment { target, value } => {
                self.write_line("(assignment");
                self.indent();
                self.write_line("(target");
                self.indent();
                self.ve(target);
                self.dedent();
                self.write_line(")");
                self.write_line("(value");
                self.indent();
                self.ve(value);
                self.dedent();
                self.write_line(")");
                self.dedent();
                self.write_line(")");
            }
            Stmt::FieldAssignment {
                object,
                field,
                value,
            } => {
                self.write_line(&format!("(field_assignment \"{}\"", field));
                self.indent();
                self.write_line("(object");
                self.indent();
                self.ve(object);
                self.dedent();
                self.write_line(")");
                self.write_line("(value");
                self.indent();
                self.ve(value);
                self.dedent();
                self.write_line(")");
                self.dedent();
                self.write_line(")");
            }
            Stmt::CompoundAssignment { target, op, value } => {
                self.write_line("(compound_assignment");
                self.indent();
                self.print_compound_assign_op(*op);
                self.write_line("(target");
                self.indent();
                self.ve(target);
                self.dedent();
                self.write_line(")");
                self.write_line("(value");
                self.indent();
                self.ve(value);
                self.dedent();
                self.write_line(")");
                self.dedent();
                self.write_line(")");
            }
            Stmt::Expression { expr } => {
                self.write_line("(expression_stmt");
                self.indent();
                self.ve(expr);
                self.dedent();
                self.write_line(")");
            }
            Stmt::Return { value } => match value {
                Some(e) => {
                    self.write_line("(return");
                    self.indent();
                    self.ve(e);
                    self.dedent();
                    self.write_line(")");
                }
                None => self.write_line("(return (none))"),
            },
            Stmt::Defer { expr } => {
                self.write_line("(defer");
                self.indent();
                self.ve(expr);
                self.dedent();
                self.write_line(")");
            }
            Stmt::Throw { expr } => {
                self.write_line("(throw");
                self.indent();
                self.ve(expr);
                self.dedent();
                self.write_line(")");
            }
            Stmt::Break => self.write_line("(break)"),
            Stmt::Continue => self.write_line("(continue)"),
            Stmt::For {
                name,
                iterable,
                body,
            } => {
                self.write_line(&format!("(for \"{}\"", name));
                self.indent();
                self.write_line("(iterable");
                self.indent();
                self.ve(iterable);
                self.dedent();
                self.write_line(")");
                self.write_line("(body");
                self.indent();
                self.ve(body);
                self.dedent();
                self.write_line(")");
                self.dedent();
                self.write_line(")");
            }
            Stmt::While { condition, body } => {
                self.write_line("(while");
                self.indent();
                self.write_line("(cond");
                self.indent();
                self.ve(condition);
                self.dedent();
                self.write_line(")");
                self.write_line("(body");
                self.indent();
                self.ve(body);
                self.dedent();
                self.write_line(")");
                self.dedent();
                self.write_line(")");
            }
            Stmt::Loop { body } => {
                self.write_line("(loop");
                self.indent();
                self.write_line("(body");
                self.indent();
                self.ve(body);
                self.dedent();
                self.write_line(")");
                self.dedent();
                self.write_line(")");
            }
        }
    }

    // --- 模式 ---

    fn visit_pattern(&mut self, pat: PatternId) {
        match &self.arena.pattern(pat).node {
            Pattern::Wildcard => self.write_line("(wildcard)"),
            Pattern::Literal(lit) => {
                self.write_line("(pattern_literal");
                self.indent();
                self.print_pattern_literal(lit);
                self.dedent();
                self.write_line(")");
            }
            Pattern::Variable { name } => {
                self.write_line(&format!("(pattern_var \"{}\")", name));
            }
            Pattern::Constructor { name, patterns } => {
                self.write_line(&format!("(pattern_constructor \"{}\"", name));
                self.indent();
                if patterns.is_empty() {
                    self.write_line("(patterns ())");
                } else {
                    self.write_line("(patterns");
                    self.indent();
                    for p in patterns {
                        self.vp(p);
                    }
                    self.dedent();
                    self.write_line(")");
                }
                self.dedent();
                self.write_line(")");
            }
            Pattern::Record { fields } => {
                self.write_line("(pattern_record");
                self.indent();
                if fields.is_empty() {
                    self.write_line("(fields ())");
                } else {
                    self.write_line("(fields");
                    self.indent();
                    for f in fields {
                        self.write_line(&format!("(field \"{}\"", f.name));
                        self.indent();
                        self.vp(&f.pattern);
                        self.dedent();
                        self.write_line(")");
                    }
                    self.dedent();
                    self.write_line(")");
                }
                self.dedent();
                self.write_line(")");
            }
            Pattern::OrPattern { left, right } => {
                self.write_line("(or_pattern");
                self.indent();
                self.write_line("(left");
                self.indent();
                self.vp(left);
                self.dedent();
                self.write_line(")");
                self.write_line("(right");
                self.indent();
                self.vp(right);
                self.dedent();
                self.write_line(")");
                self.dedent();
                self.write_line(")");
            }
            Pattern::Guard { pattern, condition } => {
                self.write_line("(guard_pattern");
                self.indent();
                self.write_line("(pattern");
                self.indent();
                self.vp(pattern);
                self.dedent();
                self.write_line(")");
                self.write_line("(condition");
                self.indent();
                self.ve(condition);
                self.dedent();
                self.write_line(")");
                self.dedent();
                self.write_line(")");
            }
        }
    }
}
impl<'a> Printer<'a> {
    // --- 方法 ---

    fn print_methods(&mut self, methods: &'a [MethodDecl<'a>]) {
        if methods.is_empty() {
            self.write_line("(methods ())");
            return;
        }
        self.write_line("(methods");
        self.indent();
        for m in methods {
            self.print_method(m);
        }
        self.dedent();
        self.write_line(")");
    }

    fn print_method(&mut self, m: &'a MethodDecl<'a>) {
        self.write_line(&format!("(method \"{}\"", m.name));
        self.indent();
        self.print_visibility(m.visibility);
        self.write_line(&format!("(is_async {})(is_override {})", m.is_async, m.is_override));
        self.print_type_params(&m.type_params);
        self.print_params(&m.params);
        self.print_return_type(&m.return_type);
        if let Some(delegate) = &m.delegate {
            self.write_line(&format!(
                "(delegate (trait \"{}\") (method \"{}\"))",
                delegate.trait_name, delegate.method_name
            ));
        } else {
            self.write_line("(delegate (none))");
        }
        if let Some(body) = &m.body {
            self.write_line("(body");
            self.indent();
            self.ve(body);
            self.dedent();
            self.write_line(")");
        } else {
            self.write_line("(body (none))");
        }
        self.dedent();
        self.write_line(")");
    }

    fn print_associated_types(&mut self, assoc: &'a [AssociatedType<'a>]) {
        if assoc.is_empty() {
            self.write_line("(associated_types ())");
            return;
        }
        self.write_line("(associated_types");
        self.indent();
        for at in assoc {
            self.write_line(&format!("(associated_type \"{}\"", at.name));
            self.indent();
            match &at.kind {
                Some(k) => {
                    self.write_line("(kind");
                    self.indent();
                    self.visit_kind(k);
                    self.dedent();
                    self.write_line(")");
                }
                None => self.write_line("(kind (none))"),
            }
            self.dedent();
            self.write_line(")");
        }
        self.dedent();
        self.write_line(")");
    }

    fn print_type_constraints(&mut self, constraints: &[TypeConstraint<'_>]) {
        if constraints.is_empty() {
            self.write_line("(type_constraints ())");
            return;
        }
        self.write_line("(type_constraints");
        self.indent();
        for c in constraints {
            self.write_line(&format!("(constraint \"{}\"", c.type_param));
            self.indent();
            self.vt(&c.concrete_type);
            self.dedent();
            self.write_line(")");
        }
        self.dedent();
        self.write_line(")");
    }

    // --- 可见性/参数/约束 ---

    fn print_visibility(&mut self, vis: Visibility) {
        match vis {
            Visibility::Private => self.write_line("(visibility private)"),
            Visibility::Public => self.write_line("(visibility public)"),
        }
    }

    fn print_type_params(&mut self, params: &'a [TypeParam<'a>]) {
        if params.is_empty() {
            self.write_line("(type_params ())");
            return;
        }
        self.write_line("(type_params");
        self.indent();
        for tp in params {
            self.write_line(&format!("(type_param \"{}\"", tp.name));
            self.indent();
            match &tp.kind {
                Some(k) => {
                    self.write_line("(kind");
                    self.indent();
                    self.visit_kind(k);
                    self.dedent();
                    self.write_line(")");
                }
                None => self.write_line("(kind (none))"),
            }
            self.print_bounds(&tp.bounds);
            self.dedent();
            self.write_line(")");
        }
        self.dedent();
        self.write_line(")");
    }

    fn print_params(&mut self, params: &[Param<'_>]) {
        if params.is_empty() {
            self.write_line("(params ())");
            return;
        }
        self.write_line("(params");
        self.indent();
        for p in params {
            self.write_line(&format!("(param \"{}\"", p.name));
            self.indent();
            match &p.type_annotation {
                Some(ty) => {
                    self.write_line("(type");
                    self.indent();
                    self.vt(ty);
                    self.dedent();
                    self.write_line(")");
                }
                None => self.write_line("(type (none))"),
            }
            self.dedent();
            self.write_line(")");
        }
        self.dedent();
        self.write_line(")");
    }

    fn print_bounds(&mut self, bounds: &[TraitBound<'_>]) {
        if bounds.is_empty() {
            self.write_line("(bounds ())");
            return;
        }
        self.write_line("(bounds");
        self.indent();
        for b in bounds {
            self.write_line(&format!("(trait_bound \"{}\"", b.trait_name));
            self.indent();
            self.print_type_list("type_args", &b.type_args);
            self.dedent();
            self.write_line(")");
        }
        self.dedent();
        self.write_line(")");
    }

    fn print_return_type(&mut self, rt: &Option<TypeRef>) {
        match rt {
            Some(ty) => {
                self.write_line("(return_type");
                self.indent();
                self.vt(ty);
                self.dedent();
                self.write_line(")");
            }
            None => self.write_line("(return_type (none))"),
        }
    }
    fn print_pattern_literal(&mut self, lit: &PatternLiteral<'_>) {
        match lit {
            PatternLiteral::Int(s) => self.write_line(&format!("(int \"{}\")", s)),
            PatternLiteral::Float(s) => self.write_line(&format!("(float \"{}\")", s)),
            PatternLiteral::Bool(b) => self.write_line(&format!("(bool {})", b)),
            PatternLiteral::Char(c) => self.write_line(&format!("(char {})", c)),
            PatternLiteral::String(s) => {
                self.write_line(&format!("(string \"{}\")", escape_str(s)));
            }
            PatternLiteral::Null => self.write_line("(null)"),
        }
    }

    // --- 运算符打印 ---

    impl_print_op!(print_binary_op, BinaryOp, binary_op_str);
    impl_print_op!(print_unary_op, UnaryOp, unary_op_str);
    impl_print_op!(print_compound_assign_op, CompoundAssignOp, compound_assign_op_str);

    // --- 列表/可选辅助 ---

    impl_print_list!(print_expr_list, ExprRef, visit_expr);
    impl_print_list!(print_type_list, TypeRef, visit_type);

    fn print_type_args_option(&mut self, type_args: &Option<Vec<TypeRef>>) {
        match type_args {
            Some(args) if !args.is_empty() => self.print_type_list("type_args", args),
            _ => self.write_line("(type_args ())"),
        }
    }
}

// --- 运算符字符串映射 ---

fn binary_op_str(op: BinaryOp) -> &'static str {
    match op {
        BinaryOp::Add => "add",
        BinaryOp::Sub => "sub",
        BinaryOp::Mul => "mul",
        BinaryOp::Div => "div",
        BinaryOp::Mod => "mod",
        BinaryOp::Eq => "eq",
        BinaryOp::NotEq => "neq",
        BinaryOp::RefEq => "ref_eq",
        BinaryOp::RefNeq => "ref_neq",
        BinaryOp::Lt => "lt",
        BinaryOp::Gt => "gt",
        BinaryOp::LtEq => "lt_eq",
        BinaryOp::GtEq => "gt_eq",
        BinaryOp::And => "and",
        BinaryOp::Or => "or",
        BinaryOp::BitAnd => "bit_and",
        BinaryOp::BitOr => "bit_or",
        BinaryOp::BitXor => "bit_xor",
        BinaryOp::Shl => "shl",
        BinaryOp::Shr => "shr",
        BinaryOp::ConcatList => "concat_list",
        BinaryOp::Range => "range",
        BinaryOp::RangeInclusive => "range_inclusive",
        BinaryOp::Elvis => "elvis",
    }
}

fn unary_op_str(op: UnaryOp) -> &'static str {
    match op {
        UnaryOp::Not => "not",
        UnaryOp::Neg => "neg",
        UnaryOp::BitNot => "bit_not",
    }
}

fn compound_assign_op_str(op: CompoundAssignOp) -> &'static str {
    match op {
        CompoundAssignOp::AddAssign => "add_assign",
        CompoundAssignOp::SubAssign => "sub_assign",
        CompoundAssignOp::MulAssign => "mul_assign",
        CompoundAssignOp::DivAssign => "div_assign",
        CompoundAssignOp::ModAssign => "mod_assign",
        CompoundAssignOp::BitAndAssign => "bit_and_assign",
        CompoundAssignOp::BitOrAssign => "bit_or_assign",
        CompoundAssignOp::BitXorAssign => "bit_xor_assign",
        CompoundAssignOp::ShlAssign => "shl_assign",
        CompoundAssignOp::ShrAssign => "shr_assign",
    }
}

fn cast_mode_str(mode: CastMode) -> &'static str {
    match mode {
        CastMode::To => "to",
        CastMode::TryTo => "try_to",
    }
}

/// 转义字符串中的特殊字符，用于打印带引号的字面量
fn escape_str(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            c if (c as u32) < 0x20 => {
                out.push_str(&format!("\\u{{{:x}}}", c as u32));
            }
            c => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod printer_tests {
    use super::*;
    use bumpalo::Bump;

    fn parse_and_print(src: &str) -> String {
        let arena = Bump::new();
        let mut lexer = Lexer::new(src);
        let mut sink = TokenCollector::new();
        lexer.tokenize_into(&mut sink);
        let tokens = sink.into_tokens();
        let tokens_ref: &[Token<'_>] = arena.alloc_slice_copy(&tokens);
        let mut parser = Parser::new(tokens_ref, &arena, ErrorCollector::new());
        let module = parser.parse_module("test").unwrap();
        let mut printer = Printer::new(&module.arena);
        printer.print_module(&module).to_string()
    }

    #[test]
    fn test_print_empty_module() {
        let out = parse_and_print("");
        assert!(out.contains("(module \"test\""));
    }

    #[test]
    fn test_print_simple_fun() {
        let out = parse_and_print("fun main(): void { println(\"hello\") }");
        assert!(out.contains("(fun_decl \"main\""));
        assert!(out.contains("(is_entry true)"));
        assert!(out.contains("(str_lit \"hello\")"));
    }

    #[test]
    fn test_print_binary_expr() {
        let out = parse_and_print("fun f(): void { val x = 1 + 2 * 3 }");
        assert!(out.contains("(op add)"));
        assert!(out.contains("(op mul)"));
    }

    #[test]
    fn test_print_type_decl_adt() {
        let out = parse_and_print("type Color = | Red | Green | Blue");
        assert!(out.contains("(type_decl \"Color\""));
        assert!(out.contains("(constructor \"Red\""));
        assert!(out.contains("(constructor \"Green\""));
        assert!(out.contains("(constructor \"Blue\""));
    }

    #[test]
    fn test_print_nested_generics() {
        let out = parse_and_print("type Foo = List<List<i32>>");
        assert!(out.contains("(type_generic \"List\""));
        assert!(out.contains("(type_named \"i32\")"));
    }

    #[test]
    fn test_print_record_literal() {
        let out = parse_and_print("fun f(): void { val r = (x: 1, y: 2) }");
        assert!(out.contains("(record_lit"));
        assert!(out.contains("(field \"x\""));
    }

    #[test]
    fn test_print_lambda() {
        let out = parse_and_print("fun f(): void { val g = (x: i32) => x + 1 }");
        assert!(out.contains("(lambda"));
        assert!(out.contains("(body_expr"));
    }

    #[test]
    fn test_print_match() {
        let out = parse_and_print("fun f(x: i32): i32 { match x { _ => 0 } }");
        assert!(out.contains("(match"));
        assert!(out.contains("(wildcard)"));
    }

    #[test]
    fn test_print_import() {
        let out = parse_and_print("import main.foo.{ bar, baz as qux }");
        assert!(out.contains("(import_decl \"main.foo\""));
        assert!(out.contains("(item \"bar\")"));
        assert!(out.contains("(alias \"qux\")"));
    }

    #[test]
    fn test_print_trait_decl() {
        let out = parse_and_print("trait Drawable { fun draw(): void }");
        assert!(out.contains("(trait_decl \"Drawable\""));
        assert!(out.contains("(method \"draw\""));
    }

    #[test]
    fn test_print_string_interpolation() {
        let out = parse_and_print("fun f(): void { println(\"hello {name}!\") }");
        assert!(out.contains("(str_interp"));
        assert!(out.contains("(literal \"hello \")"));
        assert!(out.contains("(ident \"name\")"));
    }

    #[test]
    fn test_print_array_fill() {
        let out = parse_and_print("fun f(): void { val a = [0, ..10] }");
        assert!(out.contains("(array_lit"));
        assert!(out.contains("(fill"));
    }

    #[test]
    fn test_escape_str() {
        assert_eq!(escape_str("hello"), "hello");
        assert_eq!(escape_str("a\"b"), "a\\\"b");
        assert_eq!(escape_str("a\\b"), "a\\\\b");
        assert_eq!(escape_str("a\nb"), "a\\nb");
    }

    #[test]
    fn test_op_str_coverage() {
        // 确保所有运算符都有字符串映射
        assert_eq!(binary_op_str(BinaryOp::Add), "add");
        assert_eq!(binary_op_str(BinaryOp::Elvis), "elvis");
        assert_eq!(unary_op_str(UnaryOp::Not), "not");
        assert_eq!(compound_assign_op_str(CompoundAssignOp::AddAssign), "add_assign");
        assert_eq!(cast_mode_str(CastMode::To), "to");
    }
}
