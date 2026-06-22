//! Glue 语言运行时值表示
//!
//! 定义求值过程中的所有运行时值类型，包括：
//! - 求值错误和控制流信号
//! - 范围值 (Range)
//! - 错误值 (ErrorValue)
//! - 内建函数类型 (BuiltinFn)
//! - 闭包 (Closure)
//! - 运行时值 (Value) — 所有求值结果的核心联合类型

const std = @import("std");
const ast = @import("ast");
const atomic_mod = @import("atomic");
const channel_mod = @import("channel");
const spawn_mod = @import("spawn");

// ============================================================
// 求值错误
// ============================================================

pub const EvalError = error{
    OutOfMemory,
    TypeMismatch,
    UndefinedVariable,
    ImmutableAssignment,
    NotCallable,
    WrongArity,
    IndexOutOfBounds,
    UnsupportedOperation,
    CircularDependency,
    FileNotFound,
    MissingMain,
    /// 类型检查失败 — 错误已打印到 stderr，阻止后续求值/callMain（文档 D45 先检查后求值）。
    TypeCheckFailed,
};

/// 控制流信号 — 使用 Zig error 机制实现非局部跳转
pub const ControlFlow = error{
    ReturnValue,
    ThrowValue,
    BreakSignal,
    ContinueSignal,
    /// Glue panic — 不可捕获，但允许 defer 执行
    GluePanic,
    /// 尾调用信号 — TCO trampoline 使用
    TailCall,
};

/// 合并的求值错误集
pub const EvalResult = EvalError || ControlFlow;

// ============================================================
// 范围值
// ============================================================

pub const Range = struct {
    start: i128,
    end: i128,
    inclusive: bool, // true = ..=, false = ..

    pub fn contains(self: Range, val: i128) bool {
        if (self.inclusive) {
            return val >= self.start and val <= self.end;
        } else {
            return val >= self.start and val < self.end;
        }
    }

    pub fn len(self: Range) i128 {
        if (self.inclusive) {
            return self.end - self.start + 1;
        } else {
            return self.end - self.start;
        }
    }
};

// ============================================================
// 错误值
// ============================================================

pub const ErrorValue = struct {
    /// 错误类型名（如 "Error"、"FileError"）
    type_name: []const u8,
    message: []const u8,
    /// 是否为 Error 的子类型（文档 2.4.3: FileError <: Error）
    /// 自定义错误类型（type X = Error("...")）自动是 Error 的子类型
    is_error_subtype: bool = false,
};

// ============================================================
// Throw 值（Throw<T, E> 的运行时表示）
// ============================================================

/// Throw<T, E> 的运行时值
/// 文档 2.4.4: Throw<T, E> 的值有两种状态：
/// - Ok(value) — 成功，持有 T 类型的值
/// - Error(message) — 失败，持有错误信息
pub const ThrowValue = union(enum) {
    /// Ok(value) — 成功状态
    ok: *Value,
    /// Error(message) — 失败状态
    err: ErrorValue,
};

// ============================================================
// 内建函数类型
// ============================================================
/// 内建函数指针类型
///
/// 使用 *anyopaque 作为上下文指针以避免与 Evaluator 的循环依赖。
/// 在 eval.zig 中注册内建函数时，将 *Evaluator 转换为 *anyopaque；
/// 调用时，内建函数的 wrapper 将 *anyopaque 转换回 *Evaluator。
pub const BuiltinFn = *const fn (*anyopaque, ?*anyopaque, []const Value) anyerror!Value;

/// 内建函数（带用户上下文）
///
/// ctx: *Evaluator（通过 @ptrCast 传递）
/// user_ctx: 可选的用户上下文指针（如 ErrorNewtypeCtx）
pub const Builtin = struct {
    fn_ptr: BuiltinFn,
    user_ctx: ?*anyopaque = null,
};

// ============================================================
// ADT 值（代数数据类型的运行时表示）
// ============================================================

/// ADT 构造器字段
pub const AdtField = struct {
    /// 字段名（位置参数为 null）
    name: ?[]const u8,
    value: Value,
};

/// ADT 值 — 代数数据类型构造器的运行时实例
///
/// 如 `Circle(3.14)` 创建 AdtValue{ .type_name = "Shape", .constructor = "Circle", .fields = [...] }
/// 如 `Cons(1, Nil)` 创建 AdtValue{ .type_name = "List", .constructor = "Cons", .fields = [...] }
/// 如 `Lt` 创建 AdtValue{ .type_name = "Ordering", .constructor = "Lt", .fields = [] }
pub const AdtValue = struct {
    /// 类型名（如 Shape, List, Ordering）
    type_name: []const u8,
    /// 构造器名（如 Circle, Cons, Lt）
    constructor: []const u8,
    /// 构造器字段值
    fields: []AdtField,
    /// 引用计数（共享 + 写时拷贝；阶段 0 仅就位，未接入释放）
    rc: u32 = 1,
};

// ============================================================
// Newtype 值（零开销包装类型的运行时表示）
// ============================================================

/// Newtype 值 — 单字段 ADT，创建语义不同但运行时零开销的新类型
///
/// 如 `type UserId = UserId(i32)` 声明后，`UserId(42)` 创建
/// NewtypeValue{ .type_name = "UserId", .inner = Value{ .integer = IntValue{ .value = 42 } } }
///
/// 文档 2.14: Newtype — 创建新类型，运行时零开销
/// 术语表: Newtype — 单字段 ADT，创建语义不同但运行时无开销的新类型
pub const NewtypeValue = struct {
    /// 类型名（如 UserId, Celsius）
    type_name: []const u8,
    /// 内部被包装的值
    inner: Value,
    rc: u32 = 1,
};

// ============================================================
// 闭包
// ============================================================

/// 续14/闭包转换：被闭包捕获的可变变量（var）的共享 cell。
/// 帧绑定与所有捕获该 var 的闭包都指向同一 *Cell，使可变状态在帧与闭包间共享，
/// 且 cell 寿命独立于定义帧（escaped 闭包捕获的 var 在帧返回后仍存活，见 makeCounter）。
/// rc：帧 + 各捕获闭包联合持有，归零才释放。透明语义：读经 .inner、写经 setCell，
/// 与 atomic_val 的透明 load/store 同构（但非原子，per-heap 单线程）。
pub const Cell = struct {
    inner: Value,
    rc: u32 = 1,
};


pub const Closure = struct {
    params: []ast.Param,
    body: ast.LambdaBody,
    env: *anyopaque, // *Environment（capture_env）— 不透明指针避免循环依赖
    allocator: std.mem.Allocator,
    /// 续14/闭包转换：引用计数。闭包现持 capture_env（快照的自由变量 val + 共享 cell），
    /// 归零时须 releaseEnv 该 capture_env（否则捕获的值/cell 泄漏，如 len 内 go 捕获的大列表）。
    /// 装箱 rc：闭包值经 clone/retain 复制句柄时 +1，release 时 -1，归零释放 capture_env + 箱体。
    rc: u32 = 1,
    /// capture_env 的释放回调（env.zig 设置，避免 value→env 循环依赖）。归零时调用 env_release_fn(env)。
    /// null 时不释放 env（如旧式 retain 的 env、或无 capture 的场景）。
    env_release_fn: ?*const fn (*anyopaque) void = null,
};

/// 字节码 VM 的闭包值（M1b）。与树遍历器 `Closure`（AST 形态）平行：
/// 这里 func 指向编译后的 `chunk.Function`，以 `*const anyopaque` 存储以打破
/// value↔chunk 循环依赖（chunk.zig import value，故 value 不能 import chunk）。
/// VM 内 @ptrCast 还原为 *const Function。
/// 默认柯里化也由本结构承载（不复用 eval 的 GC 管理的 PartialApplication，避免双重内存模型）：
///   bound_args = 已预绑定的实参；arity 是函数总形参数。
///   bound_args.len + 新实参 == arity → 调用；< → 产生 bound_args 更长的新 vm_closure；> → WrongArity。
/// M1b-1：upvalues 恒空（仅顶层函数作一等值）。M1b-2 起填充捕获的自由变量（含共享 *Cell）。
pub const VmClosure = struct {
    func: *const anyopaque, // *const chunk.Function
    arity: u8,
    upvalues: []Value = &.{},
    bound_args: []Value = &.{}, // 默认柯里化预绑定实参（owned，归零时 release）
    rc: u32 = 1,
    allocator: std.mem.Allocator,
    /// M5c：letrec 自引用 upvalue 索引（-1 = 无）。该 upvalue 指向闭包自身的 cell（递归局部
    /// 函数捕获自身），为**弱引用**：retain/release 都跳过它，避免 cell↔closure 循环泄漏。
    self_upvalue_idx: i32 = -1,
};

// ============================================================
// 一等 Trait 值（Phase 7）
// ============================================================

/// 一等 Trait 值的运行时表示（文档 §4.7）。
/// 概念上是 vtable 指针 + data 载荷的胖指针；这里以方法名 -> 闭包的映射
/// 表示 vtable（接口函数指针），data 以可选 receiver 值表示。
/// - 内联 trait 值 `trait { fun log(msg){...} }`：data 为 null，方法是自由闭包。
/// - 文件模块作为 trait 值：data 为模块记录，方法绑定到模块。
pub const TraitValue = struct {
    /// Trait 名（用于诊断与方法分派校验，可空）
    trait_name: []const u8 = "",
    /// vtable：方法名 -> 实现闭包
    methods: std.StringHashMap(Value),
    /// data 载荷（receiver）；内联 trait 值为 null
    data: ?*Value = null,
    allocator: std.mem.Allocator,
    /// M4d：VM 模式标记。true 表示由 VM 构造（方法为 vm_closure，纯 refcount）；releaseVM 归零时
    /// 释放 methods（key + vm_closure）+ 箱体。eval 模式（false）由 GC 管理，releaseVM no-op。
    vm_owned: bool = false,
    /// VM 模式 ref_count。
    rc: u32 = 1,
};

// ============================================================
// Lazy 值（Phase 7）— 显式惰性求值
// ============================================================

/// 文档 §6.10: `Lazy<T>` 延迟求值，首次访问时计算并缓存。
/// thunk 持有未求值表达式与其闭包环境；cached 持有首次求值后的结果。
pub const LazyValue = struct {
    /// 未求值的表达式（thunk body）
    expr: *ast.Expr,
    /// 求值时所需的环境（*Environment，不透明指针避免循环依赖）
    env: *anyopaque,
    /// 缓存的结果；null 表示尚未求值
    cached: ?Value = null,
    /// 是否已求值（区分 cached 为 null_val 的合法缓存）
    forced: bool = false,
    allocator: std.mem.Allocator,
    /// M4d：VM 模式 thunk —— 编译后的零参闭包（*VmClosure，不透明避免循环）。非空表示由 VM 构造，
    /// force 走 VM 执行（而非 evalExpr）；此时 expr/env 是占位（VM 无 AST/Environment）。
    vm_thunk: ?*anyopaque = null,
    /// VM 模式 ref_count（eval 模式的 lazy 由 GC/lazy_values 列表管理，rc 不用）。
    rc: u32 = 1,
};

// ============================================================
// 并发原语值（Phase 4）— 从 runtime 模块 re-export
// ============================================================

pub const AtomicValue = atomic_mod.AtomicValue;
pub const AtomicType = atomic_mod.AtomicValue.AtomicType;
pub const atomicTypeToIntType = atomic_mod.atomicTypeToIntType;
pub const intTypeToAtomicType = atomic_mod.intTypeToAtomicType;
pub const valueToAtomicRaw = atomic_mod.valueToAtomicRaw;

pub const SpawnStatus = spawn_mod.SpawnStatus;
pub const SpawnHandle = spawn_mod.SpawnHandle;

pub const ChannelValue = channel_mod.ChannelValue;
pub const SenderValue = channel_mod.SenderValue;
pub const ReceiverValue = channel_mod.ReceiverValue;

// ============================================================
// 迭代器值（Iterable/Iterator 协议的运行时表示）
// ============================================================

/// 数组迭代器
pub const ArrayIterator = struct {
    array: []Value,
    index: usize,
};

/// 字符串迭代器（UTF-8 码点）
pub const StringIterator = struct {
    string: []const u8,
    byte_offset: usize,
};

/// 范围迭代器
pub const RangeIterator = struct {
    current: i128,
    end: i128,
    inclusive: bool,
};

// ============================================================
// 整数类型标签
// ============================================================

/// 整数具体类型标签，用于运行时溢出检查
pub const IntType = enum {
    i8,
    i16,
    i32,
    i64,
    i128,
    u8,
    u16,
    u32,
    u64,
    u128,

    /// 该类型是否为有符号整数
    pub fn isSigned(self: IntType) bool {
        return switch (self) {
            .i8, .i16, .i32, .i64, .i128 => true,
            .u8, .u16, .u32, .u64, .u128 => false,
        };
    }

    /// 返回该整数类型的最小值（u128 存储，有符号类型使用二补数表示）
    pub fn minInt(self: IntType) u128 {
        return switch (self) {
            .i8 => @as(u128, @bitCast(@as(i128, std.math.minInt(i8)))),
            .i16 => @as(u128, @bitCast(@as(i128, std.math.minInt(i16)))),
            .i32 => @as(u128, @bitCast(@as(i128, std.math.minInt(i32)))),
            .i64 => @as(u128, @bitCast(@as(i128, std.math.minInt(i64)))),
            .i128 => @as(u128, @bitCast(@as(i128, std.math.minInt(i128)))),
            .u8, .u16, .u32, .u64, .u128 => 0,
        };
    }

    /// 返回该整数类型的最大值
    pub fn maxInt(self: IntType) u128 {
        return switch (self) {
            .i8 => @as(u128, std.math.maxInt(i8)),
            .i16 => @as(u128, std.math.maxInt(i16)),
            .i32 => @as(u128, std.math.maxInt(i32)),
            .i64 => @as(u128, std.math.maxInt(i64)),
            .i128 => @as(u128, @bitCast(@as(i128, std.math.maxInt(i128)))),
            .u8 => std.math.maxInt(u8),
            .u16 => std.math.maxInt(u16),
            .u32 => std.math.maxInt(u32),
            .u64 => std.math.maxInt(u64),
            .u128 => std.math.maxInt(u128),
        };
    }

    /// 检查值是否在该类型的范围内
    /// 有符号类型：将 u128 解释为 i128 进行有符号比较
    /// 无符号类型：直接与 maxInt 比较
    pub fn inRange(self: IntType, val: u128) bool {
        return switch (self) {
            inline .i8, .i16, .i32, .i64, .i128 => |tag| {
                const signed_val: i128 = @bitCast(val);
                const signed_min: i128 = switch (tag) {
                    .i8 => std.math.minInt(i8),
                    .i16 => std.math.minInt(i16),
                    .i32 => std.math.minInt(i32),
                    .i64 => std.math.minInt(i64),
                    .i128 => std.math.minInt(i128),
                    else => unreachable,
                };
                const signed_max: i128 = switch (tag) {
                    .i8 => std.math.maxInt(i8),
                    .i16 => std.math.maxInt(i16),
                    .i32 => std.math.maxInt(i32),
                    .i64 => std.math.maxInt(i64),
                    .i128 => std.math.maxInt(i128),
                    else => unreachable,
                };
                return signed_val >= signed_min and signed_val <= signed_max;
            },
            inline .u8, .u16, .u32, .u64, .u128 => |tag| {
                const unsigned_max: u128 = switch (tag) {
                    .u8 => std.math.maxInt(u8),
                    .u16 => std.math.maxInt(u16),
                    .u32 => std.math.maxInt(u32),
                    .u64 => std.math.maxInt(u64),
                    .u128 => std.math.maxInt(u128),
                    else => unreachable,
                };
                return val <= unsigned_max;
            },
        };
    }

    /// 从类型名称字符串解析
    pub fn fromName(name: []const u8) ?IntType {
        if (std.mem.eql(u8, name, "i8")) return .i8;
        if (std.mem.eql(u8, name, "i16")) return .i16;
        if (std.mem.eql(u8, name, "i32")) return .i32;
        if (std.mem.eql(u8, name, "i64")) return .i64;
        if (std.mem.eql(u8, name, "i128")) return .i128;
        if (std.mem.eql(u8, name, "u8")) return .u8;
        if (std.mem.eql(u8, name, "u16")) return .u16;
        if (std.mem.eql(u8, name, "u32")) return .u32;
        if (std.mem.eql(u8, name, "u64")) return .u64;
        if (std.mem.eql(u8, name, "u128")) return .u128;
        return null;
    }

    /// 返回该整数类型的位宽
    pub fn bitWidth(self: IntType) usize {
        return switch (self) {
            .i8, .u8 => 8,
            .i16, .u16 => 16,
            .i32, .u32 => 32,
            .i64, .u64 => 64,
            .i128, .u128 => 128,
        };
    }
};

/// 带类型标签的整数值
/// value 使用 u128 存储，可表示 u128::MAX
/// 有符号类型的负值以二补数形式存储，通过 type_tag 区分解释方式
pub const IntValue = struct {
    value: u128,
    type_tag: IntType = .i32,

    /// 获取有符号整数值（仅用于有符号类型）
    pub fn signedValue(self: IntValue) i128 {
        return @bitCast(self.value);
    }
};

/// 整数字面量自动推断：返回能容纳该值的最小整数类型
/// 推断顺序：i8 → u8 → i16 → u16 → i32 → u32 → i64 → u64 → i128 → u128
/// 负值只考虑有符号类型
pub fn inferIntType(val: u128) IntType {
    // 文档 §6.12: 无类型后缀、且无显式类型标注的整数字面量，推断为「能容纳该值
    // 的最小类型」。带标注时由声明/形参处的 castValue 按标注类型转换（覆盖此默认）；
    // 带后缀时由 evalIntLiteral 直接采用后缀类型，均不经过本函数。
    const signed_val: i128 = @bitCast(val);
    if (signed_val >= 0) {
        // 非负值：同位宽优先有符号，再无符号，逐级加宽取最小可容纳类型
        if (val <= std.math.maxInt(i8)) return .i8;
        if (val <= std.math.maxInt(u8)) return .u8;
        if (val <= std.math.maxInt(i16)) return .i16;
        if (val <= std.math.maxInt(u16)) return .u16;
        if (val <= std.math.maxInt(i32)) return .i32;
        if (val <= std.math.maxInt(u32)) return .u32;
        if (val <= std.math.maxInt(i64)) return .i64;
        if (val <= std.math.maxInt(u64)) return .u64;
        if (val <= @as(u128, @bitCast(@as(i128, std.math.maxInt(i128))))) return .i128;
        return .u128;
    } else {
        // 负值：只考虑有符号类型，取最小可容纳位宽
        if (signed_val >= std.math.minInt(i8)) return .i8;
        if (signed_val >= std.math.minInt(i16)) return .i16;
        if (signed_val >= std.math.minInt(i32)) return .i32;
        if (signed_val >= std.math.minInt(i64)) return .i64;
        return .i128;
    }
}

/// 整数算术类型提升：返回两个整数类型中较大的类型
/// 规则：较大位宽优先；同位宽不同符号时，提升为有符号类型
pub fn promoteIntTypes(left: IntType, right: IntType) IntType {
    const left_bits = left.bitWidth();
    const right_bits = right.bitWidth();
    if (left_bits > right_bits) return left;
    if (right_bits > left_bits) return right;
    // 同位宽：如果有任一是无符号，提升为下一级有符号类型
    if (!left.isSigned() or !right.isSigned()) {
        return switch (left_bits) {
            8 => .i16,
            16 => .i32,
            32 => .i64,
            64 => .i128,
            128 => .i128,
            else => unreachable,
        };
    }
    return left;
}

// ============================================================
// 浮点类型标签
// ============================================================

/// 浮点具体类型标签，用于运行时精度检查
/// 文档 §2.2: f16/f32/f64/f128
pub const FloatType = enum {
    f16,
    f32,
    f64,
    f128,

    pub fn fromName(name: []const u8) ?FloatType {
        if (std.mem.eql(u8, name, "f16")) return .f16;
        if (std.mem.eql(u8, name, "f32")) return .f32;
        if (std.mem.eql(u8, name, "f64")) return .f64;
        if (std.mem.eql(u8, name, "f128")) return .f128;
        return null;
    }

    /// 返回该浮点类型的位宽
    pub fn bitWidth(self: FloatType) usize {
        return switch (self) {
            .f16 => 16,
            .f32 => 32,
            .f64 => 64,
            .f128 => 128,
        };
    }
};

/// 浮点字面量自动推断：使用往返检查确定最小适用类型
/// 推断顺序：f16 → f32 → f64 → f128
/// 将 f128 值依次尝试转换为 f16/f32/f64 再转回 f128，若相等则该类型可精确表示
pub fn inferFloatType(val: f128) FloatType {
    // 尝试 f16
    const f16_val: f16 = @floatCast(val);
    const f16_rt: f128 = @floatCast(f16_val);
    if (f16_rt == val and !std.math.isNan(f16_val) and !std.math.isInf(f16_val)) return .f16;
    // 尝试 f32
    const f32_val: f32 = @floatCast(val);
    const f32_rt: f128 = @floatCast(f32_val);
    if (f32_rt == val and !std.math.isNan(f32_val) and !std.math.isInf(f32_val)) return .f32;
    // 尝试 f64
    const f64_val: f64 = @floatCast(val);
    const f64_rt: f128 = @floatCast(f64_val);
    if (f64_rt == val and !std.math.isNan(f64_val) and !std.math.isInf(f64_val)) return .f64;
    // 使用 f128
    return .f128;
}

/// 浮点算术类型提升：返回两个浮点类型中较大的类型
pub fn promoteFloatTypes(left: FloatType, right: FloatType) FloatType {
    if (left.bitWidth() >= right.bitWidth()) return left;
    return right;
}

/// 带类型标签的浮点值
/// value 统一使用 f128 存储（所有浮点类型均可精确表示在 f128 中）
/// type_tag 区分 f16/f32/f64/f128，用于：
/// - 类型名推断（valueTypeName）
/// - 精度范围检查（f16/f32 运算结果需验证在对应精度范围内）
/// - impl 方法分派
/// - Atomic<T> 类型标签
pub const FloatValue = struct {
    value: f128,
    type_tag: FloatType = .f64,
};

// ============================================================
// 运行时值
// ============================================================

/// 记录值（积类型 / Product Type）
/// 文档 §2.5.2：记录类型是匿名的，基于结构化匹配
/// type_name 存储创建时的类型名（如 "User"），用于构造器模式匹配
pub const RecordValue = struct {
    type_name: []const u8, // 创建时的类型名，匿名记录字面量为 ""
    fields: std.StringHashMap(Value),
    rc: u32 = 1,
};

/// 部分应用值 — 默认柯里化的运行时表示
/// 文档 §2.8.1: fun add(a: i32, b: i32) : i32 { a + b }
///   val add5 = add(5)  // 部分应用，返回 PartialApplication
///   add5(3)            // => 8
pub const PartialApplication = struct {
    /// 原始函数（闭包或内置函数）
    func: Value,
    /// 已绑定的参数
    bound_args: []Value,
    /// 剩余需要的参数数量
    remaining: usize,
    /// 分配器
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PartialApplication) void {
        for (self.bound_args) |arg| {
            var v = arg;
            v.deinit(self.allocator);
        }
        self.allocator.free(self.bound_args);
    }
};

/// 数组值
pub const ArrayValue = struct {
    elements: []Value,
    fixed_size: ?u64, // null = 动态 T[], non-null = 固定大小 T[N]
    rc: u32 = 1,
};

pub const Value = union(enum) {
    // 基本类型
    integer: IntValue,
    float: FloatValue,
    boolean: bool,
    char_val: u21,
    string: []const u8,
    null_val,
    unit,

    // 复合类型（装箱为指针以支持引用计数共享 + 写时拷贝）
    array: *ArrayValue,
    record: *RecordValue,

    // ADT 值（代数数据类型构造器实例）
    adt: *AdtValue,

    // Newtype 值（零开销包装类型实例）
    newtype: *NewtypeValue,

    // 范围
    range: Range,

    // 闭包
    closure: *Closure,

    /// 字节码 VM 闭包（M1b）：编译后函数 + 捕获的 upvalues。与 closure 并存，
    /// 由 VM 产生/消费；eval 不构造它（但 retain/release/clone 等需识别以保正确性）。
    vm_closure: *VmClosure,

    // 部分应用（默认柯里化）
    partial: *PartialApplication,

    // 内建函数
    builtin: Builtin,

    // 错误值（用于 throw 传播）
    error_val: ErrorValue,

    // Throw 值（Throw<T, E> 的运行时表示）
    throw_val: *ThrowValue,

    // 迭代器（Iterable/Iterator 协议的运行时表示）
    /// 数组迭代器
    array_iterator: *ArrayIterator,
    /// 字符串迭代器（UTF-8 码点）
    string_iterator: *StringIterator,
    /// 范围迭代器
    range_iterator: *RangeIterator,

    // 并发原语值（Phase 4）
    /// Atomic<T> — 跨协程共享原子状态
    atomic_val: *AtomicValue,
    /// Spawn<T> — 协程句柄（线性类型）
    spawn_val: *SpawnHandle,
    /// Channel<T> — CSP 通信通道
    channel_val: *ChannelValue,
    /// Sender<T> — Channel 发送端
    sender_val: *SenderValue,
    /// Receiver<T> — Channel 接收端
    receiver_val: *ReceiverValue,

    /// 一等 Trait 值（Phase 7，文档 §4.6/§4.7）：vtable + data 胖指针
    trait_value: *TraitValue,

    /// Lazy<T> 值（Phase 7，文档 §6.10）：延迟求值 + 首次访问缓存
    lazy_val: *LazyValue,

    /// 续14/闭包转换：被捕获 var 的共享可变 cell。透明语义——读经 evalIdentifier 解包、
    /// 写经 env.set 转发到 cell.inner。帧与捕获闭包共享同一 *Cell（rc 联合持有）。
    cell_val: *Cell,

    /// 装箱构造：分配一个 rc=1 的数组值。
    pub fn makeArray(allocator: std.mem.Allocator, elements: []Value, fixed_size: ?u64) !Value {
        const p = try allocator.create(ArrayValue);
        p.* = ArrayValue{ .elements = elements, .fixed_size = fixed_size, .rc = 1 };
        return Value{ .array = p };
    }

    /// 装箱构造：分配一个 rc=1 的记录值。
    pub fn makeRecord(allocator: std.mem.Allocator, type_name: []const u8, fields: std.StringHashMap(Value)) !Value {
        const p = try allocator.create(RecordValue);
        p.* = RecordValue{ .type_name = type_name, .fields = fields, .rc = 1 };
        return Value{ .record = p };
    }

    /// 引用计数 +1（用于共享绑定/传参，替代深拷贝）。返回自身便于链式。
    /// 仅对带 rc 的堆值有效；基础类型/无 rc 类型原样返回。
    pub fn retain(self: Value) Value {
        switch (self) {
            .adt => |p| p.rc += 1,
            .newtype => |p| p.rc += 1,
            .array => |p| p.rc += 1,
            .record => |p| p.rc += 1,
            .cell_val => |p| p.rc += 1, // 续14/闭包转换：cell 帧+闭包联合持有
            .closure => |p| p.rc += 1, // 续14/闭包转换：闭包 rc，归零释放 capture_env
            .vm_closure => |p| p.rc += 1, // M1b：VM 闭包 rc，归零释放 upvalues
            else => {},
        }
        return self;
    }

    /// 引用计数 -1；归零则递归 release 子值并释放箱体。
    pub fn release(self: Value, allocator: std.mem.Allocator) void {
        switch (self) {
            .adt => |p| {
                if (p.rc > 1) { p.rc -= 1; return; }
                for (p.fields) |*f| f.value.release(allocator);
                allocator.free(p.fields);
                allocator.destroy(p);
            },
            .newtype => |p| {
                if (p.rc > 1) { p.rc -= 1; return; }
                p.inner.release(allocator);
                allocator.destroy(p);
            },
            .array => |p| {
                if (p.rc > 1) { p.rc -= 1; return; }
                for (p.elements) |*e| e.release(allocator);
                allocator.free(p.elements);
                allocator.destroy(p);
            },
            .record => |p| {
                if (p.rc > 1) { p.rc -= 1; return; }
                var it = p.fields.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.*.release(allocator);
                }
                p.fields.deinit();
                allocator.destroy(p);
            },
            .cell_val => |p| {
                // 续14/闭包转换：归零才释放 cell + 其内值（帧与捕获闭包联合持有）。
                if (p.rc > 1) { p.rc -= 1; return; }
                p.inner.release(allocator);
                allocator.destroy(p);
            },
            .closure => |p| {
                // 续14/闭包转换：归零才释放 capture_env（经 env_release_fn）+ 箱体。
                // capture_env 持有快照的 val 值 + 共享 cell；不释放会泄漏（如 go 捕获的大列表）。
                if (p.rc > 1) { p.rc -= 1; return; }
                if (p.env_release_fn) |f| f(p.env);
                p.allocator.destroy(p);
            },
            .vm_closure => |p| {
                // M1b：归零才释放捕获的 upvalues + bound_args + slice + 箱体。func 指向 Program
                // 持有的 Function，不在此释放。
                if (p.rc > 1) { p.rc -= 1; return; }
                for (p.upvalues) |uv| uv.release(allocator);
                if (p.upvalues.len > 0) p.allocator.free(p.upvalues);
                for (p.bound_args) |ba| ba.release(allocator);
                if (p.bound_args.len > 0) p.allocator.free(p.bound_args);
                p.allocator.destroy(p);
            },
            // string 字节由 owned 持有者各自 dupe（生成点 + 借用点 retainOwned 均走 value_allocator）。
            // release 即归还字节。SlabPool 魔数守卫兜底：误传 arena 字节时掩码反查 magic 不符会安全忽略。
            .string => |s| allocator.free(s),
            else => {},
        }
    }

    /// 字节码 VM 专用释放（纯 refcount 模型）。仅 VM 调用；eval 永远走 release（对 throw_val/
    /// error_val 是 no-op，因 eval 的 GC 疏散管理它们）。VM 无 GC，故对这两类用值语义深释放：
    /// 释放壳 + 错误字符串，嵌套值递归 releaseVM（与 retainOwned 的 rc+1 平衡）。其它类型委托 release。
    pub fn releaseVM(self: Value, allocator: std.mem.Allocator) void {
        switch (self) {
            .error_val => |e| {
                allocator.free(e.type_name);
                allocator.free(e.message);
            },
            // M4a：atomic_val 内建原子 ref_count；归零销毁（协程间共享安全）。
            .atomic_val => |av| {
                if (av.unref()) allocator.destroy(av);
            },
            // M4b：channel/sender/receiver 内建原子 ref_count。channel 归零 deinit+destroy；
            // sender/receiver 是轻包装（各持一个 channel ref + 自身分配）——unref channel 后销毁包装。
            .channel_val => |ch| {
                if (ch.unref()) {
                    ch.deinit();
                    allocator.destroy(ch);
                }
            },
            .sender_val => |sv| {
                if (sv.channel.unref()) {
                    sv.channel.deinit();
                    allocator.destroy(sv.channel);
                }
                allocator.destroy(sv);
            },
            .receiver_val => |rv| {
                if (rv.channel.unref()) {
                    rv.channel.deinit();
                    allocator.destroy(rv.channel);
                }
                allocator.destroy(rv);
            },
            .throw_val => |tv| {
                switch (tv.*) {
                    .ok => |v| {
                        v.*.releaseVM(allocator);
                        allocator.destroy(v);
                    },
                    .err => |e| {
                        allocator.free(e.type_name);
                        allocator.free(e.message);
                    },
                }
                allocator.destroy(tv);
            },
            // M4c：cell/vm_closure 必须递归 releaseVM（非 release）——否则嵌套的 atomic/channel
            // 走 release no-op，ref_count 不递减而泄漏。归零才深释放内层。
            .cell_val => |c| {
                if (c.rc > 1) {
                    c.rc -= 1;
                    return;
                }
                c.inner.releaseVM(allocator);
                allocator.destroy(c);
            },
            .vm_closure => |p| {
                if (p.rc > 1) {
                    p.rc -= 1;
                    return;
                }
                for (p.upvalues, 0..) |uv, i| {
                    // M5c：跳过 letrec 弱自引用 upvalue（指向自身 cell，不持计数 → 不释放，避免
                    // 在本闭包正被该 cell 释放时反向再释放 cell 造成 use-after-free）。
                    if (p.self_upvalue_idx >= 0 and i == @as(usize, @intCast(p.self_upvalue_idx))) continue;
                    uv.releaseVM(allocator);
                }
                if (p.upvalues.len > 0) p.allocator.free(p.upvalues);
                for (p.bound_args) |ba| ba.releaseVM(allocator);
                if (p.bound_args.len > 0) p.allocator.free(p.bound_args);
                p.allocator.destroy(p);
            },
            // M4d：VM 模式 lazy —— 归零才释放 thunk 闭包 + 缓存值 + 箱体。eval 模式 lazy（vm_thunk==null）
            // 由 GC/lazy_values 列表管理，此处 no-op（不 destroy，避免双释放）。
            .lazy_val => |lz| {
                if (lz.vm_thunk == null) return; // eval 模式：交给 GC
                if (lz.rc > 1) {
                    lz.rc -= 1;
                    return;
                }
                const thunk: *VmClosure = @ptrCast(@alignCast(lz.vm_thunk.?));
                (Value{ .vm_closure = thunk }).releaseVM(allocator);
                if (lz.cached) |c| c.releaseVM(allocator);
                allocator.destroy(lz);
            },
            // M4d：VM 模式 trait 值 —— 归零才释放 methods（key + vm_closure）+ data + 箱体。
            // eval 模式（vm_owned==false）由 GC 管理，no-op。
            .trait_value => |tv| {
                if (!tv.vm_owned) return;
                if (tv.rc > 1) {
                    tv.rc -= 1;
                    return;
                }
                var it = tv.methods.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.*.releaseVM(allocator);
                }
                tv.methods.deinit();
                if (tv.data) |d| {
                    d.releaseVM(allocator);
                    allocator.destroy(d);
                }
                allocator.destroy(tv);
            },
            else => self.release(allocator),
        }
    }

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .array => |arr| {
                for (arr.elements) |*item| {
                    item.deinit(allocator);
                }
                allocator.free(arr.elements);
            },
            .record => |rv| {
                if (rv.type_name.len > 0) {
                    allocator.free(rv.type_name);
                }
                var iter = rv.fields.iterator();
                while (iter.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    var val = entry.value_ptr.*;
                    val.deinit(allocator);
                }
                rv.fields.deinit();
            },
            .string => |s| {
                allocator.free(s);
            },
            .error_val => |e| {
                allocator.free(e.type_name);
                allocator.free(e.message);
            },
            .throw_val => |tv| {
                switch (tv.*) {
                    .ok => |v| {
                        v.deinit(allocator);
                        allocator.destroy(v);
                    },
                    .err => |e| {
                        allocator.free(e.type_name);
                        allocator.free(e.message);
                    },
                }
                allocator.destroy(tv);
            },
            .adt => {
                // ADT 值由 Evaluator 统一管理（通过 arena allocator），
                // 不在此释放，避免同一 *AdtValue 被多个 Value 引用导致 double-free
            },
            .newtype => {
                // Newtype 值由 Evaluator 统一管理，不在此释放
            },
            .partial => |pa| {
                pa.deinit();
                allocator.destroy(pa);
            },
            .array_iterator, .string_iterator, .range_iterator => {
                // 迭代器由 Evaluator 统一管理，不在此释放
            },
            else => {},
        }
    }

    /// 克隆值 — 用于同 Heap 内的值复制
    ///
    /// 注意：此方法用于同 Heap 内的值复制（如 Environment.define 深拷贝）。
    /// 跨 Heap 传递（spawn 闭包捕获）应使用 env.deepCloneValue，
    /// 它严格按照文档 §5.2 六类规则处理每种类型。
    ///
    /// §5.2 跨 Heap 传递规则对照：
    /// - 基础类型 (integer/float/boolean/char_val/null_val/unit/range): 值拷贝 ✓
    /// - 不可变数据结构 (string/array/record/adt/newtype/error_val/throw_val/partial): 深拷贝 ✓
    /// - 一等 Trait 值: vtable 共享 + data 深拷贝（Phase 7 实现，builtin 视为简化 Trait 值）
    /// - Channel (channel_val/sender_val/receiver_val): 引用传递（ref count）✓
    /// - 函数/闭包 (closure): 此处浅拷贝，跨 Heap 时由 deepCloneValue 深拷贝环境
    /// - Atomic<T> (atomic_val): 浅拷贝（ref count）✓
    pub fn clone(self: Value, allocator: std.mem.Allocator) !Value {        return switch (self) {
            // §5.2 规则 1: 基础类型 — 值拷贝
            .integer => self,
            .float => self,
            .boolean => self,
            .char_val => self,
            .null_val => self,
            .unit => self,
            .builtin => self,
            .range => self,
            // §5.2 规则 2: 不可变数据结构 — 同 Heap 内共享（retain），写时拷贝(COW)保证别名安全。
            // 这把绑定/传参从 O(size) 深拷贝降为 O(1) retain，链表累加从 O(n^2) 变 O(n)。
            .string => |s| Value{ .string = try allocator.dupe(u8, s) },
            .array => self.retain(),
            .record => self.retain(),
            // §5.2 规则 5: 闭包 — 同 Heap 内浅拷贝（rc+1 共享 capture_env）；跨 Heap 由 deepCloneValue 处理
            .closure => |c| {
                c.rc += 1;
                return Value{ .closure = c };
            },
            // M1b：VM 闭包同 Heap 内浅拷贝（rc+1 共享 upvalues）。
            .vm_closure => |c| {
                c.rc += 1;
                return Value{ .vm_closure = c };
            },
            // §5.2 规则 2: 不可变数据结构 — 深拷贝
            .partial => |pa| {
                const new_pa = try allocator.create(PartialApplication);
                const new_args = try allocator.alloc(Value, pa.bound_args.len);
                for (pa.bound_args, 0..) |arg, i| {
                    new_args[i] = try arg.clone(allocator);
                }
                new_pa.* = PartialApplication{
                    .func = try pa.func.clone(allocator),
                    .bound_args = new_args,
                    .remaining = pa.remaining,
                    .allocator = allocator,
                };
                return Value{ .partial = new_pa };
            },
            .adt => self.retain(),
            .newtype => self.retain(),
            .error_val => |e| Value{ .error_val = ErrorValue{
                .type_name = try allocator.dupe(u8, e.type_name),
                .message = try allocator.dupe(u8, e.message),
                .is_error_subtype = e.is_error_subtype,
            } },
            .throw_val => |tv| {
                const new_tv = try allocator.create(ThrowValue);
                switch (tv.*) {
                    .ok => |v| {
                        const cloned_val = try v.clone(allocator);
                        const cloned_ptr = try allocator.create(Value);
                        cloned_ptr.* = cloned_val;
                        new_tv.* = ThrowValue{ .ok = cloned_ptr };
                    },
                    .err => |e| {
                        new_tv.* = ThrowValue{ .err = ErrorValue{
                            .type_name = try allocator.dupe(u8, e.type_name),
                            .message = try allocator.dupe(u8, e.message),
                            .is_error_subtype = e.is_error_subtype,
                        } };
                    },
                }
                return Value{ .throw_val = new_tv };
            },
            // 迭代器：引用语义
            .array_iterator => |ai| Value{ .array_iterator = ai },
            .string_iterator => |si| Value{ .string_iterator = si },
            .range_iterator => |ri| Value{ .range_iterator = ri },
            // 续14/闭包转换：cell — 共享浅拷贝（retain）。clone 用于绑定/传参，cell 的共享
            // 可变语义要求所有持有者指向同一 *Cell，故仅 rc+1，绝不深拷。
            .cell_val => |c| {
                c.rc += 1;
                return Value{ .cell_val = c };
            },
            // §5.2 规则 6: Atomic<T> — 浅拷贝（原子增加引用计数）
            .atomic_val => |av| {
                av.ref();
                return Value{ .atomic_val = av };
            },
            // Spawn<T> 线性类型：clone 不增加副本
            .spawn_val => self,
            // §5.2 规则 4: Channel — 调度器 heap 中，两端只持有引用
            .channel_val => |cv| {
                cv.ref();
                return Value{ .channel_val = cv };
            },
            .sender_val => |sv| {
                sv.ref();
                return Value{ .sender_val = sv };
            },
            .receiver_val => |rv| {
                rv.ref();
                return Value{ .receiver_val = rv };
            },
            // §5.2 规则 3: 一等 Trait 值 — vtable 共享（方法表浅拷贝），data 深拷贝
            .trait_value => |tv| {
                const new_tv = try allocator.create(TraitValue);
                var new_methods = std.StringHashMap(Value).init(allocator);
                var it = tv.methods.iterator();
                while (it.next()) |entry| {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    try new_methods.put(key, try entry.value_ptr.*.clone(allocator));
                }
                var new_data: ?*Value = null;
                if (tv.data) |d| {
                    const dc = try allocator.create(Value);
                    dc.* = try d.clone(allocator);
                    new_data = dc;
                }
                new_tv.* = TraitValue{
                    .trait_name = if (tv.trait_name.len > 0) try allocator.dupe(u8, tv.trait_name) else "",
                    .methods = new_methods,
                    .data = new_data,
                    .allocator = allocator,
                };
                return Value{ .trait_value = new_tv };
            },
            // Lazy<T>：thunk 引用语义共享（保留缓存一致性）
            .lazy_val => self,
        };
    }

    /// M4c：跨 allocator / 跨线程**完整**深拷贝（VM spawn 用）。
    /// 与 clone 不同：array/record 不走 retain（非原子 rc 跨线程不安全），而是按目标 allocator
    /// 重新分配并递归深拷。基础类型值拷；string dupe；atomic/channel/sender/receiver **共享**
    /// （内建原子 ref_count，跨线程安全）—— spawn 深拷捕获 + Atomic/Channel 浅拷语义。
    /// 闭包/trait/lazy/iterator 暂不支持跨线程（返回 error.Unsupported），spawn body 捕获到这些则回退。
    pub fn deepCopyAcross(self: Value, allocator: std.mem.Allocator) !Value {
        return switch (self) {
            .integer, .float, .boolean, .char_val, .null_val, .unit, .range => self,
            .string => |s| Value{ .string = try allocator.dupe(u8, s) },
            .array => |arr| {
                const new_elems = try allocator.alloc(Value, arr.elements.len);
                errdefer allocator.free(new_elems);
                for (arr.elements, 0..) |e, i| new_elems[i] = try e.deepCopyAcross(allocator);
                return try makeArray(allocator, new_elems, arr.fixed_size);
            },
            .record => |rec| {
                const new_rec = try allocator.create(RecordValue);
                var new_fields = std.StringHashMap(Value).init(allocator);
                var it = rec.fields.iterator();
                while (it.next()) |entry| {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    try new_fields.put(key, try entry.value_ptr.*.deepCopyAcross(allocator));
                }
                new_rec.* = RecordValue{
                    .type_name = if (rec.type_name.len > 0) try allocator.dupe(u8, rec.type_name) else "",
                    .fields = new_fields,
                    .rc = 1,
                };
                return Value{ .record = new_rec };
            },
            // 并发原语：内建原子 ref_count，跨线程共享安全（spawn 浅拷语义）。
            .atomic_val => |av| {
                av.ref();
                return Value{ .atomic_val = av };
            },
            .channel_val => |cv| {
                cv.ref();
                return Value{ .channel_val = cv };
            },
            .sender_val => |sv| {
                sv.channel.ref();
                const ns = try allocator.create(SenderValue);
                ns.* = .{ .channel = sv.channel };
                return Value{ .sender_val = ns };
            },
            .receiver_val => |rv| {
                rv.channel.ref();
                const nr = try allocator.create(ReceiverValue);
                nr.* = .{ .channel = rv.channel };
                return Value{ .receiver_val = nr };
            },
            .error_val => |e| Value{ .error_val = ErrorValue{
                .type_name = try allocator.dupe(u8, e.type_name),
                .message = try allocator.dupe(u8, e.message),
                .is_error_subtype = e.is_error_subtype,
            } },
            .throw_val => |tv| {
                const new_tv = try allocator.create(ThrowValue);
                switch (tv.*) {
                    .ok => |v| {
                        const cp = try allocator.create(Value);
                        cp.* = try v.deepCopyAcross(allocator);
                        new_tv.* = ThrowValue{ .ok = cp };
                    },
                    .err => |e| new_tv.* = ThrowValue{ .err = ErrorValue{
                        .type_name = try allocator.dupe(u8, e.type_name),
                        .message = try allocator.dupe(u8, e.message),
                        .is_error_subtype = e.is_error_subtype,
                    } },
                }
                return Value{ .throw_val = new_tv };
            },
            else => error.Unsupported, // closure/trait/lazy/iterator 等暂不支持跨线程 spawn
        };
    }

    /// debug=false: display 模式（顶层字符串无引号，用户友好）
    /// debug=true: repr 模式（字符串带引号，结构化表示）
    pub fn format(self: Value, buf: *std.ArrayList(u8), allocator: std.mem.Allocator, debug: bool) !void {
        switch (self) {
            .integer => |iv| {
                if (iv.type_tag.isSigned()) {
                    try buf.print(allocator, "{}", .{@as(i128, @bitCast(iv.value))});
                } else {
                    try buf.print(allocator, "{}", .{iv.value});
                }
            },
            .float => |fv| try buf.print(allocator, "{d}", .{fv.value}),
            .boolean => |b| try buf.print(allocator, "{}", .{b}),
            .char_val => |c| try buf.print(allocator, "{u}", .{c}),
            .string => |s| if (debug) {
                try buf.print(allocator, "\"{s}\"", .{s});
            } else {
                try buf.print(allocator, "{s}", .{s});
            },
            .null_val => try buf.appendSlice(allocator, "null"),
            .unit => try buf.appendSlice(allocator, "()"),
            .range => |r| {
                if (r.inclusive) {
                    try buf.print(allocator, "{}..={}", .{ r.start, r.end });
                } else {
                    try buf.print(allocator, "{}..{}", .{ r.start, r.end });
                }
            },
            .array => |arr| {
                try buf.appendSlice(allocator, "[");
                for (arr.elements, 0..) |item, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try item.format(buf, allocator, true);
                }
                try buf.appendSlice(allocator, "]");
            },
            .record => |rv| {
                if (rv.type_name.len > 0) {
                    try buf.print(allocator, "{s}(", .{rv.type_name});
                } else {
                    try buf.appendSlice(allocator, "(");
                }
                var iter = rv.fields.iterator();
                var first = true;
                while (iter.next()) |entry| {
                    if (!first) try buf.appendSlice(allocator, ", ");
                    first = false;
                    try buf.print(allocator, "{s}: ", .{entry.key_ptr.*});
                    try entry.value_ptr.*.format(buf, allocator, true);
                }
                try buf.appendSlice(allocator, ")");
            },
            .closure => try buf.appendSlice(allocator, "<closure>"),
            .vm_closure => try buf.appendSlice(allocator, "<fn>"),
            .partial => try buf.appendSlice(allocator, "<partial>"),
            .builtin => try buf.appendSlice(allocator, "<builtin>"),
            .adt => |av| {
                try buf.print(allocator, "{s}", .{av.constructor});
                if (av.fields.len > 0) {
                    try buf.appendSlice(allocator, "(");
                    for (av.fields, 0..) |f, i| {
                        if (i > 0) try buf.appendSlice(allocator, ", ");
                        if (f.name) |n| {
                            try buf.print(allocator, "{s}: ", .{n});
                        }
                        try f.value.format(buf, allocator, true);
                    }
                    try buf.appendSlice(allocator, ")");
                }
            },
            .newtype => |nv| {
                try buf.print(allocator, "{s}(", .{nv.type_name});
                try nv.inner.format(buf, allocator, true);
                try buf.appendSlice(allocator, ")");
            },
            .error_val => |e| try buf.print(allocator, "{s}(\"{s}\")", .{ e.type_name, e.message }),
            .throw_val => |tv| {
                switch (tv.*) {
                    .ok => |v| {
                        try buf.appendSlice(allocator, "Ok(");
                        try v.format(buf, allocator, true);
                        try buf.appendSlice(allocator, ")");
                    },
                    .err => |e| {
                        try buf.print(allocator, "{s}(\"{s}\")", .{ e.type_name, e.message });
                    },
                }
            },
            .array_iterator => try buf.appendSlice(allocator, "<array_iterator>"),
            .string_iterator => try buf.appendSlice(allocator, "<string_iterator>"),
            .range_iterator => try buf.appendSlice(allocator, "<range_iterator>"),
            .atomic_val => try buf.appendSlice(allocator, "<atomic>"),
            .cell_val => |c| try c.inner.format(buf, allocator, debug), // 透明：显示内值
            .spawn_val => try buf.appendSlice(allocator, "<spawn>"),
            .channel_val => try buf.appendSlice(allocator, "<channel>"),
            .sender_val => try buf.appendSlice(allocator, "<sender>"),
            .receiver_val => try buf.appendSlice(allocator, "<receiver>"),
            .trait_value => |tv| {
                if (tv.trait_name.len > 0) {
                    try buf.print(allocator, "<trait {s}>", .{tv.trait_name});
                } else {
                    try buf.appendSlice(allocator, "<trait>");
                }
            },
            .lazy_val => |lz| {
                if (lz.forced) {
                    try buf.appendSlice(allocator, "<lazy forced>");
                } else {
                    try buf.appendSlice(allocator, "<lazy>");
                }
            },
        }
    }

    /// 身份相等：是否引用同一底层内存（区别于语义相等 equals）。
    /// 用于判断 castValue 等是否产生了新值——string 比较 slice 指针，boxed 比较箱体指针，
    /// 标量按值。tag 不同即不同身份。callFunction 用它决定 cast 出的临时是否需要 release。
    pub fn identityEquals(self: Value, other: Value) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .string => |s| s.ptr == other.string.ptr and s.len == other.string.len,
            .array => |a| a == other.array,
            .record => |r| r == other.record,
            .adt => |p| p == other.adt,
            .newtype => |p| p == other.newtype,
            .closure => |c| c == other.closure,
            .vm_closure => |c| c == other.vm_closure,
            .cell_val => |c| c == other.cell_val,
            .partial => |p| p == other.partial,
            .throw_val => |t| t == other.throw_val,
            else => self.equals(other), // 标量/无堆载荷：按值
        };
    }

    pub fn equals(self: Value, other: Value) bool {
        const self_tag = std.meta.activeTag(self);
        const other_tag = std.meta.activeTag(other);
        if (self_tag != other_tag) return false;
        return switch (self) {
            .integer => |iv| iv.value == other.integer.value and iv.type_tag == other.integer.type_tag,
            .float => |fv| fv.value == other.float.value and fv.type_tag == other.float.type_tag,
            .boolean => |b| b == other.boolean,
            .char_val => |c| c == other.char_val,
            .string => |s| std.mem.eql(u8, s, other.string),
            .null_val => true,
            .unit => true,
            .range => |r| r.start == other.range.start and r.end == other.range.end and r.inclusive == other.range.inclusive,
            // 引用相等
            .array => |a| a.elements.ptr == other.array.elements.ptr,
            .record => |r| @intFromPtr(&r) == @intFromPtr(&other.record),
            .adt => |av| av == other.adt, // 引用相等
            .newtype => |nv| nv == other.newtype, // 引用相等
            .closure => |c| c == other.closure,
            .vm_closure => |c| c == other.vm_closure,
            .partial => |pa| pa == other.partial,
            .builtin => |b_val| b_val.fn_ptr == other.builtin.fn_ptr and b_val.user_ctx == other.builtin.user_ctx,
            .error_val => |e| std.mem.eql(u8, e.type_name, other.error_val.type_name) and std.mem.eql(u8, e.message, other.error_val.message),
            .throw_val => |tv| tv == other.throw_val, // 引用相等
            .array_iterator => |ai| ai == other.array_iterator, // 引用相等
            .string_iterator => |si| si == other.string_iterator, // 引用相等
            .range_iterator => |ri| ri == other.range_iterator, // 引用相等
            .atomic_val => |av| av == other.atomic_val, // 引用相等
            .cell_val => |c| c == other.cell_val, // 引用相等（透明解包在使用点完成，此处不应到达）
            .spawn_val => |sh| sh == other.spawn_val, // 引用相等
            .channel_val => |cv| cv == other.channel_val, // 引用相等
            .sender_val => |sv| sv == other.sender_val, // 引用相等
            .receiver_val => |rv| rv == other.receiver_val, // 引用相等
            .trait_value => |tv| tv == other.trait_value, // 引用相等
            .lazy_val => |lz| lz == other.lazy_val, // 引用相等
        };
    }

    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .boolean => |b| b,
            .integer => |iv| iv.value != 0,
            .float => |fv| fv.value != 0.0,
            .null_val => false,
            .unit => false,
            else => true,
        };
    }

    pub fn isNull(self: Value) bool {
        return self == .null_val;
    }

    pub fn asInteger(self: Value) !u128 {
        return switch (self) {
            .integer => |iv| iv.value,
            else => error.TypeMismatch,
        };
    }

    pub fn asFloat(self: Value) !f128 {
        return switch (self) {
            .float => |fv| fv.value,
            .integer => |iv| if (iv.type_tag.isSigned()) @floatFromInt(@as(i128, @bitCast(iv.value))) else @floatFromInt(iv.value),
            else => error.TypeMismatch,
        };
    }

    pub fn asBoolean(self: Value) !bool {
        return switch (self) {
            .boolean => |b| b,
            else => error.TypeMismatch,
        };
    }

    pub fn asString(self: Value) ![]const u8 {
        return switch (self) {
            .string => |s| s,
            else => error.TypeMismatch,
        };
    }
};
