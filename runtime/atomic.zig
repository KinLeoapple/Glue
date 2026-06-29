//! Atomic<T> 原子操作
//!
//! 文档 §3.4: Atomic<T> 是跨协程共享原子状态的唯一方式，替代 Arc<T>

const std = @import("std");
const value = @import("value");

const Value = value.Value;
const IntType = value.IntType;

/// Atomic<T> 值 — 跨协程共享原子状态
/// 文档 §3.4: Atomic<T> 是引用类型，atomic expr 创建堆上原子值
/// T 限制为原始类型：i8..i128, u8..u128, f32, f64, bool, char
pub const AtomicValue = struct {
    /// 原子存储的值 — 使用 i128 统一表示所有整数类型
    /// f64/bool/char 也通过 @bitCast 存储为 i128
    data: std.atomic.Value(i128),
    /// 引用计数 — 归零时自动释放
    ref_count: std.atomic.Value(usize),
    /// 类型标签 — 确定如何解释 data
    type_tag: AtomicType,

    pub const AtomicType = enum {
        i8, i16, i32, i64, i128,
        u8, u16, u32, u64, u128,
        f16, f32, f64, f128,
        bool,
        char,
    };

    /// 从整数值创建 AtomicValue
    pub fn initInt(int_val: i128, tag: AtomicType) AtomicValue {
        return AtomicValue{
            .data = std.atomic.Value(i128).init(int_val),
            .ref_count = std.atomic.Value(usize).init(1),
            .type_tag = tag,
        };
    }

    /// 从浮点值创建 AtomicValue
    pub fn initFloat(float_val: f128, tag: AtomicType) AtomicValue {
        const bits: u128 = @bitCast(float_val);
        return AtomicValue{
            .data = std.atomic.Value(i128).init(@bitCast(bits)),
            .ref_count = std.atomic.Value(usize).init(1),
            .type_tag = tag,
        };
    }

    /// 从布尔值创建 AtomicValue
    pub fn initBool(b: bool) AtomicValue {
        return AtomicValue{
            .data = std.atomic.Value(i128).init(if (b) 1 else 0),
            .ref_count = std.atomic.Value(usize).init(1),
            .type_tag = .bool,
        };
    }

    /// 从字符值创建 AtomicValue
    pub fn initChar(c: u21) AtomicValue {
        return AtomicValue{
            .data = std.atomic.Value(i128).init(@as(i128, @intCast(c))),
            .ref_count = std.atomic.Value(usize).init(1),
            .type_tag = .char,
        };
    }

    /// 加载当前值到 Value
    pub fn load(self: *AtomicValue, allocator: std.mem.Allocator) !Value {
        _ = allocator;
        const raw = self.data.load(.seq_cst);
        return switch (self.type_tag) {
            .i8, .i16, .i32, .i64, .i128, .u8, .u16, .u32, .u64, .u128 => blk: {
                const int_type = atomicTypeToIntType(self.type_tag);
                break :blk Value.fromInt(value.Int.fromNative(int_type, raw));
            },
            .f16, .f32, .f64, .f128 => blk: {
                // 对于浮点数，需要根据类型大小正确处理
                const float_type: value.FloatType = switch (self.type_tag) {
                    .f16 => .f16,
                    .f32 => .f32,
                    .f64 => .f64,
                    .f128 => .f128,
                    else => unreachable,
                };
                const float_val: f128 = switch (self.type_tag) {
                    .f16 => @floatCast(@as(f16, @bitCast(@as(u16, @truncate(@as(u128, @bitCast(raw))))))),
                    .f32 => @floatCast(@as(f32, @bitCast(@as(u32, @truncate(@as(u128, @bitCast(raw))))))),
                    .f64 => @floatCast(@as(f64, @bitCast(@as(u64, @truncate(@as(u128, @bitCast(raw))))))),
                    .f128 => @bitCast(@as(u128, @bitCast(raw))),
                    else => unreachable,
                };
                break :blk Value.fromFloat(value.Float.fromNative(.f128, float_val).toFloatType(float_type));
            },
            .bool => Value.fromBool(raw != 0),
            .char => Value.fromChar(value.Char.fromNative(@intCast(raw)) catch unreachable),
        };
    }

    /// 原子存储 Value
    pub fn store(self: *AtomicValue, val: Value) void {
        const raw = valueToAtomicRaw(val, self.type_tag);
        self.data.store(raw, .seq_cst);
    }

    /// 原子 fetch_add
    pub fn fetchAdd(self: *AtomicValue, operand: i128) i128 {
        return self.data.fetchAdd(operand, .seq_cst);
    }

    /// 原子 fetch_sub
    pub fn fetchSub(self: *AtomicValue, operand: i128) i128 {
        return self.data.fetchSub(operand, .seq_cst);
    }

    /// 原子 fetch_mul (使用 CAS 循环，因为没有硬件 fetch_mul)
    pub fn fetchMul(self: *AtomicValue, operand: i128) i128 {
        while (true) {
            const current = self.data.load(.seq_cst);
            const new_val = current * operand;
            if (self.data.cmpxchgStrong(current, new_val, .seq_cst, .seq_cst)) |_| {
                continue;
            }
            return current;
        }
    }

    /// 原子 fetch_and
    pub fn fetchAnd(self: *AtomicValue, operand: i128) i128 {
        return self.data.fetchAnd(operand, .seq_cst);
    }

    /// 原子 fetch_or
    pub fn fetchOr(self: *AtomicValue, operand: i128) i128 {
        return self.data.fetchOr(operand, .seq_cst);
    }

    /// CAS (compare-and-swap)，返回是否成功
    pub fn cas(self: *AtomicValue, expected: i128, new: i128) bool {
        return self.data.cmpxchgStrong(expected, new, .seq_cst, .seq_cst) == null;
    }

    /// 原子交换，返回旧值
    pub fn xchg(self: *AtomicValue, new: i128) i128 {
        return self.data.swap(new, .seq_cst);
    }

    /// 增加引用计数
    pub fn ref(self: *AtomicValue) void {
        _ = self.ref_count.fetchAdd(1, .seq_cst);
    }

    /// 减少引用计数，归零返回 true
    pub fn unref(self: *AtomicValue) bool {
        return self.ref_count.fetchSub(1, .seq_cst) == 1;
    }
};

pub fn atomicTypeToIntType(at: AtomicValue.AtomicType) IntType {
    return switch (at) {
        .i8 => .i8, .i16 => .i16, .i32 => .i32, .i64 => .i64, .i128 => .i128,
        .u8 => .u8, .u16 => .u16, .u32 => .u32, .u64 => .u64, .u128 => .u128,
        else => .i32, // f16/f32/f64/f128/bool/char 不应该走到这里
    };
}

pub fn intTypeToAtomicType(it: IntType) AtomicValue.AtomicType {
    return switch (it) {
        .i8 => .i8, .i16 => .i16, .i32 => .i32, .i64 => .i64, .i128 => .i128,
        .u8 => .u8, .u16 => .u16, .u32 => .u32, .u64 => .u64, .u128 => .u128,
    };
}

pub fn valueToAtomicRaw(val: Value, tag: AtomicValue.AtomicType) i128 {
    return switch (val) {
        .int => blk: {
            break :blk @bitCast(val.asInt().toNative(u128));
        },
        .float => blk: {
            const fv: f128 = val.asFloat().asF128();
            // 根据原子变量的实际类型，将浮点数的位表示存储为 i128
            // 小的浮点类型只占用低位，高位为 0
            const raw: i128 = switch (tag) {
                .f16 => @as(i128, @bitCast(@as(i128, @as(u16, @bitCast(@as(f16, @floatCast(fv))))))),
                .f32 => @as(i128, @bitCast(@as(i128, @as(u32, @bitCast(@as(f32, @floatCast(fv))))))),
                .f64 => @as(i128, @bitCast(@as(i128, @as(u64, @bitCast(@as(f64, @floatCast(fv))))))),
                .f128 => @bitCast(@as(u128, @bitCast(fv))),
                else => 0,
            };
            break :blk raw;
        },
        .boolean => if (val.asBool()) 1 else 0,
        .char => @as(i128, @intCast(val.asChar().toNative())),
        else => 0,
    };
}
