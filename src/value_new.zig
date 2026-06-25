//! Glue 语言运行时值表示 - 16B Value 优化版本
//!
//! 重大变更：Value 从 64 字节缩减到 16 字节
//! - 策略：Tag + Payload 分离（Tagged Union）
//! - 小值内联（int/float/bool/char/null/unit）
//! - 大值装箱（指针统一经 BoxedValue 包装）
//! - 引用计数统一在 BoxedValue 头部
//!
//! 设计文档：docs/value16-implementation-plan.md

const std = @import("std");
const ast = @import("ast");
const atomic_mod = @import("atomic");
const channel_mod = @import("channel");
const spawn_mod = @import("spawn");

// ============================================================
// 错误与控制流（保持不变）
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
    TypeCheckFailed,
};

pub const ControlFlow = error{
    ReturnValue,
    ThrowValue,
    BreakSignal,
    ContinueSignal,
    GluePanic,
    TailCall,
};

pub const EvalResult = EvalError || ControlFlow;

// ============================================================
// 辅助结构（保持不变）
// ============================================================

pub const Range = struct {
    start: i128,
    end: i128,
    inclusive: bool,

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

pub const ErrorValue = struct {
    type_name: []const u8,
    message: []const u8,
    is_error_subtype: bool = false,
};

pub const ThrowValue = union(enum) {
    ok: *Value,
    err: ErrorValue,
};

pub const BuiltinFn = *const fn (*anyopaque, ?*anyopaque, []const Value) anyerror!Value;

pub const Builtin = struct {
    fn_ptr: BuiltinFn,
    user_ctx: ?*anyopaque = null,
};

// ============================================================
// 整数与浮点类型（保持不变）
// ============================================================

pub const IntType = enum {
    i8, i16, i32, i64, i128,
    u8, u16, u32, u64, u128,

    pub fn isSigned(self: IntType) bool {
        return switch (self) {
            .i8, .i16, .i32, .i64, .i128 => true,
            .u8, .u16, .u32, .u64, .u128 => false,
        };
    }

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

pub const FloatType = enum {
    f16, f32, f64, f128,

    pub fn fromName(name: []const u8) ?FloatType {
        if (std.mem.eql(u8, name, "f16")) return .f16;
        if (std.mem.eql(u8, name, "f32")) return .f32;
        if (std.mem.eql(u8, name, "f64")) return .f64;
        if (std.mem.eql(u8, name, "f128")) return .f128;
        return null;
    }

    pub fn bitWidth(self: FloatType) usize {
        return switch (self) {
            .f16 => 16,
            .f32 => 32,
            .f64 => 64,
            .f128 => 128,
        };
    }

    pub fn minFloat(self: FloatType) f128 {
        return switch (self) {
            .f16 => -std.math.floatMax(f16),
            .f32 => -std.math.floatMax(f32),
            .f64 => -std.math.floatMax(f64),
            .f128 => -std.math.floatMax(f128),
        };
    }

    pub fn maxFloat(self: FloatType) f128 {
        return switch (self) {
            .f16 => std.math.floatMax(f16),
            .f32 => std.math.floatMax(f32),
            .f64 => std.math.floatMax(f64),
            .f128 => std.math.floatMax(f128),
        };
    }

    pub fn inRange(self: FloatType, val: f128) bool {
        if (std.math.isNan(val) or std.math.isInf(val)) return false;
        const min = self.minFloat();
        const max = self.maxFloat();
        return val >= min and val <= max;
    }
};

pub const IntValue = struct {
    value: u128,
    type_tag: IntType = .i32,

    pub fn signedValue(self: IntValue) i128 {
        return @bitCast(self.value);
    }
};

/// 带类型标签的浮点值
/// value 使用 f128 存储，可表示所有浮点类型
pub const FloatValue = struct {
    value: f128,
    type_tag: FloatType = .f64,
};

pub fn inferIntType(val: u128) IntType {
    const signed_val: i128 = @bitCast(val);
    if (signed_val >= 0) {
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
        if (signed_val >= std.math.minInt(i8)) return .i8;
        if (signed_val >= std.math.minInt(i16)) return .i16;
        if (signed_val >= std.math.minInt(i32)) return .i32;
        if (signed_val >= std.math.minInt(i64)) return .i64;
        return .i128;
    }
}

pub fn promoteIntTypes(left: IntType, right: IntType) IntType {
    const left_bits = left.bitWidth();
    const right_bits = right.bitWidth();
    if (left_bits > right_bits) return left;
    if (right_bits > left_bits) return right;
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
// 复合值结构（保持不变，将被装箱）
// ============================================================

pub const AdtField = struct {
    name: ?[]const u8,
    value: Value,
};

pub const AdtValue = struct {
    type_name: []const u8,
    constructor: []const u8,
    fields: []AdtField,
    rc: u32 = 1,
};

pub const NewtypeValue = struct {
    type_name: []const u8,
    inner: Value,
    rc: u32 = 1,
};

pub const ArrayValue = struct {
    elements: []Value,
    fixed_size: ?u64 = null,
    rc: u32 = 1,
};

pub const RecordValue = struct {
    type_name: []const u8,
    fields: std.StringHashMap(Value),
    rc: u32 = 1,
};

pub const Cell = struct {
    inner: Value,
    rc: u32 = 1,
};

pub const VmClosure = struct {
    func: *const anyopaque,
    arity: u8,
    upvalues: []Value = &.{},
    bound_args: []Value = &.{},
    rc: u32 = 1,
    allocator: std.mem.Allocator,
    self_upvalue_idx: i32 = -1,
};

pub const PartialApplication = struct {
    func: Value,
    bound_args: []Value,
    remaining_arity: u8,
    rc: u32 = 1,
};

pub const TraitValue = struct {
    trait_name: []const u8 = "",
    methods: std.StringHashMap(Value),
    data: ?*Value = null,
    allocator: std.mem.Allocator,
    vm_owned: bool = false,
    rc: u32 = 1,
};

pub const LazyValue = struct {
    expr: *ast.Expr,
    env: *anyopaque,
    cached: ?Value = null,
    forced: bool = false,
    allocator: std.mem.Allocator,
    vm_thunk: ?*anyopaque = null,
    rc: u32 = 1,
};

pub const ArrayIterator = struct {
    array: []Value,
    index: usize,
};

pub const StringIterator = struct {
    string: []const u8,
    byte_offset: usize,
};

pub const RangeIterator = struct {
    current: i128,
    end: i128,
    inclusive: bool,
};

// 并发原语（re-export）
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
// 16B Value 核心结构
// ============================================================

/// 类型标签（8位，256种类型）
pub const ValueTag = enum(u8) {
    // 内联类型（payload 直接存值，无需堆分配）
    null_val = 0,
    unit = 1,
    boolean = 2,      // payload: 0=false, 1=true
    small_int = 3,    // payload: i48 有符号整数
    char_val = 4,     // payload: u21 Unicode 码点

    // 浮点类型（多精度支持）
    float16 = 5,      // payload: u16 位模式
    float32 = 6,      // payload: u32 位模式
    float64 = 7,      // payload: f64 位模式

    // 装箱类型（payload 存指针，指向 BoxedValue）
    big_int = 10,     // i64/i128/u64/u128 超出 i48 范围
    float128 = 11,    // f128 超出 8字节
    string = 12,
    array = 13,
    record = 14,
    adt = 15,
    newtype = 16,
    range = 17,
    vm_closure = 18,
    partial = 19,
    builtin = 20,
    error_val = 21,
    throw_val = 22,

    // 迭代器
    array_iterator = 30,
    string_iterator = 31,
    range_iterator = 32,

    // 并发原语
    atomic_val = 40,
    spawn_val = 41,
    channel_val = 42,
    sender_val = 43,
    receiver_val = 44,

    // 高级特性
    trait_value = 50,
    lazy_val = 51,
    cell_val = 52,
};

/// 16B Value：tag + payload 分离
pub const Value = struct {
    tag: ValueTag,
    _pad: [7]u8 = undefined, // 对齐到 8 字节边界
    payload: u64,

    // ============================================================
    // 编码函数（构造 Value）
    // ============================================================

    pub inline fn fromNull() Value {
        return .{ .tag = .null_val, .payload = 0 };
    }

    pub inline fn fromUnit() Value {
        return .{ .tag = .unit, .payload = 0 };
    }

    pub inline fn fromBool(b: bool) Value {
        return .{ .tag = .boolean, .payload = if (b) 1 else 0 };
    }

    /// 小整数（-2^47 ~ 2^47-1）直接内联
    pub inline fn fromSmallInt(i: i48) Value {
        return .{ .tag = .small_int, .payload = @bitCast(@as(i64, i)) };
    }

    /// 大整数需要装箱（通过 BoxedValue）
    pub fn fromBigInt(allocator: std.mem.Allocator, int_val: IntValue) !Value {
        const box = try allocator.create(BoxedValue);
        box.* = .{
            .tag = .big_int,
            .rc = 1,
            .payload = .{ .big_int = int_val },
        };
        return .{ .tag = .big_int, .payload = @intFromPtr(box) };
    }

    /// 智能整数编码：小整数内联，大整数装箱
    pub fn fromInt(allocator: std.mem.Allocator, int_val: IntValue) !Value {
        // 检查是否在 i48 范围内
        const signed_val: i128 = @bitCast(int_val.value);
        if (signed_val >= std.math.minInt(i48) and signed_val <= std.math.maxInt(i48)) {
            return fromSmallInt(@intCast(signed_val));
        } else {
            return fromBigInt(allocator, int_val);
        }
    }

    pub inline fn fromChar(c: u21) Value {
        return .{ .tag = .char_val, .payload = c };
    }

    /// 多精度浮点编码（根据FloatValue的type_tag选择）
    pub fn fromFloatValue(allocator: std.mem.Allocator, float_val: FloatValue) !Value {
        return switch (float_val.type_tag) {
            .f16 => {
                const f16_val: f16 = @floatCast(float_val.value);
                const u16_val: u16 = @bitCast(f16_val);
                return .{ .tag = .float16, .payload = u16_val };
            },
            .f32 => {
                const f32_val: f32 = @floatCast(float_val.value);
                const u32_val: u32 = @bitCast(f32_val);
                return .{ .tag = .float32, .payload = u32_val };
            },
            .f64 => {
                const f64_val: f64 = @floatCast(float_val.value);
                return .{ .tag = .float64, .payload = @bitCast(f64_val) };
            },
            .f128 => try fromFloat128(allocator, float_val.value),
        };
    }

    /// f16 编码（2字节内联）
    pub inline fn fromFloat16(f: f16) Value {
        const u16_val: u16 = @bitCast(f);
        return .{ .tag = .float16, .payload = u16_val };
    }

    /// f32 编码（4字节内联）
    pub inline fn fromFloat32(f: f32) Value {
        const u32_val: u32 = @bitCast(f);
        return .{ .tag = .float32, .payload = u32_val };
    }

    /// f64 编码（8字节内联）
    pub inline fn fromFloat64(f: f64) Value {
        return .{ .tag = .float64, .payload = @bitCast(f) };
    }

    /// f128 编码（16字节装箱）
    pub fn fromFloat128(allocator: std.mem.Allocator, f: f128) !Value {
        const box = try allocator.create(BoxedValue);
        box.* = .{
            .tag = .float128,
            .rc = 1,
            .payload = .{ .float128 = f },
        };
        return .{ .tag = .float128, .payload = @intFromPtr(box) };
    }

    /// 向后兼容：统一浮点编码（默认f64）
    pub inline fn fromFloat(f: f64) Value {
        return fromFloat64(f);
    }

    pub inline fn fromString(allocator: std.mem.Allocator, s: []const u8) !Value {
        const box = try allocator.create(BoxedValue);
        box.* = .{
            .tag = .string,
            .rc = 1,
            .payload = .{ .string = s },
        };
        return .{ .tag = .string, .payload = @intFromPtr(box) };
    }

    /// 通用装箱函数（用于复合类型）
    pub inline fn fromBoxed(tag: ValueTag, ptr: *anyopaque) Value {
        return .{ .tag = tag, .payload = @intFromPtr(ptr) };
    }

    /// 构造 ADT 值
    pub fn makeAdt(allocator: std.mem.Allocator, type_name: []const u8, constructor: []const u8, fields: []AdtField) !Value {
        const box = try allocator.create(BoxedValue);
        box.* = .{
            .tag = .adt,
            .rc = 1,
            .payload = .{
                .adt = .{
                    .type_name = type_name,
                    .constructor = constructor,
                    .fields = fields,
                    .rc = 1,
                },
            },
        };
        return .{ .tag = .adt, .payload = @intFromPtr(box) };
    }

    /// 构造 Newtype 值
    pub fn makeNewtype(allocator: std.mem.Allocator, type_name: []const u8, inner: Value) !Value {
        const box = try allocator.create(BoxedValue);
        box.* = .{
            .tag = .newtype,
            .rc = 1,
            .payload = .{
                .newtype = .{
                    .type_name = type_name,
                    .inner = inner,
                    .rc = 1,
                },
            },
        };
        return .{ .tag = .newtype, .payload = @intFromPtr(box) };
    }

    /// 构造 Cell 值（用于可变捕获）
    pub fn makeCell(allocator: std.mem.Allocator, inner: Value) !Value {
        const box = try allocator.create(BoxedValue);
        box.* = .{
            .tag = .cell_val,
            .rc = 1,
            .payload = .{
                .cell_val = .{
                    .inner = inner,
                    .rc = 1,
                },
            },
        };
        return .{ .tag = .cell_val, .payload = @intFromPtr(box) };
    }

    /// 构造 Range 值
    pub fn makeRange(allocator: std.mem.Allocator, start: i128, end: i128, inclusive: bool) !Value {
        const box = try allocator.create(BoxedValue);
        box.* = .{
            .tag = .range,
            .rc = 1,
            .payload = .{
                .range = .{
                    .start = start,
                    .end = end,
                    .inclusive = inclusive,
                },
            },
        };
        return .{ .tag = .range, .payload = @intFromPtr(box) };
    }

    /// 构造 VmClosure 值
    pub fn makeVmClosure(
        allocator: std.mem.Allocator,
        func: *const anyopaque,
        arity: u8,
        upvalues: []Value,
        bound_args: []Value,
    ) !Value {
        const box = try allocator.create(BoxedValue);
        box.* = .{
            .tag = .vm_closure,
            .rc = 1,
            .payload = .{
                .vm_closure = .{
                    .func = func,
                    .arity = arity,
                    .upvalues = upvalues,
                    .bound_args = bound_args,
                    .rc = 1,
                    .allocator = allocator,
                },
            },
        };
        return .{ .tag = .vm_closure, .payload = @intFromPtr(box) };
    }

    /// 构造 Partial Application 值
    pub fn makePartial(allocator: std.mem.Allocator, func: Value, bound_args: []Value, remaining_arity: u8) !Value {
        const box = try allocator.create(BoxedValue);
        box.* = .{
            .tag = .partial,
            .rc = 1,
            .payload = .{
                .partial = .{
                    .func = func,
                    .bound_args = bound_args,
                    .remaining_arity = remaining_arity,
                    .rc = 1,
                },
            },
        };
        return .{ .tag = .partial, .payload = @intFromPtr(box) };
    }

    /// 构造 ErrorValue
    pub fn makeError(allocator: std.mem.Allocator, type_name: []const u8, message: []const u8, is_error_subtype: bool) !Value {
        const box = try allocator.create(BoxedValue);
        box.* = .{
            .tag = .error_val,
            .rc = 1,
            .payload = .{
                .error_val = .{
                    .type_name = type_name,
                    .message = message,
                    .is_error_subtype = is_error_subtype,
                },
            },
        };
        return .{ .tag = .error_val, .payload = @intFromPtr(box) };
    }

    /// 构造 ThrowValue
    pub fn makeThrow(allocator: std.mem.Allocator, throw_val: ThrowValue) !Value {
        const box = try allocator.create(BoxedValue);
        box.* = .{
            .tag = .throw_val,
            .rc = 1,
            .payload = .{ .throw_val = throw_val },
        };
        return .{ .tag = .throw_val, .payload = @intFromPtr(box) };
    }

    /// 构造 Builtin 值
    pub fn makeBuiltin(allocator: std.mem.Allocator, builtin: Builtin) !Value {
        const box = try allocator.create(BoxedValue);
        box.* = .{
            .tag = .builtin,
            .rc = 1,
            .payload = .{ .builtin = builtin },
        };
        return .{ .tag = .builtin, .payload = @intFromPtr(box) };
    }

    // ============================================================
    // 解码函数（提取值）
    // ============================================================

    pub inline fn isNull(self: Value) bool {
        return self.tag == .null_val;
    }

    pub inline fn isUnit(self: Value) bool {
        return self.tag == .unit;
    }

    pub inline fn asBool(self: Value) bool {
        std.debug.assert(self.tag == .boolean);
        return self.payload != 0;
    }

    pub inline fn asSmallInt(self: Value) i48 {
        std.debug.assert(self.tag == .small_int);
        const i64_val: i64 = @bitCast(self.payload);
        return @intCast(i64_val);
    }

    pub inline fn asChar(self: Value) u21 {
        std.debug.assert(self.tag == .char_val);
        return @intCast(self.payload);
    }

    /// 多精度浮点解码（返回FloatValue保留类型信息）
    pub fn asFloatValue(self: Value) FloatValue {
        return switch (self.tag) {
            .float16 => {
                const u16_val: u16 = @intCast(self.payload);
                const f16_val: f16 = @bitCast(u16_val);
                return .{ .value = @floatCast(f16_val), .type_tag = .f16 };
            },
            .float32 => {
                const u32_val: u32 = @intCast(self.payload);
                const f32_val: f32 = @bitCast(u32_val);
                return .{ .value = @floatCast(f32_val), .type_tag = .f32 };
            },
            .float64 => {
                const f64_val: f64 = @bitCast(self.payload);
                return .{ .value = @floatCast(f64_val), .type_tag = .f64 };
            },
            .float128 => {
                const box = self.asBoxed();
                return .{ .value = box.payload.float128, .type_tag = .f128 };
            },
            else => unreachable,
        };
    }

    /// f16 解码
    pub inline fn asFloat16(self: Value) f16 {
        std.debug.assert(self.tag == .float16);
        const u16_val: u16 = @intCast(self.payload);
        return @bitCast(u16_val);
    }

    /// f32 解码
    pub inline fn asFloat32(self: Value) f32 {
        std.debug.assert(self.tag == .float32);
        const u32_val: u32 = @intCast(self.payload);
        return @bitCast(u32_val);
    }

    /// f64 解码
    pub inline fn asFloat64(self: Value) f64 {
        std.debug.assert(self.tag == .float64);
        return @bitCast(self.payload);
    }

    /// f128 解码
    pub inline fn asFloat128(self: Value) f128 {
        std.debug.assert(self.tag == .float128);
        return self.asBoxed().payload.float128;
    }

    /// 向后兼容：统一浮点解码（默认f64）
    pub inline fn asFloat(self: Value) f64 {
        return self.asFloat64();
    }

    pub inline fn asBoxed(self: Value) *BoxedValue {
        std.debug.assert(self.isBoxed());
        return @ptrFromInt(self.payload);
    }

    pub inline fn asPointer(self: Value, comptime T: type) *T {
        return @ptrFromInt(self.payload);
    }

    /// 智能整数解码：小整数直接取值，大整数从箱体提取
    pub fn asInt(self: Value) IntValue {
        return switch (self.tag) {
            .small_int => {
                const i48_val = self.asSmallInt();
                return .{ .value = @bitCast(@as(i128, i48_val)), .type_tag = .i32 };
            },
            .big_int => self.asBoxed().payload.big_int,
            else => unreachable,
        };
    }

    // ============================================================
    // 类型检查
    // ============================================================

    pub inline fn isInline(self: Value) bool {
        return @intFromEnum(self.tag) < 10;
    }

    pub inline fn isBoxed(self: Value) bool {
        return @intFromEnum(self.tag) >= 10;
    }

    pub inline fn isInteger(self: Value) bool {
        return self.tag == .small_int or self.tag == .big_int;
    }

    pub inline fn isFloat(self: Value) bool {
        return self.tag == .float16 or self.tag == .float32 or
               self.tag == .float64 or self.tag == .float128;
    }

    // ============================================================
    // 引用计数
    // ============================================================

    pub fn retain(self: Value) Value {
        if (self.isBoxed()) {
            const box: *BoxedValue = @ptrFromInt(self.payload);
            box.rc += 1;
        }
        return self;
    }

    pub fn release(self: Value, allocator: std.mem.Allocator) void {
        if (self.isBoxed()) {
            const box: *BoxedValue = @ptrFromInt(self.payload);
            if (box.rc > 1) {
                box.rc -= 1;
            } else {
                // 归零：释放 payload + 箱体
                box.releasePayload(allocator);
                allocator.destroy(box);
            }
        }
    }

    /// retainOwned：用于需要独立所有权的场景（string/数组元素等）
    pub fn retainOwned(self: Value, allocator: std.mem.Allocator) !Value {
        return switch (self.tag) {
            .string => {
                // string 需要 dupe
                const s = self.asBoxed().payload.string;
                const duped = try allocator.dupe(u8, s);
                return try fromString(allocator, duped);
            },
            else => self.retain(),
        };
    }

    // ============================================================
    // 辅助函数（向后兼容）
    // ============================================================

    pub fn makeArray(allocator: std.mem.Allocator, elements: []Value, fixed_size: ?u64) !Value {
        const box = try allocator.create(BoxedValue);
        box.* = .{
            .tag = .array,
            .rc = 1,
            .payload = .{
                .array = .{
                    .elements = elements,
                    .fixed_size = fixed_size,
                    .rc = 1,
                },
            },
        };
        return .{ .tag = .array, .payload = @intFromPtr(box) };
    }

    pub fn makeRecord(allocator: std.mem.Allocator, type_name: []const u8, fields: std.StringHashMap(Value)) !Value {
        const box = try allocator.create(BoxedValue);
        box.* = .{
            .tag = .record,
            .rc = 1,
            .payload = .{
                .record = .{
                    .type_name = type_name,
                    .fields = fields,
                    .rc = 1,
                },
            },
        };
        return .{ .tag = .record, .payload = @intFromPtr(box) };
    }

    /// 类型相等比较（用于模式匹配）
    pub fn equals(self: Value, other: Value) bool {
        if (@intFromEnum(self.tag) != @intFromEnum(other.tag)) return false;

        return switch (self.tag) {
            .null_val, .unit => true,
            .boolean => self.asBool() == other.asBool(),
            .small_int => self.asSmallInt() == other.asSmallInt(),
            .char_val => self.asChar() == other.asChar(),
            .float16 => self.asFloat16() == other.asFloat16(),
            .float32 => self.asFloat32() == other.asFloat32(),
            .float64 => self.asFloat64() == other.asFloat64(),
            else => self.payload == other.payload, // 指针相等
        };
    }
};

// ============================================================
// BoxedValue：统一装箱头部
// ============================================================

pub const BoxedValue = struct {
    tag: ValueTag,
    rc: u32,
    payload: union {
        big_int: IntValue,
        float128: f128,      // 新增f128装箱
        string: []const u8,
        array: ArrayValue,
        record: RecordValue,
        adt: AdtValue,
        newtype: NewtypeValue,
        range: Range,
        vm_closure: VmClosure,
        partial: PartialApplication,
        builtin: Builtin,
        error_val: ErrorValue,
        throw_val: ThrowValue,
        array_iterator: ArrayIterator,
        string_iterator: StringIterator,
        range_iterator: RangeIterator,
        atomic_val: *AtomicValue,
        spawn_val: *SpawnHandle,
        channel_val: *ChannelValue,
        sender_val: *SenderValue,
        receiver_val: *ReceiverValue,
        trait_value: TraitValue,
        lazy_val: LazyValue,
        cell_val: Cell,
    },

    pub fn releasePayload(self: *BoxedValue, allocator: std.mem.Allocator) void {
        switch (self.tag) {
            .string => {
                allocator.free(self.payload.string);
            },
            .float128 => {
                // f128值类型，无需释放
            },
            .array => {
                for (self.payload.array.elements) |*e| e.release(allocator);
                allocator.free(self.payload.array.elements);
            },
            .record => {
                var it = self.payload.record.fields.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.*.release(allocator);
                }
                self.payload.record.fields.deinit();
            },
            .adt => {
                for (self.payload.adt.fields) |*f| f.value.release(allocator);
                allocator.free(self.payload.adt.fields);
            },
            .newtype => {
                self.payload.newtype.inner.release(allocator);
            },
            .cell_val => {
                self.payload.cell_val.inner.release(allocator);
            },
            .vm_closure => {
                const closure = &self.payload.vm_closure;
                for (closure.upvalues) |uv| uv.release(allocator);
                if (closure.upvalues.len > 0) closure.allocator.free(closure.upvalues);
                for (closure.bound_args) |ba| ba.release(allocator);
                if (closure.bound_args.len > 0) closure.allocator.free(closure.bound_args);
            },
            .partial => {
                self.payload.partial.func.release(allocator);
                for (self.payload.partial.bound_args) |ba| ba.release(allocator);
                if (self.payload.partial.bound_args.len > 0) allocator.free(self.payload.partial.bound_args);
            },
            .throw_val => {
                switch (self.payload.throw_val) {
                    .ok => |ptr| {
                        ptr.release(allocator);
                        allocator.destroy(ptr);
                    },
                    .err => {},
                }
            },
            .trait_value => {
                var it = self.payload.trait_value.methods.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.*.release(allocator);
                }
                self.payload.trait_value.methods.deinit();
                if (self.payload.trait_value.data) |data_ptr| {
                    data_ptr.release(allocator);
                    allocator.destroy(data_ptr);
                }
            },
            .lazy_val => {
                if (self.payload.lazy_val.cached) |cached| {
                    cached.release(allocator);
                }
                // expr/env 由外部管理，不在此释放
            },
            .array_iterator => {
                // 迭代器不拥有数组，无需释放
            },
            .string_iterator => {
                // 迭代器不拥有字符串，无需释放
            },
            .range_iterator => {
                // 值类型，无需释放
            },
            .atomic_val, .spawn_val, .channel_val, .sender_val, .receiver_val => {
                // 并发原语由外部运行时管理
            },
            .big_int, .range, .builtin, .error_val => {
                // 值类型，无需递归释放
            },
            else => {
                // 其他类型（如果有遗漏）
            },
        }
    }
};

// ============================================================
// 编译期大小验证
// ============================================================

comptime {
    if (@sizeOf(Value) != 16) {
        @compileError(std.fmt.comptimePrint("Value size is {d}, expected 16", .{@sizeOf(Value)}));
    }
}

// ============================================================
// 单元测试
// ============================================================

const testing = std.testing;

test "Value size is 16 bytes" {
    try testing.expectEqual(16, @sizeOf(Value));
}

test "null value" {
    const v = Value.fromNull();
    try testing.expect(v.isNull());
    try testing.expectEqual(ValueTag.null_val, v.tag);
}

test "unit value" {
    const v = Value.fromUnit();
    try testing.expect(v.isUnit());
    try testing.expectEqual(ValueTag.unit, v.tag);
}

test "boolean values" {
    const t = Value.fromBool(true);
    const f = Value.fromBool(false);

    try testing.expect(t.asBool());
    try testing.expect(!f.asBool());
    try testing.expectEqual(ValueTag.boolean, t.tag);
}

test "char value" {
    const v = Value.fromChar('A');
    try testing.expectEqual(@as(u21, 'A'), v.asChar());
    try testing.expectEqual(ValueTag.char_val, v.tag);
}

test "float value" {
    const v = Value.fromFloat(3.14159);
    try testing.expectApproxEqRel(3.14159, v.asFloat(), 0.00001);
    try testing.expectEqual(ValueTag.float64, v.tag);
}

test "small int - positive" {
    const v = Value.fromSmallInt(42);
    try testing.expectEqual(@as(i48, 42), v.asSmallInt());
    try testing.expect(v.isInline());
    try testing.expect(!v.isBoxed());
}

test "small int - negative" {
    const v = Value.fromSmallInt(-12345);
    try testing.expectEqual(@as(i48, -12345), v.asSmallInt());
}

test "big int - i64 out of i48 range" {
    const allocator = testing.allocator;

    const big_val = IntValue{ .value = @bitCast(@as(i128, 1 << 50)), .type_tag = .i64 };
    const v = try Value.fromBigInt(allocator, big_val);
    defer v.release(allocator);

    try testing.expect(v.isBoxed());
    try testing.expectEqual(ValueTag.big_int, v.tag);

    const retrieved = v.asInt();
    try testing.expectEqual(big_val.value, retrieved.value);
    try testing.expectEqual(big_val.type_tag, retrieved.type_tag);
}

test "smart int encoding" {
    const allocator = testing.allocator;

    const small = IntValue{ .value = 100, .type_tag = .i32 };
    const v = try Value.fromInt(allocator, small);

    try testing.expect(v.isInline());
    try testing.expectEqual(ValueTag.small_int, v.tag);
}

test "string value" {
    const allocator = testing.allocator;

    const s = try allocator.dupe(u8, "hello");
    const v = try Value.fromString(allocator, s);
    defer v.release(allocator);

    try testing.expect(v.isBoxed());
    try testing.expectEqual(ValueTag.string, v.tag);

    const retrieved = v.asBoxed().payload.string;
    try testing.expectEqualStrings("hello", retrieved);
}

test "refcount - retain increments" {
    const allocator = testing.allocator;

    const s = try allocator.dupe(u8, "test");
    const v = try Value.fromString(allocator, s);

    const box = v.asBoxed();
    try testing.expectEqual(@as(u32, 1), box.rc);

    _ = v.retain();
    try testing.expectEqual(@as(u32, 2), box.rc);

    // 释放所有引用
    v.release(allocator); // rc = 1
    v.release(allocator); // rc = 0, freed
}

test "refcount - inline no-op" {
    const allocator = testing.allocator;
    const v = Value.fromSmallInt(42);
    _ = v.retain();
    v.release(allocator);
    try testing.expectEqual(@as(i48, 42), v.asSmallInt());
}

test "array value" {
    const allocator = testing.allocator;

    var elements = try allocator.alloc(Value, 3);
    elements[0] = Value.fromSmallInt(1);
    elements[1] = Value.fromSmallInt(2);
    elements[2] = Value.fromSmallInt(3);

    const v = try Value.makeArray(allocator, elements, null);
    defer v.release(allocator);

    try testing.expect(v.isBoxed());
    const arr = v.asBoxed().payload.array;
    try testing.expectEqual(@as(usize, 3), arr.elements.len);
}

test "inline vs boxed" {
    const allocator = testing.allocator;

    try testing.expect(Value.fromNull().isInline());
    try testing.expect(Value.fromSmallInt(42).isInline());

    const s = try allocator.dupe(u8, "test");
    const v = try Value.fromString(allocator, s);
    defer v.release(allocator);
    try testing.expect(v.isBoxed());
}

test "value equality" {
    const v1 = Value.fromSmallInt(42);
    const v2 = Value.fromSmallInt(42);
    const v3 = Value.fromSmallInt(43);

    try testing.expect(v1.equals(v2));
    try testing.expect(!v1.equals(v3));
}

test "inferIntType" {
    try testing.expectEqual(IntType.i8, inferIntType(42));
    try testing.expectEqual(IntType.u8, inferIntType(200));
}

test "retainOwned - string duplicates" {
    const allocator = testing.allocator;

    const s1 = try allocator.dupe(u8, "hello");
    const v1 = try Value.fromString(allocator, s1);
    defer v1.release(allocator);

    const v2 = try v1.retainOwned(allocator);
    defer v2.release(allocator);

    const ptr1 = v1.asBoxed().payload.string.ptr;
    const ptr2 = v2.asBoxed().payload.string.ptr;
    try testing.expect(ptr1 != ptr2);
    try testing.expectEqualStrings(v1.asBoxed().payload.string, v2.asBoxed().payload.string);
}

// ============================================================
// 新增单元测试（Day2）
// ============================================================

test "makeAdt - ADT construction" {
    const allocator = testing.allocator;

    var fields = try allocator.alloc(AdtField, 2);
    fields[0] = .{ .name = "x", .value = Value.fromSmallInt(10) };
    fields[1] = .{ .name = "y", .value = Value.fromSmallInt(20) };

    const v = try Value.makeAdt(allocator, "Point", "Point", fields);
    defer v.release(allocator);

    try testing.expect(v.isBoxed());
    try testing.expectEqual(ValueTag.adt, v.tag);

    const adt = v.asBoxed().payload.adt;
    try testing.expectEqualStrings("Point", adt.type_name);
    try testing.expectEqualStrings("Point", adt.constructor);
    try testing.expectEqual(@as(usize, 2), adt.fields.len);
}

test "makeNewtype - Newtype construction" {
    const allocator = testing.allocator;

    const inner = Value.fromSmallInt(42);
    const v = try Value.makeNewtype(allocator, "UserId", inner);
    defer v.release(allocator);

    try testing.expect(v.isBoxed());
    try testing.expectEqual(ValueTag.newtype, v.tag);

    const newtype = v.asBoxed().payload.newtype;
    try testing.expectEqualStrings("UserId", newtype.type_name);
    try testing.expectEqual(@as(i48, 42), newtype.inner.asSmallInt());
}

test "makeCell - Cell construction" {
    const allocator = testing.allocator;

    const inner = Value.fromSmallInt(100);
    const v = try Value.makeCell(allocator, inner);
    defer v.release(allocator);

    try testing.expect(v.isBoxed());
    try testing.expectEqual(ValueTag.cell_val, v.tag);

    const cell = v.asBoxed().payload.cell_val;
    try testing.expectEqual(@as(i48, 100), cell.inner.asSmallInt());
}

test "makeRange - Range construction" {
    const allocator = testing.allocator;

    const v = try Value.makeRange(allocator, 0, 10, false);
    defer v.release(allocator);

    try testing.expect(v.isBoxed());
    try testing.expectEqual(ValueTag.range, v.tag);

    const range = v.asBoxed().payload.range;
    try testing.expectEqual(@as(i128, 0), range.start);
    try testing.expectEqual(@as(i128, 10), range.end);
    try testing.expect(!range.inclusive);
}

test "makeError - ErrorValue construction" {
    const allocator = testing.allocator;

    const v = try Value.makeError(allocator, "FileError", "file not found", true);
    defer v.release(allocator);

    try testing.expect(v.isBoxed());
    try testing.expectEqual(ValueTag.error_val, v.tag);

    const err = v.asBoxed().payload.error_val;
    try testing.expectEqualStrings("FileError", err.type_name);
    try testing.expectEqualStrings("file not found", err.message);
    try testing.expect(err.is_error_subtype);
}

test "ADT with nested values" {
    const allocator = testing.allocator;

    // 构造嵌套 ADT: Some(Some(42))
    const inner_fields = try allocator.alloc(AdtField, 1);
    inner_fields[0] = .{ .name = null, .value = Value.fromSmallInt(42) };

    const inner = try Value.makeAdt(allocator, "Option", "Some", inner_fields);

    const outer_fields = try allocator.alloc(AdtField, 1);
    outer_fields[0] = .{ .name = null, .value = inner };

    const outer = try Value.makeAdt(allocator, "Option", "Some", outer_fields);
    defer outer.release(allocator);

    try testing.expect(outer.isBoxed());
    const outer_adt = outer.asBoxed().payload.adt;
    try testing.expectEqual(@as(usize, 1), outer_adt.fields.len);

    // 验证嵌套结构
    const nested = outer_adt.fields[0].value;
    try testing.expectEqual(ValueTag.adt, nested.tag);
}

test "record with mixed value types" {
    const allocator = testing.allocator;

    var fields = std.StringHashMap(Value).init(allocator);

    const name_key = try allocator.dupe(u8, "name");
    const age_key = try allocator.dupe(u8, "age");
    const active_key = try allocator.dupe(u8, "active");

    try fields.put(name_key, try Value.fromString(allocator, try allocator.dupe(u8, "Alice")));
    try fields.put(age_key, Value.fromSmallInt(30));
    try fields.put(active_key, Value.fromBool(true));

    const v = try Value.makeRecord(allocator, "Person", fields);
    defer v.release(allocator);

    try testing.expect(v.isBoxed());
    const record = v.asBoxed().payload.record;
    try testing.expectEqual(@as(usize, 3), record.fields.count());
}

test "Cell refcount with multiple references" {
    const allocator = testing.allocator;

    const inner = Value.fromSmallInt(42);
    const cell = try Value.makeCell(allocator, inner);

    const ref1 = cell.retain();
    const ref2 = cell.retain();

    const box = cell.asBoxed();
    try testing.expectEqual(@as(u32, 3), box.rc);

    ref2.release(allocator);
    try testing.expectEqual(@as(u32, 2), box.rc);

    ref1.release(allocator);
    try testing.expectEqual(@as(u32, 1), box.rc);

    cell.release(allocator);
}

test "Newtype wrapping complex value" {
    const allocator = testing.allocator;

    // Newtype 包装数组
    var arr_elements = try allocator.alloc(Value, 3);
    arr_elements[0] = Value.fromSmallInt(1);
    arr_elements[1] = Value.fromSmallInt(2);
    arr_elements[2] = Value.fromSmallInt(3);

    const arr = try Value.makeArray(allocator, arr_elements, null);
    const newtype = try Value.makeNewtype(allocator, "IntList", arr);
    defer newtype.release(allocator);

    const nt = newtype.asBoxed().payload.newtype;
    try testing.expectEqual(ValueTag.array, nt.inner.tag);
}
// Day3 新增测试 - VmClosure
test "VmClosure construction and refcount" {
    const allocator = testing.allocator;

    const func: *const anyopaque = @ptrFromInt(0x1000);
    var upvalues = try allocator.alloc(Value, 2);
    upvalues[0] = Value.fromSmallInt(10);
    upvalues[1] = Value.fromSmallInt(20);

    var bound = try allocator.alloc(Value, 1);
    bound[0] = Value.fromSmallInt(30);

    const v = try Value.makeVmClosure(allocator, func, 3, upvalues, bound);
    defer v.release(allocator);

    try testing.expect(v.isBoxed());
    try testing.expectEqual(ValueTag.vm_closure, v.tag);

    const closure = v.asBoxed().payload.vm_closure;
    try testing.expectEqual(@as(u8, 3), closure.arity);
    try testing.expectEqual(@as(usize, 2), closure.upvalues.len);
    try testing.expectEqual(@as(usize, 1), closure.bound_args.len);
}

test "Partial application construction" {
    const allocator = testing.allocator;

    const func = Value.fromSmallInt(42);
    var bound = try allocator.alloc(Value, 2);
    bound[0] = Value.fromSmallInt(1);
    bound[1] = Value.fromSmallInt(2);

    const v = try Value.makePartial(allocator, func, bound, 3);
    defer v.release(allocator);

    try testing.expect(v.isBoxed());
    try testing.expectEqual(ValueTag.partial, v.tag);

    const partial = v.asBoxed().payload.partial;
    try testing.expectEqual(@as(u8, 3), partial.remaining_arity);
    try testing.expectEqual(@as(usize, 2), partial.bound_args.len);
}

test "Range operations" {
    const allocator = testing.allocator;

    const excl = try Value.makeRange(allocator, 0, 10, false);
    defer excl.release(allocator);

    const incl = try Value.makeRange(allocator, 0, 10, true);
    defer incl.release(allocator);

    const r1 = excl.asBoxed().payload.range;
    const r2 = incl.asBoxed().payload.range;

    try testing.expectEqual(@as(i128, 10), r1.len());
    try testing.expectEqual(@as(i128, 11), r2.len());
    try testing.expect(r1.contains(5));
    try testing.expect(!r1.contains(10));
    try testing.expect(r2.contains(10));
}

test "Deep nested release" {
    const allocator = testing.allocator;

    const cell = try Value.makeCell(allocator, Value.fromSmallInt(42));
    const newtype = try Value.makeNewtype(allocator, "UserId", cell);

    var adt_fields = try allocator.alloc(AdtField, 1);
    adt_fields[0] = .{ .name = "value", .value = newtype };
    const adt = try Value.makeAdt(allocator, "Wrapper", "Wrap", adt_fields);

    var record_fields = std.StringHashMap(Value).init(allocator);
    try record_fields.put(try allocator.dupe(u8, "x"), adt);
    const record = try Value.makeRecord(allocator, "Container", record_fields);

    var arr_elements = try allocator.alloc(Value, 1);
    arr_elements[0] = record;
    const array = try Value.makeArray(allocator, arr_elements, null);

    array.release(allocator);
}

test "Value equality basic types" {
    try testing.expect(Value.fromNull().equals(Value.fromNull()));
    try testing.expect(Value.fromUnit().equals(Value.fromUnit()));
    try testing.expect(Value.fromBool(true).equals(Value.fromBool(true)));
    try testing.expect(!Value.fromBool(true).equals(Value.fromBool(false)));

    const int1 = Value.fromSmallInt(42);
    const int2 = Value.fromSmallInt(42);
    try testing.expect(int1.equals(int2));
}

test "Smart int boundary" {
    const allocator = testing.allocator;

    const max_i48 = std.math.maxInt(i48);
    const v_max = try Value.fromInt(allocator, .{ .value = @bitCast(@as(i128, max_i48)), .type_tag = .i64 });
    try testing.expect(v_max.isInline());

    const over = try Value.fromInt(allocator, .{ .value = @bitCast(@as(i128, max_i48) + 1), .type_tag = .i64 });
    defer over.release(allocator);
    try testing.expect(over.isBoxed());
}
// Day4 新增测试 - 并发原语、Trait、迭代器、压力测试

test "Array with 100 elements stress test" {
    const allocator = testing.allocator;

    const elements = try allocator.alloc(Value, 100);
    for (elements, 0..) |*e, i| {
        e.* = Value.fromSmallInt(@intCast(i));
    }

    const v = try Value.makeArray(allocator, elements, null);
    defer v.release(allocator);

    const arr = v.asBoxed().payload.array;
    try testing.expectEqual(@as(usize, 100), arr.elements.len);
    try testing.expectEqual(@as(i48, 0), arr.elements[0].asSmallInt());
    try testing.expectEqual(@as(i48, 99), arr.elements[99].asSmallInt());
}

test "Record with 20 fields" {
    const allocator = testing.allocator;

    var fields = std.StringHashMap(Value).init(allocator);
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        // 使用简短静态键名
        const keys = [_][]const u8{"a","b","c","d","e","f","g","h","i","j","k","l","m","n","o","p","q","r","s","t"};
        const key = try allocator.dupe(u8, keys[i]);
        try fields.put(key, Value.fromSmallInt(@intCast(i)));
    }

    const v = try Value.makeRecord(allocator, "LargeRecord", fields);
    defer v.release(allocator);

    const record = v.asBoxed().payload.record;
    try testing.expectEqual(@as(usize, 20), record.fields.count());
}

test "Deeply nested 8 layers" {
    const allocator = testing.allocator;

    // Layer 1: Cell
    var val = try Value.makeCell(allocator, Value.fromSmallInt(42));

    // Layer 2-7: Newtype wrapping
    var layer: usize = 2;
    while (layer <= 7) : (layer += 1) {
        // 注意：type_name 将由 Newtype 的 release 管理，这里不需要单独释放
        // 但为了测试，我们使用静态字符串
        val = try Value.makeNewtype(allocator, "Layer", val);
    }

    // Layer 8: Array
    const arr = try allocator.alloc(Value, 1);
    arr[0] = val;
    const final = try Value.makeArray(allocator, arr, null);

    // Single release should handle all 8 layers
    final.release(allocator);
}

test "Multiple retain and release cycles" {
    const allocator = testing.allocator;

    const s = try allocator.dupe(u8, "test");
    const v = try Value.fromString(allocator, s);

    // Cycle 1
    _ = v.retain();
    v.release(allocator);

    // Cycle 2
    _ = v.retain();
    _ = v.retain();
    v.release(allocator);
    v.release(allocator);

    // Final release
    v.release(allocator);
}

test "ADT with 10 fields" {
    const allocator = testing.allocator;

    const fields = try allocator.alloc(AdtField, 10);
    for (fields, 0..) |*f, i| {
        // 使用静态字段名避免内存管理复杂性
        f.* = .{ .name = "field", .value = Value.fromSmallInt(@intCast(i)) };
    }

    const v = try Value.makeAdt(allocator, "BigADT", "Ctor", fields);
    defer v.release(allocator);

    const adt = v.asBoxed().payload.adt;
    try testing.expectEqual(@as(usize, 10), adt.fields.len);
}

test "Range negative values" {
    const allocator = testing.allocator;

    const r = try Value.makeRange(allocator, -10, -1, true);
    defer r.release(allocator);

    const range = r.asBoxed().payload.range;
    try testing.expectEqual(@as(i128, -10), range.start);
    try testing.expectEqual(@as(i128, -1), range.end);
    try testing.expect(range.contains(-5));
    try testing.expect(!range.contains(0));
    try testing.expectEqual(@as(i128, 10), range.len());
}

test "Range large values" {
    const allocator = testing.allocator;

    const r = try Value.makeRange(allocator, 0, 1000000, false);
    defer r.release(allocator);

    const range = r.asBoxed().payload.range;
    try testing.expectEqual(@as(i128, 1000000), range.len());
    try testing.expect(range.contains(500000));
    try testing.expect(!range.contains(1000000));
}

test "ErrorValue with long message" {
    const allocator = testing.allocator;

    const long_msg = "This is a very long error message that tests string handling in ErrorValue construction and release";
    const v = try Value.makeError(allocator, "TestError", long_msg, true);
    defer v.release(allocator);

    const err = v.asBoxed().payload.error_val;
    try testing.expectEqualStrings(long_msg, err.message);
}

test "Builtin function with context" {
    const allocator = testing.allocator;

    const dummy_fn: BuiltinFn = struct {
        fn call(_: *anyopaque, _: ?*anyopaque, _: []const Value) anyerror!Value {
            return Value.fromSmallInt(999);
        }
    }.call;

    var ctx: u32 = 12345;
    const builtin = Builtin{ .fn_ptr = dummy_fn, .user_ctx = @ptrCast(&ctx) };
    const v = try Value.makeBuiltin(allocator, builtin);
    defer v.release(allocator);

    const b = v.asBoxed().payload.builtin;
    try testing.expect(b.user_ctx != null);
}

test "Array fixed size constraint" {
    const allocator = testing.allocator;

    const elements = try allocator.alloc(Value, 5);
    for (elements, 0..) |*e, i| {
        e.* = Value.fromSmallInt(@intCast(i));
    }

    const v = try Value.makeArray(allocator, elements, 5);
    defer v.release(allocator);

    const arr = v.asBoxed().payload.array;
    try testing.expectEqual(@as(?u64, 5), arr.fixed_size);
    try testing.expectEqual(@as(usize, 5), arr.elements.len);
}

test "Cell with null inner value" {
    const allocator = testing.allocator;

    const cell = try Value.makeCell(allocator, Value.fromNull());
    defer cell.release(allocator);

    const c = cell.asBoxed().payload.cell_val;
    try testing.expect(c.inner.isNull());
}

test "Cell with unit inner value" {
    const allocator = testing.allocator;

    const cell = try Value.makeCell(allocator, Value.fromUnit());
    defer cell.release(allocator);

    const c = cell.asBoxed().payload.cell_val;
    try testing.expect(c.inner.isUnit());
}

test "Newtype wrapping null" {
    const allocator = testing.allocator;

    const nt = try Value.makeNewtype(allocator, "Optional", Value.fromNull());
    defer nt.release(allocator);

    const newtype = nt.asBoxed().payload.newtype;
    try testing.expect(newtype.inner.isNull());
}

test "Partial with zero bound args" {
    const allocator = testing.allocator;

    const func = Value.fromSmallInt(100);
    const empty = try allocator.alloc(Value, 0);

    const p = try Value.makePartial(allocator, func, empty, 5);
    defer p.release(allocator);

    const partial = p.asBoxed().payload.partial;
    try testing.expectEqual(@as(usize, 0), partial.bound_args.len);
    try testing.expectEqual(@as(u8, 5), partial.remaining_arity);
}

test "VmClosure with zero upvalues" {
    const allocator = testing.allocator;

    const func: *const anyopaque = @ptrFromInt(0x2000);
    const empty_uv = try allocator.alloc(Value, 0);
    const empty_ba = try allocator.alloc(Value, 0);

    const vc = try Value.makeVmClosure(allocator, func, 2, empty_uv, empty_ba);
    defer vc.release(allocator);

    const closure = vc.asBoxed().payload.vm_closure;
    try testing.expectEqual(@as(usize, 0), closure.upvalues.len);
    try testing.expectEqual(@as(usize, 0), closure.bound_args.len);
    try testing.expectEqual(@as(u8, 2), closure.arity);
}

test "Record empty fields" {
    const allocator = testing.allocator;

    const fields = std.StringHashMap(Value).init(allocator);
    const v = try Value.makeRecord(allocator, "Empty", fields);
    defer v.release(allocator);

    const record = v.asBoxed().payload.record;
    try testing.expectEqual(@as(usize, 0), record.fields.count());
}

test "ADT empty fields" {
    const allocator = testing.allocator;

    const empty = try allocator.alloc(AdtField, 0);
    const v = try Value.makeAdt(allocator, "Unit", "Unit", empty);
    defer v.release(allocator);

    const adt = v.asBoxed().payload.adt;
    try testing.expectEqual(@as(usize, 0), adt.fields.len);
}

test "Float special values" {
    const pos_inf = Value.fromFloat(std.math.inf(f64));
    const neg_inf = Value.fromFloat(-std.math.inf(f64));
    const nan = Value.fromFloat(std.math.nan(f64));

    try testing.expect(std.math.isInf(pos_inf.asFloat()));
    try testing.expect(std.math.isInf(neg_inf.asFloat()));
    try testing.expect(std.math.isNan(nan.asFloat()));
}

test "Integer type promotion examples" {
    const i8_type = IntType.i8;
    const i32_type = IntType.i32;
    const u8_type = IntType.u8;

    const promoted = promoteIntTypes(i8_type, i32_type);
    try testing.expectEqual(IntType.i32, promoted);

    const mixed = promoteIntTypes(i8_type, u8_type);
    try testing.expectEqual(IntType.i16, mixed);
}

test "Integer type in range checks" {
    const i8_type = IntType.i8;
    try testing.expect(i8_type.inRange(100));
    try testing.expect(!i8_type.inRange(200));

    const u8_type = IntType.u8;
    try testing.expect(u8_type.inRange(255));
    try testing.expect(!u8_type.inRange(256));
}

// Day4+ 多精度浮点测试

test "Float16 encoding and decoding" {
    const f16_val: f16 = 3.14;
    const v = Value.fromFloat16(f16_val);
    
    try testing.expectEqual(ValueTag.float16, v.tag);
    try testing.expect(v.isInline());
    try testing.expect(v.isFloat());
    
    const recovered = v.asFloat16();
    try testing.expectApproxEqRel(f16_val, recovered, 0.01);
}

test "Float32 encoding and decoding" {
    const f32_val: f32 = 3.141592;
    const v = Value.fromFloat32(f32_val);
    
    try testing.expectEqual(ValueTag.float32, v.tag);
    try testing.expect(v.isInline());
    
    const recovered = v.asFloat32();
    try testing.expectApproxEqRel(f32_val, recovered, 0.00001);
}

test "Float64 encoding and decoding" {
    const f64_val: f64 = 3.141592653589793;
    const v = Value.fromFloat64(f64_val);
    
    try testing.expectEqual(ValueTag.float64, v.tag);
    try testing.expect(v.isInline());
    
    const recovered = v.asFloat64();
    try testing.expectEqual(f64_val, recovered);
}

test "Float128 boxing" {
    const allocator = testing.allocator;
    
    const f128_val: f128 = 3.14159265358979323846264338327950288;
    const v = try Value.fromFloat128(allocator, f128_val);
    defer v.release(allocator);
    
    try testing.expectEqual(ValueTag.float128, v.tag);
    try testing.expect(v.isBoxed());
    try testing.expect(v.isFloat());
    
    const recovered = v.asFloat128();
    try testing.expectEqual(f128_val, recovered);
}

test "FloatValue round-trip with type preservation" {
    const allocator = testing.allocator;

    // f16
    const fv16 = FloatValue{ .value = 3.14, .type_tag = .f16 };
    const v16 = try Value.fromFloatValue(allocator, fv16);
    const recovered16 = v16.asFloatValue();
    try testing.expectEqual(FloatType.f16, recovered16.type_tag);

    // f32
    const fv32 = FloatValue{ .value = 3.14159, .type_tag = .f32 };
    const v32 = try Value.fromFloatValue(allocator, fv32);
    const recovered32 = v32.asFloatValue();
    try testing.expectEqual(FloatType.f32, recovered32.type_tag);

    // f64
    const fv64 = FloatValue{ .value = 0.1, .type_tag = .f64 };
    const v64 = try Value.fromFloatValue(allocator, fv64);
    const recovered64 = v64.asFloatValue();
    try testing.expectEqual(FloatType.f64, recovered64.type_tag);

    // f128
    const fv128 = FloatValue{ .value = 1.23456789e50, .type_tag = .f128 };
    const v128 = try Value.fromFloatValue(allocator, fv128);
    defer v128.release(allocator);
    const recovered128 = v128.asFloatValue();
    try testing.expectEqual(FloatType.f128, recovered128.type_tag);
}

test "isFloat type check" {
    const allocator = testing.allocator;
    
    try testing.expect(Value.fromFloat16(1.0).isFloat());
    try testing.expect(Value.fromFloat32(1.0).isFloat());
    try testing.expect(Value.fromFloat64(1.0).isFloat());
    
    const f128_v = try Value.fromFloat128(allocator, 1.0);
    defer f128_v.release(allocator);
    try testing.expect(f128_v.isFloat());
    
    // 非浮点值
    try testing.expect(!Value.fromSmallInt(42).isFloat());
    try testing.expect(!Value.fromBool(true).isFloat());
}
