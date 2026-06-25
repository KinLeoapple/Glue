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
};

pub const IntValue = struct {
    value: u128,
    type_tag: IntType = .i32,

    pub fn signedValue(self: IntValue) i128 {
        return @bitCast(self.value);
    }
};

pub const FloatValue = struct {
    value: f64,
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
    float_val = 5,    // payload: f64 位模式

    // 装箱类型（payload 存指针，指向 BoxedValue）
    big_int = 10,     // i64/i128/u64/u128 超出 i48 范围
    string = 11,
    array = 12,
    record = 13,
    adt = 14,
    newtype = 15,
    range = 16,
    vm_closure = 17,
    partial = 18,
    builtin = 19,
    error_val = 20,
    throw_val = 21,

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

    pub inline fn fromFloat(f: f64) Value {
        return .{ .tag = .float_val, .payload = @bitCast(f) };
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

    pub inline fn asFloat(self: Value) f64 {
        std.debug.assert(self.tag == .float_val);
        return @bitCast(self.payload);
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
            .float_val => self.asFloat() == other.asFloat(),
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
            .big_int, .range, .builtin, .error_val => {
                // 值类型，无需递归释放
            },
            else => {
                // 其他类型暂时简化处理（TODO: 完整实现）
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
    try testing.expectEqual(ValueTag.float_val, v.tag);
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
