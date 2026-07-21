//! 抽象语法树（AST）定义
//!
//! 定义 Glue 语言经词法分析与语法分析后产生的所有语法树节点类型，
//! 包括表达式、语句、声明、类型节点、模式以及模块结构。
//! 这些类型是前端（lexer/parser）与后端（语义分析、IR 构建）之间共享的数据契约。

const std = @import("std");

/// 源码位置：行号与列号，用于错误定位
pub const SourceLocation = struct {
    line: u32,
    column: u32,
};

/// AST 节点包装：将源码位置提取到节点外部，减少 union 体积。
/// 通过 @fieldParentPtr("node", ptr) 从 *T 反查 *NodeSlot(T) 获取 loc。
pub fn NodeSlot(comptime T: type) type {
    return struct {
        loc: SourceLocation,
        node: T,
    };
}

/// 可见性修饰：区分私有与公开声明
pub const Visibility = enum {
    private,
    public,
};

/// 二元运算符种类
pub const BinaryOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
    eq,
    not_eq,
    ref_eq,
    ref_neq,
    lt,
    gt,
    lt_eq,
    gt_eq,
    and_op,
    or_op,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
    concat,
    concat_list,
    range,
    range_inclusive,
    elvis,
};

/// 复合赋值运算符种类（如 +=、-=）
pub const CompoundAssignOp = enum {
    add_assign,
    sub_assign,
    mul_assign,
    div_assign,
    mod_assign,
    bit_and_assign,
    bit_or_assign,
    bit_xor_assign,
    shl_assign,
    shr_assign,
};

/// 一元运算符种类
pub const UnaryOp = enum {
    not,
    neg,
    bit_not,
};

/// 类型种类（kind）：用于高阶类型标注，支持星类型与箭头类型
pub const Kind = union(enum) {
    star,
    arrow: struct {
        param: *Kind,
        result: *Kind,
    },
};

/// cast builder 转换模式
/// - to: wrap on overflow（产生 Inf 时 panic，D61 强化），结果类型 = T
/// - try_to: 越界/解析失败/产生 Inf 时返回 Throw<T, CastError>，结果类型 = Throw<T, CastError>
pub const CastMode = enum {
    to,
    try_to,
};

/// 类型语法节点：命名类型、泛型、可空、函数、记录、数组、kind 标注等
pub const TypeNode = union(enum) {
    named: struct {
        name: []const u8,
    },
    self_type: struct {},
    generic: struct {
        name: []const u8,
        args: []*TypeNode,
    },
    nullable: struct {
        inner: *TypeNode,
    },
    /// 借用引用 &T：指向已有对象的引用，共享读写，RC 管理
    ref_type: struct {
        inner: *TypeNode,
    },
    /// 裸指针 *T：绕过 RC，不安全，预留用于 FFI
    raw_ptr: struct {
        inner: *TypeNode,
    },
    function: struct {
        params: []*TypeNode,
        return_type: *TypeNode,
    },
    record: struct {
        fields: []RecordFieldType,
    },
    array: struct {
        element_type: *TypeNode,
        size: ?u64,
    },
    kind_annotated: struct {
        inner: *TypeNode,
        kind: *Kind,
    },
};

/// 返回类型节点的源码位置
pub fn typeNodeLocation(node: *const TypeNode) SourceLocation {
    const slot: *const NodeSlot(TypeNode) = @alignCast(@fieldParentPtr("node", node));
    return slot.loc;
}

/// 模式匹配中的模式：通配符、字面量、变量、构造器、记录、或模式、守卫模式
pub const Pattern = union(enum) {
    wildcard,
    literal: PatternLiteral,
    variable: struct {
        name: []const u8,
    },
    constructor: struct {
        name: []const u8,
        patterns: []*Pattern,
    },
    record: struct {
        fields: []PatternRecordField,
    },
    or_pattern: struct {
        left: *Pattern,
        right: *Pattern,
    },
    guard: struct {
        pattern: *Pattern,
        condition: *Expr,
    },
};

/// 返回模式节点的源码位置
pub fn patternLocation(pat: *const Pattern) SourceLocation {
    const slot: *const NodeSlot(Pattern) = @alignCast(@fieldParentPtr("node", pat));
    return slot.loc;
}

/// 模式匹配中的字面量模式
pub const PatternLiteral = union(enum) {
    int: []const u8,
    float: []const u8,
    bool: bool,
    char: u21,
    string: []const u8,
    null: SourceLocation,
};

/// 记录模式中的字段：字段名与对应子模式
pub const PatternRecordField = struct {
    name: []const u8,
    pattern: *Pattern,
};

/// 函数/lambda 参数
pub const Param = struct {
    location: SourceLocation,
    name: []const u8,
    type_annotation: ?*TypeNode,
};

/// 类型参数：携带名称、kind 约束与 trait 约束
pub const TypeParam = struct {
    location: SourceLocation,
    name: []const u8,
    kind: ?*Kind,
    bounds: []TraitBound,
};

/// trait 约束：trait 名与类型实参
pub const TraitBound = struct {
    trait_name: []const u8,
    type_args: []*TypeNode,
};

/// 类型约束：将类型参数绑定到具体类型
pub const TypeConstraint = struct {
    type_param: []const u8,
    concrete_type: *TypeNode,
};

/// 记录类型字段：字段名与字段类型
pub const RecordFieldType = struct {
    name: []const u8,
    ty: *TypeNode,
};

/// 记录字面量字段：字段名与字段值表达式
pub const RecordFieldExpr = struct {
    name: []const u8,
    value: *Expr,
};

/// 构造器字段：可选字段名与类型（无名时为位置参数）
pub const ConstructorField = struct {
    name: ?[]const u8,
    ty: *TypeNode,
};

/// 字符串插值的组成部分：字面量文本或内嵌表达式
pub const InterpolationPart = union(enum) {
    literal: []const u8,
    expression: *Expr,
};

/// lambda 体：既可以是块表达式，也可以是普通表达式
pub const LambdaBody = union(enum) {
    block: *Expr,
    expression: *Expr,
};

/// match 表达式的一个分支：模式、可选守卫与分支体
pub const MatchArm = struct {
    pattern: *Pattern,
    guard: ?*Expr,
    body: *Expr,
};

/// select 表达式的一个分支：接收通道消息或超时
pub const SelectArm = union(enum) {
    receive: struct {
        location: SourceLocation,
        channel_expr: *Expr,
        binding: ?[]const u8,
        body: *Expr,
    },
    timeout: struct {
        location: SourceLocation,
        duration: *Expr,
        body: *Expr,
    },
};

/// import 语句中的单个导入项：名称与可选别名
pub const ImportItem = struct {
    name: []const u8,
    alias: ?[]const u8,
};

/// 构造器定义：名称、字段列表与可选返回类型
pub const ConstructorDef = struct {
    location: SourceLocation,
    name: []const u8,
    fields: []ConstructorField,
    return_type: ?*TypeNode,
};

/// 类型定义体：代数数据类型、记录、别名、新类型、错误新类型
pub const TypeDef = union(enum) {
    adt: struct {
        constructors: []ConstructorDef,
    },
    record: struct {
        fields: []RecordFieldType,
    },
    alias: struct {
        target: *TypeNode,
    },
    newtype: struct {
        name: []const u8,
        inner: *TypeNode,
    },
    error_newtype: struct {
        name: []const u8,
        params: []Param,
    },
};

/// 方法声明：名称、类型参数、参数、返回类型、可选方法体、是否覆盖、委托信息
pub const MethodDecl = struct {
    location: SourceLocation,
    name: []const u8,
    type_params: []TypeParam,
    params: []Param,
    return_type: ?*TypeNode,
    body: ?*Expr,
    is_override: bool,
    delegate: ?DelegateInfo = null,
    visibility: Visibility = .private,
};

/// 委托信息：将方法委托给某个 trait 的某个方法
pub const DelegateInfo = struct {
    trait_name: []const u8,
    method_name: []const u8,
};

/// trait 中的关联类型声明
pub const AssociatedType = struct {
    location: SourceLocation,
    name: []const u8,
    kind: ?*Kind,
};

/// 表达式节点：涵盖字面量、标识符、各种运算、调用、控制流、模式匹配等全部表达式形式
pub const Expr = union(enum) {
    int_literal: struct {
        raw: []const u8,
        suffix: ?[]const u8,
    },
    float_literal: struct {
        raw: []const u8,
        suffix: ?[]const u8,
    },
    bool_literal: struct {
        value: bool,
    },
    char_literal: struct {
        value: u21,
    },
    string_literal: struct {
        value: []const u8,
    },
    string_interpolation: struct {
        parts: []InterpolationPart,
    },
    null_literal,
    unit_literal,
    identifier: struct {
        name: []const u8,
    },
    assignment_expr: struct {
        target: *Expr,
        value: *Expr,
    },
    compound_assign: struct {
        op: CompoundAssignOp,
        target: *Expr,
        value: *Expr,
    },
    binary: struct {
        op: BinaryOp,
        left: *Expr,
        right: *Expr,
    },
    unary: struct {
        op: UnaryOp,
        operand: *Expr,
    },
    /// 取引用 &expr：获取指向 expr 的借用引用
    ref_of: struct {
        operand: *Expr,
    },
    /// 解引用 *expr：读取引用指向的值
    deref: struct {
        operand: *Expr,
    },
    call: struct {
        callee: *Expr,
        arguments: []*Expr,
        type_args: ?[]*TypeNode,
    },
    method_call: struct {
        object: *Expr,
        method: []const u8,
        arguments: []*Expr,
        type_args: ?[]*TypeNode,
    },
    field_access: struct {
        object: *Expr,
        field: []const u8,
    },
    safe_access: struct {
        object: *Expr,
        field: []const u8,
    },
    safe_method_call: struct {
        object: *Expr,
        method: []const u8,
        arguments: []*Expr,
        type_args: ?[]*TypeNode,
    },
    non_null_assert: struct {
        expr: *Expr,
    },
    propagate: struct {
        expr: *Expr,
    },
    index: struct {
        object: *Expr,
        index: *Expr,
    },
    /// 切片表达式：obj[start..end] 或 obj[start..=end]
    /// object 可以是数组或字符串；inclusive=true 时 end 包含在结果中
    slice: struct {
        object: *Expr,
        start: *Expr,
        end: *Expr,
        inclusive: bool,
    },
    array_literal: struct {
        elements: []*Expr,
        /// 数组填充语法 [value, ..count]：用 fill_value 重复 count 次创建数组
        /// 当 fill_value 非 null 时，elements 必须恰好 1 个元素（作为填充值）
        fill_value: ?*Expr = null,
        fill_count: ?*Expr = null,
    },
    record_literal: struct {
        fields: []RecordFieldExpr,
    },
    record_extend: struct {
        base: *Expr,
        updates: []RecordFieldExpr,
    },
    lambda: struct {
        params: []Param,
        body: LambdaBody,
        is_async: bool = false,
        return_type: ?*TypeNode = null,
    },
    if_expr: struct {
        condition: *Expr,
        then_branch: *Expr,
        else_branch: ?*Expr,
    },
    block: struct {
        statements: []*Stmt,
        trailing_expr: ?*Expr,
    },
    match: struct {
        scrutinee: *Expr,
        arms: []MatchArm,
    },
    type_cast: struct {
        target_type: *TypeNode,
        expr: *Expr,
        /// true = 安全转换（i32(x)?），越界抛出错误（? 错误传播），结果类型为 target_type
        /// false = 不安全转换（i32(x)），结果类型为 target_type，wrap/饱和
        safe: bool = false,
    },
    /// cast builder 表达式（Phase 3 新语法）
    /// 语法形式：cast(expr).to(T) / cast(expr).try_to(T)
    /// - to: wrap on overflow，产生 Inf 时 panic（D61 强化），结果类型 = T
    /// - try_to: 越界 / 解析失败 / 产生 Inf 时返回 Throw<T, CastError>，结果类型 = Throw<T, CastError>
    cast_builder: struct {
        expr: *Expr,
        target_type: *TypeNode,
        mode: CastMode,
    },
    atomic_expr: struct {
        value: *Expr,
    },
    lazy: struct {
        expr: *Expr,
    },
    spawn_expr: struct {
        expr: *Expr,
    },
    select: struct {
        arms: []SelectArm,
    },
    inline_trait_value: struct {
        methods: []MethodDecl,
    },
};

/// 语句节点：声明、赋值、控制流（return/throw/break/continue）、循环等
pub const Stmt = union(enum) {
    val_decl: struct {
        name: []const u8,
        type_annotation: ?*TypeNode,
        value: *Expr,
        visibility: Visibility = .private,
    },
    var_decl: struct {
        name: []const u8,
        type_annotation: ?*TypeNode,
        value: *Expr,
        visibility: Visibility = .private,
    },
    assignment: struct {
        target: *Expr,
        value: *Expr,
    },
    field_assignment: struct {
        object: *Expr,
        field: []const u8,
        value: *Expr,
    },
    compound_assignment: struct {
        target: *Expr,
        op: CompoundAssignOp,
        value: *Expr,
    },
    expression: struct {
        expr: *Expr,
    },
    return_stmt: struct {
        value: ?*Expr,
    },
    defer_stmt: struct {
        expr: *Expr,
    },
    throw_stmt: struct {
        location: SourceLocation,
        expr: *Expr,
    },
    break_stmt: struct {},
    continue_stmt: struct {},
    for_stmt: struct {
        name: []const u8,
        iterable: *Expr,
        body: *Expr,
    },
    while_stmt: struct {
        condition: *Expr,
        body: *Expr,
    },
    loop_stmt: struct {
        body: *Expr,
    },

    /// 返回该语句的源码位置
    pub fn getLocation(self: *const Stmt) SourceLocation {
        const slot: *const NodeSlot(Stmt) = @alignCast(@fieldParentPtr("node", self));
        return slot.loc;
    }
};

/// 顶层声明：函数、类型、trait、import、pack、表达式声明
pub const Decl = union(enum) {
    fun_decl: struct {
        location: SourceLocation,
        visibility: Visibility,
        name: []const u8,
        type_params: []TypeParam,
        params: []Param,
        return_type: ?*TypeNode,
        bounds: []TraitBound,
        body: *Expr,
        is_async: bool = false,
        is_entry: bool = false,
    },
    type_decl: struct {
        location: SourceLocation,
        visibility: Visibility,
        name: []const u8,
        type_params: []TypeParam,
        implemented_traits: []TraitBound,
        type_constraints: []TypeConstraint,
        def: TypeDef,
        methods: []MethodDecl,
    },
    trait_decl: struct {
        location: SourceLocation,
        visibility: Visibility,
        name: []const u8,
        type_params: []TypeParam,
        parents: []TraitBound,
        associated_types: []AssociatedType,
        methods: []MethodDecl,
    },
    import_decl: struct {
        location: SourceLocation,
        module_path: [][]const u8,
        items: ?[]ImportItem,
        visibility: Visibility = .private,
    },
    pack_decl: struct {
        location: SourceLocation,
        visibility: Visibility,
        name: []const u8,
    },
    expr_decl: struct {
        location: SourceLocation,
        expr: *Expr,
        stmt: ?*Stmt = null,
    },
};

/// 模块：名称、源码路径与顶层声明列表
pub const Module = struct {
    name: []const u8,
    source_path: ?[]const u8,
    declarations: []Decl,
};

/// 返回表达式节点的源码位置
pub fn exprLocation(expr: *const Expr) SourceLocation {
    const slot: *const NodeSlot(Expr) = @alignCast(@fieldParentPtr("node", expr));
    return slot.loc;
}
