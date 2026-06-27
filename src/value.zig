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
    ok: Value,
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
};

pub const NewtypeValue = struct {
    type_name: []const u8,
    inner: Value,
};

pub const ArrayValue = struct {
    elements: []Value,
    fixed_size: ?u64 = null,
};

pub const RecordValue = struct {
    type_name: []const u8,
    fields: std.StringHashMap(Value),
};

pub const Cell = struct {
    inner: Value,
};

pub const VmClosure = struct {
    func: *const anyopaque,
    arity: u8,
    upvalues: []Value = &.{},
    bound_args: []Value = &.{},
    allocator: std.mem.Allocator,
    self_upvalue_idx: i32 = -1,
};

pub const PartialApplication = struct {
    func: Value,
    bound_args: []Value,
    remaining_arity: u8,
};

pub const TraitValue = struct {
    trait_name: []const u8 = "",
    methods: std.StringHashMap(Value),
    data: ?Value = null,
    allocator: std.mem.Allocator,
    vm_owned: bool = false,
};

pub const LazyValue = struct {
    expr: *ast.Expr,
    env: *anyopaque,
    cached: ?Value = null,
    forced: bool = false,
    allocator: std.mem.Allocator,
    vm_thunk: ?*anyopaque = null,
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

    /// 构造 Sender 值
    pub fn fromSender(allocator: std.mem.Allocator, sv: *SenderValue) !Value {
        const box = try allocator.create(BoxedValue);
        box.* = .{
            .tag = .sender_val,
            .rc = 1,
            .payload = .{ .sender_val = sv },
        };
        return .{ .tag = .sender_val, .payload = @intFromPtr(box) };
    }

    /// 构造 Receiver 值
    pub fn fromReceiver(allocator: std.mem.Allocator, rv: *ReceiverValue) !Value {
        const box = try allocator.create(BoxedValue);
        box.* = .{
            .tag = .receiver_val,
            .rc = 1,
            .payload = .{ .receiver_val = rv },
        };
        return .{ .tag = .receiver_val, .payload = @intFromPtr(box) };
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

    pub inline fn retain(self: Value) Value {
        if (self.isBoxed()) {
            const box: *BoxedValue = @ptrFromInt(self.payload);
            box.rc += 1;
        }
        return self;
    }

    pub inline fn release(self: Value, allocator: std.mem.Allocator) void {
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
    /// 跨线程深拷贝：创建一个新的 Value，所有堆数据都复制到新的 allocator
    /// 用于将 Value 从一个线程的 arena 传递到另一个线程
    pub fn retainOwned(self: Value, allocator: std.mem.Allocator) !Value {
        return switch (self.tag) {
            // 简单类型：直接返回
            .null_val, .unit, .boolean, .small_int, .char_val, .float16, .float32, .float64 => self,

            // 字符串：需要深拷贝
            .string => {
                const s = self.asBoxed().payload.string;
                const duped = try allocator.dupe(u8, s);
                return try fromString(allocator, duped);
            },

            // 大整数：深拷贝
            .big_int => {
                const int_val = self.asBoxed().payload.big_int;
                return try fromBigInt(allocator, int_val);
            },

            // 浮点数：深拷贝
            .float128 => {
                const f = self.asBoxed().payload.float128;
                return try fromFloat128(allocator, f);
            },

            // 数组：递归深拷贝所有元素
            .array => {
                const arr = self.asBoxed().payload.array;
                const new_elements = try allocator.alloc(Value, arr.elements.len);
                errdefer allocator.free(new_elements);
                for (arr.elements, 0..) |elem, i| {
                    new_elements[i] = try elem.retainOwned(allocator);
                }
                return try makeArray(allocator, new_elements, arr.fixed_size);
            },

            // 记录：递归深拷贝所有字段
            .record => {
                const rec = self.asBoxed().payload.record;
                var new_fields = std.StringHashMap(Value).init(allocator);
                errdefer {
                    var it = new_fields.iterator();
                    while (it.next()) |entry| {
                        entry.value_ptr.release(allocator);
                    }
                    new_fields.deinit();
                }
                var it = rec.fields.iterator();
                while (it.next()) |entry| {
                    const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
                    const val_copy = try entry.value_ptr.retainOwned(allocator);
                    try new_fields.put(key_copy, val_copy);
                }
                const type_name_copy = try allocator.dupe(u8, rec.type_name);
                return try makeRecord(allocator, type_name_copy, new_fields);
            },

            // ADT：递归深拷贝所有字段
            .adt => {
                const adt = self.asBoxed().payload.adt;
                const new_fields = try allocator.alloc(AdtField, adt.fields.len);
                errdefer allocator.free(new_fields);
                for (adt.fields, 0..) |field, i| {
                    new_fields[i] = .{
                        .name = if (field.name) |n| try allocator.dupe(u8, n) else null,
                        .value = try field.value.retainOwned(allocator),
                    };
                }
                const type_name_copy = try allocator.dupe(u8, adt.type_name);
                const constructor_copy = try allocator.dupe(u8, adt.constructor);
                return try makeAdt(allocator, type_name_copy, constructor_copy, new_fields);
            },

            // Newtype：递归深拷贝内部值
            .newtype => {
                const nt = self.asBoxed().payload.newtype;
                const type_name_copy = try allocator.dupe(u8, nt.type_name);
                const inner_copy = try nt.inner.retainOwned(allocator);
                return try makeNewtype(allocator, type_name_copy, inner_copy);
            },

            // Range：深拷贝
            .range => {
                const r = self.asBoxed().payload.range;
                return try makeRange(allocator, r.start, r.end, r.inclusive);
            },

            // Cell：深拷贝内部值
            .cell_val => {
                const cell = self.asBoxed().payload.cell_val;
                const inner_copy = try cell.inner.retainOwned(allocator);
                return try makeCell(allocator, inner_copy);
            },

            // Error：深拷贝
            .error_val => {
                const err = self.asBoxed().payload.error_val;
                const type_name_copy = try allocator.dupe(u8, err.type_name);
                const message_copy = try allocator.dupe(u8, err.message);
                return try makeError(allocator, type_name_copy, message_copy, err.is_error_subtype);
            },

            // 这些类型不能跨线程传递，只增加引用计数
            // 注意：闭包、部分应用、builtin 等包含函数指针，理论上可以跨线程
            // 但它们的捕获可能需要深拷贝
            .vm_closure, .partial, .builtin => self.retain(),

            // 这些类型是线程相关的，不应该跨线程传递
            // 返回错误或者只增加引用计数（根据实际需求）
            .throw_val, .array_iterator, .string_iterator, .range_iterator,
            .atomic_val, .spawn_val, .channel_val, .sender_val, .receiver_val,
            .trait_value, .lazy_val => self.retain(),
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

    /// 格式化 Value 为字符串（用于打印和调试）
    pub fn format(self: Value, allocator: std.mem.Allocator, buf: *std.ArrayList(u8)) !void {
        switch (self.tag) {
            .null_val => try buf.appendSlice(allocator, "null"),
            .unit => try buf.appendSlice(allocator, "()"),
            .boolean => {
                const b = self.asBool();
                try buf.appendSlice(allocator, if (b) "true" else "false");
            },
            .small_int => {
                const temp = try std.fmt.allocPrint(allocator, "{}", .{self.asSmallInt()});
                defer allocator.free(temp);
                try buf.appendSlice(allocator, temp);
            },
            .big_int => {
                const int_val = self.asBoxed().payload.big_int;
                const temp = try std.fmt.allocPrint(allocator, "{}:{s}", .{int_val.value, @tagName(int_val.type_tag)});
                defer allocator.free(temp);
                try buf.appendSlice(allocator, temp);
            },
            .char_val => {
                const temp = try std.fmt.allocPrint(allocator, "'{u}'", .{self.asChar()});
                defer allocator.free(temp);
                try buf.appendSlice(allocator, temp);
            },
            .float16 => {
                const temp = try std.fmt.allocPrint(allocator, "{d}", .{self.asFloat16()});
                defer allocator.free(temp);
                try buf.appendSlice(allocator, temp);
            },
            .float32 => {
                const temp = try std.fmt.allocPrint(allocator, "{d}", .{self.asFloat32()});
                defer allocator.free(temp);
                try buf.appendSlice(allocator, temp);
            },
            .float64 => {
                const temp = try std.fmt.allocPrint(allocator, "{d}", .{self.asFloat64()});
                defer allocator.free(temp);
                try buf.appendSlice(allocator, temp);
            },
            .float128 => {
                const temp = try std.fmt.allocPrint(allocator, "{d}", .{self.asBoxed().payload.float128});
                defer allocator.free(temp);
                try buf.appendSlice(allocator, temp);
            },
            .string => {
                try buf.append(allocator, '"');
                try buf.appendSlice(allocator, self.asBoxed().payload.string);
                try buf.append(allocator, '"');
            },
            .array => {
                const arr = self.asBoxed().payload.array;
                try buf.append(allocator, '[');
                for (arr.elements, 0..) |elem, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try elem.format(allocator, buf);
                }
                try buf.append(allocator, ']');
            },
            .record => {
                const rec = self.asBoxed().payload.record;
                try buf.appendSlice(allocator, rec.type_name);
                try buf.append(allocator, '{');
                var it = rec.fields.iterator();
                var first = true;
                while (it.next()) |entry| {
                    if (!first) try buf.appendSlice(allocator, ", ");
                    first = false;
                    try buf.appendSlice(allocator, entry.key_ptr.*);
                    try buf.appendSlice(allocator, ": ");
                    try entry.value_ptr.format(allocator, buf);
                }
                try buf.append(allocator, '}');
            },
            .adt => {
                const adt = self.asBoxed().payload.adt;
                try buf.appendSlice(allocator, adt.type_name);
                try buf.appendSlice(allocator, "::");
                try buf.appendSlice(allocator, adt.constructor);
                if (adt.fields.len > 0) {
                    try buf.append(allocator, '(');
                    for (adt.fields, 0..) |field, i| {
                        if (i > 0) try buf.appendSlice(allocator, ", ");
                        try field.value.format(allocator, buf);
                    }
                    try buf.append(allocator, ')');
                }
            },
            .newtype => {
                const nt = self.asBoxed().payload.newtype;
                try buf.appendSlice(allocator, nt.type_name);
                try buf.append(allocator, '(');
                try nt.inner.format(allocator, buf);
                try buf.append(allocator, ')');
            },
            .range => {
                const r = self.asBoxed().payload.range;
                const temp = try std.fmt.allocPrint(allocator, "{}..{s}{}", .{r.start, if (r.inclusive) "=" else "", r.end});
                defer allocator.free(temp);
                try buf.appendSlice(allocator, temp);
            },
            .vm_closure => try buf.appendSlice(allocator, "<closure>"),
            .partial => try buf.appendSlice(allocator, "<partial>"),
            .builtin => try buf.appendSlice(allocator, "<builtin>"),
            .error_val => {
                const err = self.asBoxed().payload.error_val;
                try buf.appendSlice(allocator, "Error(");
                try buf.appendSlice(allocator, err.type_name);
                try buf.appendSlice(allocator, ": ");
                try buf.appendSlice(allocator, err.message);
                try buf.append(allocator, ')');
            },
            .throw_val => try buf.appendSlice(allocator, "<throw>"),
            .array_iterator => try buf.appendSlice(allocator, "<array_iter>"),
            .string_iterator => try buf.appendSlice(allocator, "<string_iter>"),
            .range_iterator => try buf.appendSlice(allocator, "<range_iter>"),
            .atomic_val => try buf.appendSlice(allocator, "<atomic>"),
            .spawn_val => try buf.appendSlice(allocator, "<spawn>"),
            .channel_val => try buf.appendSlice(allocator, "<channel>"),
            .sender_val => try buf.appendSlice(allocator, "<sender>"),
            .receiver_val => try buf.appendSlice(allocator, "<receiver>"),
            .trait_value => try buf.appendSlice(allocator, "<trait>"),
            .lazy_val => try buf.appendSlice(allocator, "<lazy>"),
            .cell_val => {
                const cell = self.asBoxed().payload.cell_val;
                try buf.appendSlice(allocator, "Cell(");
                try cell.inner.format(allocator, buf);
                try buf.append(allocator, ')');
            },
        }
    }

    /// 格式化 Value 为字符串并返回（用于打印和调试）
    pub fn formatAlloc(self: Value, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try self.format(allocator, &buf);
        return buf.toOwnedSlice(allocator);
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
                // 弱自引用跳过：op_set_local_letrec 断环时已 cell.rc -= 1 抵消强引用，
                // 此 upvalue 不再持 cell 的 rc，release 时必须跳过，否则 cell 被二次释放（rc 下溢）。
                const self_idx = closure.self_upvalue_idx;
                for (closure.upvalues, 0..) |uv, i| {
                    if (self_idx >= 0 and i == @as(usize, @intCast(self_idx))) continue;
                    uv.release(allocator);
                }
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
                    .ok => |v| v.release(allocator),
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
                if (self.payload.trait_value.data) |v| v.release(allocator);
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
            .atomic_val => {
                // atomic_val 有自己的引用计数，需要 unref
                const av = self.payload.atomic_val;
                if (av.unref()) {
                    allocator.destroy(av);
                }
            },
            .spawn_val, .channel_val, .sender_val, .receiver_val => {
                // 其他并发原语由外部运行时管理
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
