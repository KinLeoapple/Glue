//! 抽象语法树（AST）定义
//!
//! 定义 Glue 语言经词法分析与语法分析后产生的所有语法树节点类型，
//! 包括表达式、语句、声明、类型节点、模式以及模块结构。
//! 这些类型是前端（lexer/parser）与后端（语义分析、VM 编译）之间共享的数据契约。

const std = @import("std");

/// 源码位置：行号与列号，用于错误定位
pub const SourceLocation = struct {
    line: u32,
    column: u32,
};

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
    lt,
    gt,
    lt_eq,
    gt_eq,
    and_op,
    or_op,
    bit_and,
    bit_or,
    bit_xor,
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
};

/// 一元运算符种类
pub const UnaryOp = enum {
    not,
    neg,
};

/// 类型种类（kind）：用于高阶类型标注，支持星类型与箭头类型
pub const Kind = union(enum) {
    star,
    arrow: struct {
        param: *Kind,
        result: *Kind,
    },
};

/// 类型语法节点：命名类型、泛型、可空、函数、记录、数组、kind 标注等
pub const TypeNode = union(enum) {
    named: struct {
        location: SourceLocation,
        name: []const u8,
    },
    self_type: struct {
        location: SourceLocation,
    },
    generic: struct {
        location: SourceLocation,
        name: []const u8,
        args: []*TypeNode,
    },
    nullable: struct {
        location: SourceLocation,
        inner: *TypeNode,
    },
    function: struct {
        location: SourceLocation,
        params: []*TypeNode,
        return_type: *TypeNode,
    },
    record: struct {
        location: SourceLocation,
        fields: []RecordFieldType,
    },
    array: struct {
        location: SourceLocation,
        element_type: *TypeNode,
        size: ?u64,
    },
    kind_annotated: struct {
        location: SourceLocation,
        inner: *TypeNode,
        kind: *Kind,
    },
};

/// 模式匹配中的模式：通配符、字面量、变量、构造器、记录、或模式、守卫模式
pub const Pattern = union(enum) {
    wildcard: SourceLocation,
    literal: PatternLiteral,
    variable: struct {
        location: SourceLocation,
        name: []const u8,
    },
    constructor: struct {
        location: SourceLocation,
        name: []const u8,
        patterns: []*Pattern,
    },
    record: struct {
        location: SourceLocation,
        fields: []PatternRecordField,
    },
    or_pattern: struct {
        location: SourceLocation,
        left: *Pattern,
        right: *Pattern,
    },
    guard: struct {
        location: SourceLocation,
        pattern: *Pattern,
        condition: *Expr,
    },
};

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
    is_var: bool,
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
        methods: []MethodDecl,
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

/// 关联类型的具体定义：名称与实际类型
pub const AssociatedTypeDef = struct {
    location: SourceLocation,
    name: []const u8,
    actual_type: *TypeNode,
};

/// 表达式节点：涵盖字面量、标识符、各种运算、调用、控制流、模式匹配等全部表达式形式
pub const Expr = union(enum) {
    int_literal: struct {
        location: SourceLocation,
        raw: []const u8,
        suffix: ?[]const u8,
    },
    float_literal: struct {
        location: SourceLocation,
        raw: []const u8,
        suffix: ?[]const u8,
    },
    bool_literal: struct {
        location: SourceLocation,
        value: bool,
    },
    char_literal: struct {
        location: SourceLocation,
        value: u21,
    },
    string_literal: struct {
        location: SourceLocation,
        value: []const u8,
    },
    string_interpolation: struct {
        location: SourceLocation,
        parts: []InterpolationPart,
    },
    null_literal: SourceLocation,
    unit_literal: SourceLocation,
    identifier: struct {
        location: SourceLocation,
        name: []const u8,
    },
    assignment_expr: struct {
        location: SourceLocation,
        target: *Expr,
        value: *Expr,
    },
    compound_assign: struct {
        location: SourceLocation,
        op: CompoundAssignOp,
        target: *Expr,
        value: *Expr,
    },
    binary: struct {
        location: SourceLocation,
        op: BinaryOp,
        left: *Expr,
        right: *Expr,
    },
    unary: struct {
        location: SourceLocation,
        op: UnaryOp,
        operand: *Expr,
    },
    call: struct {
        location: SourceLocation,
        callee: *Expr,
        arguments: []*Expr,
        type_args: ?[]*TypeNode,
    },
    method_call: struct {
        location: SourceLocation,
        object: *Expr,
        method: []const u8,
        arguments: []*Expr,
        type_args: ?[]*TypeNode,
    },
    field_access: struct {
        location: SourceLocation,
        object: *Expr,
        field: []const u8,
    },
    safe_access: struct {
        location: SourceLocation,
        object: *Expr,
        field: []const u8,
    },
    safe_method_call: struct {
        location: SourceLocation,
        object: *Expr,
        method: []const u8,
        arguments: []*Expr,
        type_args: ?[]*TypeNode,
    },
    non_null_assert: struct {
        location: SourceLocation,
        expr: *Expr,
    },
    propagate: struct {
        location: SourceLocation,
        expr: *Expr,
    },
    index: struct {
        location: SourceLocation,
        object: *Expr,
        index: *Expr,
    },
    array_literal: struct {
        location: SourceLocation,
        elements: []*Expr,
    },
    record_literal: struct {
        location: SourceLocation,
        fields: []RecordFieldExpr,
    },
    record_extend: struct {
        location: SourceLocation,
        base: *Expr,
        updates: []RecordFieldExpr,
    },
    lambda: struct {
        location: SourceLocation,
        params: []Param,
        body: LambdaBody,
        is_async: bool = false,
        return_type: ?*TypeNode = null,
    },
    if_expr: struct {
        location: SourceLocation,
        condition: *Expr,
        then_branch: *Expr,
        else_branch: ?*Expr,
    },
    block: struct {
        location: SourceLocation,
        statements: []*Stmt,
        trailing_expr: ?*Expr,
    },
    match: struct {
        location: SourceLocation,
        scrutinee: *Expr,
        arms: []MatchArm,
    },
    type_cast: struct {
        location: SourceLocation,
        target_type: *TypeNode,
        expr: *Expr,
    },
    atomic_expr: struct {
        location: SourceLocation,
        value: *Expr,
    },
    lazy: struct {
        location: SourceLocation,
        expr: *Expr,
    },
    select: struct {
        location: SourceLocation,
        arms: []SelectArm,
    },
    inline_trait_value: struct {
        location: SourceLocation,
        methods: []MethodDecl,
    },
};

/// 语句节点：声明、赋值、控制流（return/throw/break/continue）、循环等
pub const Stmt = union(enum) {
    val_decl: struct {
        location: SourceLocation,
        name: []const u8,
        type_annotation: ?*TypeNode,
        value: *Expr,
        visibility: Visibility = .private,
    },
    var_decl: struct {
        location: SourceLocation,
        name: []const u8,
        type_annotation: ?*TypeNode,
        value: *Expr,
        visibility: Visibility = .private,
    },
    assignment: struct {
        location: SourceLocation,
        target: *Expr,
        value: *Expr,
    },
    field_assignment: struct {
        location: SourceLocation,
        object: *Expr,
        field: []const u8,
        value: *Expr,
    },
    compound_assignment: struct {
        location: SourceLocation,
        target: *Expr,
        op: CompoundAssignOp,
        value: *Expr,
    },
    expression: struct {
        location: SourceLocation,
        expr: *Expr,
    },
    return_stmt: struct {
        location: SourceLocation,
        value: ?*Expr,
    },
    defer_stmt: struct {
        location: SourceLocation,
        expr: *Expr,
    },
    throw_stmt: struct {
        location: SourceLocation,
        expr: *Expr,
    },
    break_stmt: struct {
        location: SourceLocation,
    },
    continue_stmt: struct {
        location: SourceLocation,
    },
    for_stmt: struct {
        location: SourceLocation,
        name: []const u8,
        iterable: *Expr,
        body: *Expr,
    },
    while_stmt: struct {
        location: SourceLocation,
        condition: *Expr,
        body: *Expr,
    },
    loop_stmt: struct {
        location: SourceLocation,
        body: *Expr,
    },

    /// 返回该语句的源码位置
    pub fn getLocation(self: Stmt) SourceLocation {
        return switch (self) {
            .val_decl => |v| v.location,
            .var_decl => |v| v.location,
            .assignment => |v| v.location,
            .field_assignment => |v| v.location,
            .expression => |v| v.location,
            .return_stmt => |v| v.location,
            .defer_stmt => |v| v.location,
            .throw_stmt => |v| v.location,
            .break_stmt => |v| v.location,
            .continue_stmt => |v| v.location,
            .for_stmt => |v| v.location,
            .while_stmt => |v| v.location,
            .loop_stmt => |v| v.location,
            .compound_assignment => |v| v.location,
        };
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
    return switch (expr.*) {
        .int_literal => |e| e.location,
        .float_literal => |e| e.location,
        .bool_literal => |e| e.location,
        .char_literal => |e| e.location,
        .string_literal => |e| e.location,
        .string_interpolation => |e| e.location,
        .null_literal => |l| l,
        .unit_literal => |l| l,
        .identifier => |e| e.location,
        .assignment_expr => |e| e.location,
        .binary => |e| e.location,
        .unary => |e| e.location,
        .call => |e| e.location,
        .method_call => |e| e.location,
        .field_access => |e| e.location,
        .safe_access => |e| e.location,
        .safe_method_call => |e| e.location,
        .non_null_assert => |e| e.location,
        .propagate => |e| e.location,
        .index => |e| e.location,
        .array_literal => |e| e.location,
        .record_literal => |e| e.location,
        .record_extend => |e| e.location,
        .lambda => |e| e.location,
        .if_expr => |e| e.location,
        .block => |e| e.location,
        .match => |e| e.location,
        .type_cast => |e| e.location,
        .atomic_expr => |e| e.location,
        .lazy => |e| e.location,
        .select => |e| e.location,
        .inline_trait_value => |e| e.location,
        .compound_assign => |e| e.location,
    };
}

/// 内置类型名常量集合，供语义分析等阶段引用
pub const type_names = struct {
    pub const error_type = "Error";
    pub const str_type = "str";
    pub const spawn_status_type = "SpawnStatus";
};
