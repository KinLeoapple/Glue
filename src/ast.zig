//! Glue 语言 AST（抽象语法树）定义
//!
//! 本文件定义了 Glue 语言的所有 AST 节点类型，涵盖：
//! - 源位置 (SourceLocation)
//! - 类型注解 (TypeNode)
//! - Kind 系统 (Kind) — 用于 HKT
//! - 模式 (Pattern) — 用于 match 表达式
//! - 表达式 (Expr)
//! - 语句 (Stmt)
//! - 顶层声明 (Decl)
//! - 编译模块 (Module)

const std = @import("std");

// ============================================================
// 源位置
// ============================================================

/// 源代码位置信息，所有 AST 节点均携带
pub const SourceLocation = struct {
    /// 行号（从 1 开始）
    line: u32,
    /// 列号（从 1 开始）
    column: u32,
};

// ============================================================
// 可见性
// ============================================================

/// 声明的可见性
pub const Visibility = enum {
    /// 默认私有，仅当前模块可见
    private,
    /// 公开，所有模块可见
    public,
};

// ============================================================
// 运算符
// ============================================================

/// 二元运算符
pub const BinaryOp = enum {
    // 算术运算符
    add, // +
    sub, // -
    mul, // *
    div, // /
    mod, // %
    // 比较运算符
    eq, // ==
    not_eq, // !=
    lt, // <
    gt, // >
    lt_eq, // <=
    gt_eq, // >=
    // 逻辑运算符
    and_op, // &&
    or_op, // ||
    // 位运算符
    bit_and, // &
    bit_or, // |
    bit_xor, // ^
    // 字符串拼接
    concat, // +（字符串上下文）
    // 数组/列表拼接
    concat_list, // ++（数组首尾相接）
    // 范围运算符
    range, // ..（开区间）
    range_inclusive, // ..=（闭区间）
    // Elvis 运算符
    elvis, // ??
};

/// 复合赋值运算符
/// 文档 §3.4.2: Atomic<T> 透明操作
/// counter += 1 → fetch_add, counter -= 1 → fetch_sub, etc.
pub const CompoundAssignOp = enum {
    add_assign, // +=
    sub_assign, // -=
    mul_assign, // *=
    div_assign, // /=
    mod_assign, // %=
    bit_and_assign, // &=
    bit_or_assign, // |=
};

/// 一元运算符
pub const UnaryOp = enum {
    /// 逻辑非 !
    not,
    /// 取负 -
    neg,
};

// ============================================================
// Kind 系统（用于 Higher-Kinded Types）
// ============================================================

/// Kind — 类型的类型
///
/// ```
/// Kind        含义             示例
/// *           具体类型         i32, String, bool
/// * -> *      一阶类型构造器   List, Vec, Tree, Array
/// * -> * -> * 二阶类型构造器   Map, Throw
/// (* -> *) -> *  高阶类型构造器  Functor, Monad
/// ```
pub const Kind = union(enum) {
    /// * — 具体类型
    star,
    /// * -> * 等箭头 Kind
    arrow: struct {
        param: *Kind,
        result: *Kind,
    },
};

// ============================================================
// 类型注解
// ============================================================

/// 类型注解节点
pub const TypeNode = union(enum) {
    /// 命名类型：i32, String, MyType
    named: struct {
        location: SourceLocation,
        name: []const u8,
    },

    /// Self 类型：在 trait 或 type 方法中指代当前类型
    self_type: struct {
        location: SourceLocation,
    },

    /// 泛型类型：List<T>, Map<K,V>, Throw<T,E>
    generic: struct {
        location: SourceLocation,
        name: []const u8,
        args: []*TypeNode,
    },

    /// 可空类型：T?
    nullable: struct {
        location: SourceLocation,
        inner: *TypeNode,
    },

    /// 函数类型：A -> B, (A,B) -> C
    function: struct {
        location: SourceLocation,
        params: []*TypeNode,
        return_type: *TypeNode,
    },

    /// 记录类型：(name: Type, ...)
    record: struct {
        location: SourceLocation,
        fields: []RecordFieldType,
    },

    /// 数组类型：T[N]（固定大小）或 T[]（动态）
    array: struct {
        location: SourceLocation,
        element_type: *TypeNode,
        size: ?u64,
    },

    /// Kind 注解类型：F : * -> *（用于 HKT 类型参数约束）
    kind_annotated: struct {
        location: SourceLocation,
        inner: *TypeNode,
        kind: *Kind,
    },
};

// ============================================================
// 模式（用于 match 表达式）
// ============================================================

/// 模式节点
pub const Pattern = union(enum) {
    /// 通配符：_
    wildcard: SourceLocation,

    /// 字面量模式：int, float, bool, char, string, null
    literal: PatternLiteral,

    /// 变量绑定模式：name（绑定匹配值到变量）
    variable: struct {
        location: SourceLocation,
        name: []const u8,
    },

    /// 构造器模式：Name(patterns) — ADT 构造器模式
    /// 如 Circle(r), Cons(x, xs), Ok(value), Error(e)
    constructor: struct {
        location: SourceLocation,
        name: []const u8,
        patterns: []*Pattern,
    },

    /// 记录模式：(field: pattern, ...)
    record: struct {
        location: SourceLocation,
        fields: []PatternRecordField,
    },

    /// 或模式：pattern1 | pattern2
    or_pattern: struct {
        location: SourceLocation,
        left: *Pattern,
        right: *Pattern,
    },

    /// 守卫模式：pattern if condition
    guard: struct {
        location: SourceLocation,
        pattern: *Pattern,
        condition: *Expr,
    },
};

/// 模式中的字面量
pub const PatternLiteral = union(enum) {
    /// 整数字面量（原始文本）
    int: []const u8,
    /// 浮点字面量（原始文本）
    float: []const u8,
    /// 布尔字面量
    bool: bool,
    /// 字符字面量（Unicode 标量值）
    char: u21,
    /// 字符串字面量
    string: []const u8,
    /// null 字面量
    null: SourceLocation,
};

/// 记录模式中的字段
pub const PatternRecordField = struct {
    name: []const u8,
    pattern: *Pattern,
};

// ============================================================
// 通用结构
// ============================================================

/// 函数参数
pub const Param = struct {
    location: SourceLocation,
    /// 参数名
    name: []const u8,
    /// 类型注解（可省略，由类型推断确定）
    type_annotation: ?*TypeNode,
    /// 是否为 var 参数（默认 val）
    is_var: bool,
};

/// 类型参数
pub const TypeParam = struct {
    location: SourceLocation,
    /// 类型参数名
    name: []const u8,
    /// Kind 注解，如 * -> *（用于 HKT）
    kind: ?*Kind,
    /// Trait 约束
    bounds: []TraitBound,
};

/// Trait 约束（bound）
pub const TraitBound = struct {
    /// Trait 名称
    trait_name: []const u8,
    /// Trait 的类型参数
    type_args: []*TypeNode,
};

/// 类型特化约束（用于 with T: ConcreteType 语法）
pub const TypeConstraint = struct {
    /// 被约束的类型参数名
    type_param: []const u8,
    /// 约束为的具体类型
    concrete_type: *TypeNode,
};

/// 记录字段类型（用于类型注解）
pub const RecordFieldType = struct {
    name: []const u8,
    ty: *TypeNode,
};

/// 记录字段表达式（用于记录字面量）
pub const RecordFieldExpr = struct {
    name: []const u8,
    value: *Expr,
};

/// ADT 构造器字段定义
pub const ConstructorField = struct {
    /// 字段名（位置参数为 null）
    name: ?[]const u8,
    /// 字段类型
    ty: *TypeNode,
};

/// 字符串插值片段
pub const InterpolationPart = union(enum) {
    /// 字面量文本
    literal: []const u8,
    /// 插值表达式
    expression: *Expr,
};

/// Lambda 体
pub const LambdaBody = union(enum) {
    /// 块体：fun(params) { stmts; expr }
    block: *Expr,
    /// 表达式体：(params) => expr
    expression: *Expr,
};

/// match 分支
pub const MatchArm = struct {
    /// 匹配模式
    pattern: *Pattern,
    /// 守卫条件（pattern if condition）
    guard: ?*Expr,
    /// 分支体
    body: *Expr,
};

/// select 分支
pub const SelectArm = union(enum) {
    /// 通道接收分支：ch.recv() => name => body
    receive: struct {
        location: SourceLocation,
        /// 通道接收表达式
        channel_expr: *Expr,
        /// 绑定变量名
        binding: ?[]const u8,
        /// 分支体
        body: *Expr,
    },
    /// 超时分支：timeout(ms) => body
    timeout: struct {
        location: SourceLocation,
        /// 超时时长表达式
        duration: *Expr,
        /// 分支体
        body: *Expr,
    },
};

/// import 导入项
pub const ImportItem = struct {
    /// 导入名称
    name: []const u8,
    /// 别名（import X.{Y as Z} 中的 Z）
    alias: ?[]const u8,
};

/// ADT 构造器定义
pub const ConstructorDef = struct {
    location: SourceLocation,
    /// 构造器名称
    name: []const u8,
    /// 构造器字段
    fields: []ConstructorField,
    /// GADT 构造器的返回类型注解（普通 ADT 为 null）
    /// 如 IntLit(i32) : Expr<i32> 中的 Expr<i32>
    return_type: ?*TypeNode,
};

/// 类型定义体
pub const TypeDef = union(enum) {
    /// ADT（和类型/枚举）：
    /// type Shape = | Circle(radius: f64) | Rectangle(width: f64, height: f64)
    adt: struct {
        constructors: []ConstructorDef,
    },

    /// 记录类型（积类型）：
    /// type User = (name: String, age: i32)
    record: struct {
        fields: []RecordFieldType,
    },

    /// 类型别名：
    /// type IntList = List<i32>
    alias: struct {
        target: *TypeNode,
    },

    /// Newtype（零开销包装类型）：
    /// type UserId = UserId(i32)
    newtype: struct {
        /// 构造器名称（与类型名相同）
        name: []const u8,
        /// 内部类型
        inner: *TypeNode,
    },

    /// 错误 newtype（自定义错误类型）：
    /// type FileError: Error = FileError(msg: str) { override fun prefix(self): str { "file error" } }
    error_newtype: struct {
        /// 构造器名称（与类型名相同）
        name: []const u8,
        /// 构造器参数（通常是 msg: str）
        params: []Param,
        /// 方法体（override 的方法，如 prefix）
        methods: []MethodDecl,
    },
};

/// 方法声明（Trait 声明与类型实现中使用）
pub const MethodDecl = struct {
    location: SourceLocation,
    /// 方法名
    name: []const u8,
    /// 类型参数
    type_params: []TypeParam,
    /// 参数列表
    params: []Param,
    /// 返回类型注解
    return_type: ?*TypeNode,
    /// 方法体（null 表示抽象方法，无默认实现）
    body: ?*Expr,
    /// 是否为 override（用于 Trait 组合中的冲突消解）
    is_override: bool,
    /// 委托信息（用于 Trait 组合中的冲突消解）
    /// `fun to_string(self): str = Serializable.to_string` 中的 `Serializable.to_string`
    delegate: ?DelegateInfo = null,
    /// 可见性
    visibility: Visibility = .private,
};

/// 委托信息（Trait 冲突消解中的委托语法）
/// `fun to_string(self): str = Serializable.to_string`
pub const DelegateInfo = struct {
    /// 委托的 Trait 名称（如 "Serializable"）
    trait_name: []const u8,
    /// 委托的方法名（如 "to_string"）
    method_name: []const u8,
};

/// 关联类型声明（Trait 中使用）
pub const AssociatedType = struct {
    location: SourceLocation,
    /// 关联类型名称
    name: []const u8,
    /// Kind 注解
    kind: ?*Kind,
};

/// trait 中的关联类型定义（如 type Item = i32）
pub const AssociatedTypeDef = struct {
    location: SourceLocation,
    /// 关联类型名称
    name: []const u8,
    /// 关联类型的实际类型
    actual_type: *TypeNode,
};

// ============================================================
// 表达式
// ============================================================

/// 表达式节点
pub const Expr = union(enum) {
    /// 整数字面量：42, 42i32, 0xFF, 0o77, 0b1010, 1_000_000
    int_literal: struct {
        location: SourceLocation,
        /// 原始文本（保留进制和分隔符信息）
        raw: []const u8,
        /// 类型后缀：i32, u64 等（null 表示默认 i32）
        suffix: ?[]const u8,
    },

    /// 浮点字面量：3.14, 3.14f32
    float_literal: struct {
        location: SourceLocation,
        /// 原始文本
        raw: []const u8,
        /// 类型后缀：f32, f64 等（null 表示默认 f64）
        suffix: ?[]const u8,
    },

    /// 布尔字面量：true, false
    bool_literal: struct {
        location: SourceLocation,
        value: bool,
    },

    /// 字符字面量：'a'
    char_literal: struct {
        location: SourceLocation,
        /// Unicode 标量值
        value: u21,
    },

    /// 字符串字面量（无插值）："hello"
    string_literal: struct {
        location: SourceLocation,
        value: []const u8,
    },

    /// 字符串插值："text {expr} text"
    /// 表示为字面量文本和插值表达式的交替列表
    string_interpolation: struct {
        location: SourceLocation,
        parts: []InterpolationPart,
    },

    /// null 字面量
    null_literal: SourceLocation,

    /// 单位字面量 ()
    unit_literal: SourceLocation,

    /// 标识符：变量名、函数名、类型名
    identifier: struct {
        location: SourceLocation,
        name: []const u8,
    },

    /// 赋值表达式：target = value（用于 defer 等上下文中）
    assignment_expr: struct {
        location: SourceLocation,
        target: *Expr,
        value: *Expr,
    },

    /// 复合赋值表达式：target op= value
    /// 文档 §3.4.2: counter += 1 映射到 fetch_add，counter &= 0xFF 映射到 fetch_and
    compound_assign: struct {
        location: SourceLocation,
        op: CompoundAssignOp,
        target: *Expr,
        value: *Expr,
    },

    /// 二元运算：left op right
    binary: struct {
        location: SourceLocation,
        op: BinaryOp,
        left: *Expr,
        right: *Expr,
    },

    /// 一元运算：op operand
    unary: struct {
        location: SourceLocation,
        op: UnaryOp,
        operand: *Expr,
    },

    /// 函数调用：callee(arguments)
    /// 如 add(1, 2), max<i32>(a, b), string(42)
    call: struct {
        location: SourceLocation,
        callee: *Expr,
        arguments: []*Expr,
        /// 显式类型参数（泛型函数调用时使用）
        /// 如 channel<i32>(0) 中的 i32
        type_args: ?[]*TypeNode,
    },

    /// 方法调用：object.method(arguments)
    /// 如 name.len(), ch.send(42)
    method_call: struct {
        location: SourceLocation,
        object: *Expr,
        method: []const u8,
        arguments: []*Expr,
        /// 显式类型参数
        type_args: ?[]*TypeNode,
    },

    /// 字段访问：object.field
    /// 如 user.name, config.host
    field_access: struct {
        location: SourceLocation,
        object: *Expr,
        field: []const u8,
    },

    /// 安全字段访问：expr?.field
    /// 如 user?.name — 若 user 为 null 则返回 null
    safe_access: struct {
        location: SourceLocation,
        object: *Expr,
        field: []const u8,
    },

    /// 安全方法调用：expr?.method(arguments)
    /// 如 name?.len() — 若 name 为 null 则返回 null
    safe_method_call: struct {
        location: SourceLocation,
        object: *Expr,
        method: []const u8,
        arguments: []*Expr,
        type_args: ?[]*TypeNode,
    },

    /// 非空断言：expr!
    /// 若值为 null 则运行时 panic
    non_null_assert: struct {
        location: SourceLocation,
        expr: *Expr,
    },

    /// 传播操作符：expr?
    /// 对 T? 提前返回 null，对 Throw<T,E> 提前传播 throw
    propagate: struct {
        location: SourceLocation,
        expr: *Expr,
    },

    /// 索引访问：object[index]
    /// 如 arr[0]
    index: struct {
        location: SourceLocation,
        object: *Expr,
        index: *Expr,
    },

    /// 数组字面量：[1, 2, 3]
    array_literal: struct {
        location: SourceLocation,
        elements: []*Expr,
    },

    /// 记录字面量：(name: "Alice", age: 30)
    record_literal: struct {
        location: SourceLocation,
        fields: []RecordFieldExpr,
    },

    /// 记录扩展/更新：(...record, field: val) 或 (...record, field: new_val)
    /// Phase 3: 文档 §2.12.1 记录操作
    record_extend: struct {
        location: SourceLocation,
        /// 被扩展的记录表达式
        base: *Expr,
        /// 新增或覆盖的字段
        updates: []RecordFieldExpr,
    },

    /// Lambda 表达式：
    /// fun(params) { body } — 块体
    /// (params) => expr — 表达式体
    lambda: struct {
        location: SourceLocation,
        params: []Param,
        body: LambdaBody,
        /// async lambda：调用时返回 Spawn<T> 而非直接执行
        is_async: bool = false,
        /// 显式返回类型注解（`fun name(params): RetType { body }` 语法）
        /// codegen 在 inferExprType 失败时（如 body 调用未注册的嵌套函数）回退到此类型
        return_type: ?*TypeNode = null,
    },

    /// if 表达式：if condition { then } else { else }
    /// Glue 中 if 是表达式，产生值
    if_expr: struct {
        location: SourceLocation,
        condition: *Expr,
        then_branch: *Expr,
        else_branch: ?*Expr,
    },

    /// 块表达式：{ stmts; expr }
    /// 最后一个表达式（如有）为块的值
    block: struct {
        location: SourceLocation,
        statements: []*Stmt,
        /// 尾表达式（块的返回值），null 表示块无返回值
        trailing_expr: ?*Expr,
    },

    /// match 表达式：match expr { patterns => body, ... }
    match: struct {
        location: SourceLocation,
        scrutinee: *Expr,
        arms: []MatchArm,
    },

    /// 类型转换：Type(expr)
    /// 显式类型转换，如 i32(x), f64(a), string(42)
    /// widening 始终合法，narrowing 运行时检查
    type_cast: struct {
        location: SourceLocation,
        target_type: *TypeNode,
        expr: *Expr,
    },

    /// atomic 表达式：atomic expr
    /// 文档 §3.4.1: 在堆上创建原子值，返回 Atomic<T> 引用
    /// atomic 是关键字前缀表达式，不是函数调用
    atomic_expr: struct {
        location: SourceLocation,
        value: *Expr,
    },

    /// lazy 表达式：lazy expr
    /// 延迟求值，首次访问时计算并缓存
    lazy: struct {
        location: SourceLocation,
        expr: *Expr,
    },

    /// select 表达式：多路复用通道操作
    /// select { ch.recv() => v => body, timeout(ms) => body }
    select: struct {
        location: SourceLocation,
        arms: []SelectArm,
    },

    /// 内联 Trait 值：trait { methods }
    /// 如 val logger : Logger = trait { fun log(msg) { ... } }
    inline_trait_value: struct {
        location: SourceLocation,
        methods: []MethodDecl,
    },
};

// ============================================================
// 语句
// ============================================================

/// 语句节点
pub const Stmt = union(enum) {
    /// 不可变绑定：val name [: Type] = expr
    val_decl: struct {
        location: SourceLocation,
        name: []const u8,
        type_annotation: ?*TypeNode,
        value: *Expr,
        /// 可见性
        visibility: Visibility = .private,
    },

    /// 可变绑定：var name [: Type] = expr
    var_decl: struct {
        location: SourceLocation,
        name: []const u8,
        type_annotation: ?*TypeNode,
        value: *Expr,
        /// 可见性
        visibility: Visibility = .private,
    },

    /// 赋值语句：target = value
    assignment: struct {
        location: SourceLocation,
        target: *Expr,
        value: *Expr,
    },

    /// 字段赋值：object.field = value
    field_assignment: struct {
        location: SourceLocation,
        object: *Expr,
        field: []const u8,
        value: *Expr,
    },

    /// 复合赋值语句：target op= value
    /// 文档 §3.4.2: Atomic<T> 透明操作
    compound_assignment: struct {
        location: SourceLocation,
        target: *Expr,
        op: CompoundAssignOp,
        value: *Expr,
    },

    /// 表达式语句（表达式作为语句，丢弃返回值）
    expression: struct {
        location: SourceLocation,
        expr: *Expr,
    },

    /// return 语句：return expr
    /// 通常为隐式（块最后一个表达式），显式用于提前返回
    return_stmt: struct {
        location: SourceLocation,
        value: ?*Expr,
    },

    /// defer 语句：defer expr
    /// 在作用域退出时按 LIFO 顺序执行
    /// 覆盖正常返回 / throw / panic
    defer_stmt: struct {
        location: SourceLocation,
        expr: *Expr,
    },

    /// throw 语句：throw expr
    /// 抛出满足 Error trait 的值，立即终止函数执行
    throw_stmt: struct {
        location: SourceLocation,
        expr: *Expr,
    },

    /// break 语句（跳出循环）
    break_stmt: struct {
        location: SourceLocation,
    },

    /// continue 语句（跳过当前迭代）
    continue_stmt: struct {
        location: SourceLocation,
    },

    /// for 循环：for name in iterable { body }
    /// 要求 iterable 满足 Iterable<T>
    /// 脱糖为 iterator/loop/match 模式
    for_stmt: struct {
        location: SourceLocation,
        /// 迭代变量名
        name: []const u8,
        /// 可迭代表达式
        iterable: *Expr,
        /// 循环体
        body: *Expr,
    },

    /// while 循环：while condition { body }
    while_stmt: struct {
        location: SourceLocation,
        condition: *Expr,
        body: *Expr,
    },

    /// loop 循环：loop { body }
    /// 无限循环，通过 break 退出
    loop_stmt: struct {
        location: SourceLocation,
        body: *Expr,
    },

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

// ============================================================
// 顶层声明
// ============================================================

/// 顶层声明节点
pub const Decl = union(enum) {
    /// 函数声明：fun name<T>(params) : ReturnType with Bounds { body }
    fun_decl: struct {
        location: SourceLocation,
        visibility: Visibility,
        name: []const u8,
        type_params: []TypeParam,
        params: []Param,
        return_type: ?*TypeNode,
        /// Trait 约束（with Bounds）
        bounds: []TraitBound,
        body: *Expr,
        /// async 函数：调用时返回 Spawn<T> 而非直接执行
        is_async: bool = false,
    },

    /// 类型声明：type Name<T>: Trait1, Trait2 = ... { methods }
    /// 涵盖 ADT、记录、别名、newtype、GADT、错误 newtype
    /// 现在支持在定义时实现 trait
    type_decl: struct {
        location: SourceLocation,
        visibility: Visibility,
        name: []const u8,
        type_params: []TypeParam,
        /// 实现的 trait 列表（新增）
        implemented_traits: []TraitBound,
        /// 类型特化约束（新增）：with T: ConcreteType
        type_constraints: []TypeConstraint,
        def: TypeDef,
        /// 方法实现块（新增）
        methods: []MethodDecl,
    },

    /// Trait 声明：trait Name<Params>(Parents) { methods }
    trait_decl: struct {
        location: SourceLocation,
        visibility: Visibility,
        name: []const u8,
        type_params: []TypeParam,
        /// 父 Trait 列表（组合语义）
        parents: []TraitBound,
        /// 关联类型声明
        associated_types: []AssociatedType,
        /// 方法声明（可含默认实现）
        methods: []MethodDecl,
    },

    /// use 声明：use Module.{items}
    /// use Collections.{Map, insert, empty}  — 选择性导入
    /// use Collections.Map                     — 导入整个模块
    /// use Collections.{Map as CMap}           — 别名导入
    /// pub use Collections.{Map}               — 公开再导出
    import_decl: struct {
        location: SourceLocation,
        /// 模块路径，如 ["Collections"] 或 ["Collections", "Map"]
        module_path: [][]const u8,
        /// 导入项列表（null 表示导入整个模块）
        items: ?[]ImportItem,
        /// 可见性（pub import 表示公开再导出）
        visibility: Visibility = .private,
    },

    /// pack 声明：[pub] pack Name
    /// 用于 pack.glue 中声明子模块
    pack_decl: struct {
        location: SourceLocation,
        visibility: Visibility,
        name: []const u8,
    },

    /// 顶层表达式声明（脚本模式）
    /// 用于在模块顶层执行表达式或语句，如 println(42) 或 val x = 1
    expr_decl: struct {
        location: SourceLocation,
        expr: *Expr,
        stmt: ?*Stmt = null,
    },
};

// ============================================================
// 编译模块
// ============================================================

/// 编译模块（一个 .glue 文件对应一个模块）
pub const Module = struct {
    /// 模块名
    name: []const u8,
    /// 源文件路径
    source_path: ?[]const u8,
    /// 模块中的顶层声明
    declarations: []Decl,
};

// ============================================================
// 工具函数
// ============================================================

/// 取任意表达式的源位置（行列）。供求值器在运行时错误中报告位置。
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
