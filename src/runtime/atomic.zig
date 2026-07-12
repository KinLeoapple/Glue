//! 原子值模块。
//!
//! 为 Glue 语言的 `Value` 类型提供互斥保护的原子操作容器。
//! 支持整数与浮点的算术原子更新（加减乘除模、位与或）、CAS 与交换，
//! 并通过引用计数支持多所有者共享。

const std = @import("std");
const value = @import("value");
const sync = @import("sync");
const Value = value.Value;
const Int = value.Int;
const Float = value.Float;
const Mutex = sync.Mutex;

/// 原子操作可能产生的错误。
pub const AtomicError = error{
    ArithmeticOverflow,
    DivideByZero,
};

/// 受互斥锁保护的原子值容器。
///
/// 所有读写操作均在临界区内完成，保证对复合类型 `Value` 的线程安全访问。
/// 引用计数用于管理容器自身的生命周期。
pub const AtomicValue = struct {
    data: Value,
    mutex: Mutex,
    ref_count: std.atomic.Value(usize),

    /// 创建初始引用计数为 1 的原子值。
    pub fn init(val: Value) AtomicValue {
        return AtomicValue{
            .data = val,
            .mutex = .{},
            .ref_count = std.atomic.Value(usize).init(1),
        };
    }

    /// 读取当前值的快照。
    pub fn load(self: *AtomicValue) Value {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.data;
    }

    /// 原子地写入新值。
    pub fn store(self: *AtomicValue, val: Value) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.data = val;
    }

    /// 原子加法。操作数会按当前值类型进行类型转换，溢出返回错误。
    pub fn fetchAdd(self: *AtomicValue, operand: Value) AtomicError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.data = switch (self.data) {
            .int => blk: {
                const a = self.data.asInt();
                const b = operand.asInt().coerceTo(a.type) orelse return error.ArithmeticOverflow;
                const r = a.add(b);
                if (r.overflow) return error.ArithmeticOverflow;
                break :blk Value.fromInt(r.result);
            },
            .float => blk: {
                const a = self.data.asFloat();
                const b = operand.asFloat().toFloatType(a.type);
                break :blk Value.fromFloat(a.add(b));
            },
            else => self.data,
        };
    }

    /// 原子减法。语义与 `fetchAdd` 对应。
    pub fn fetchSub(self: *AtomicValue, operand: Value) AtomicError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.data = switch (self.data) {
            .int => blk: {
                const a = self.data.asInt();
                const b = operand.asInt().coerceTo(a.type) orelse return error.ArithmeticOverflow;
                const r = a.subtract(b);
                if (r.overflow) return error.ArithmeticOverflow;
                break :blk Value.fromInt(r.result);
            },
            .float => blk: {
                const a = self.data.asFloat();
                const b = operand.asFloat().toFloatType(a.type);
                break :blk Value.fromFloat(a.subtract(b));
            },
            else => self.data,
        };
    }

    /// 原子乘法。
    pub fn fetchMul(self: *AtomicValue, operand: Value) AtomicError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.data = switch (self.data) {
            .int => blk: {
                const a = self.data.asInt();
                const b = operand.asInt().coerceTo(a.type) orelse return error.ArithmeticOverflow;
                const r = a.multiply(b);
                if (r.overflow) return error.ArithmeticOverflow;
                break :blk Value.fromInt(r.result);
            },
            .float => blk: {
                const a = self.data.asFloat();
                const b = operand.asFloat().toFloatType(a.type);
                break :blk Value.fromFloat(a.multiply(b));
            },
            else => self.data,
        };
    }

    /// 原子除法。整数除零返回 `DivideByZero`。
    pub fn fetchDiv(self: *AtomicValue, operand: Value) AtomicError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.data = switch (self.data) {
            .int => blk: {
                const a = self.data.asInt();
                const b = operand.asInt().coerceTo(a.type) orelse return error.ArithmeticOverflow;
                break :blk Value.fromInt(a.divideTruncating(b) catch return error.DivideByZero);
            },
            .float => blk: {
                const a = self.data.asFloat();
                const b = operand.asFloat().toFloatType(a.type);
                break :blk Value.fromFloat(a.divide(b));
            },
            else => self.data,
        };
    }

    /// 原子取模。浮点取模通过除法取整再相减实现，除零返回错误。
    pub fn fetchMod(self: *AtomicValue, operand: Value) AtomicError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.data = switch (self.data) {
            .int => blk: {
                const a = self.data.asInt();
                const b = operand.asInt().coerceTo(a.type) orelse return error.ArithmeticOverflow;
                break :blk Value.fromInt(a.remainder(b) catch return error.DivideByZero);
            },
            .float => blk: {
                const a = self.data.asFloat();
                const b = operand.asFloat().toFloatType(a.type);
                if (b.isZero()) return error.DivideByZero;
                const q = a.divide(b);
                const q_int = q.toInt(.i128) catch return error.ArithmeticOverflow;
                const q_float = value.Float.fromInt(a.type, q_int);
                break :blk Value.fromFloat(a.subtract(b.multiply(q_float)));
            },
            else => self.data,
        };
    }

    /// 原子按位与。仅对整数类型有效。
    pub fn fetchAnd(self: *AtomicValue, operand: Value) AtomicError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.data = switch (self.data) {
            .int => blk: {
                const a = self.data.asInt();
                const b = operand.asInt().coerceTo(a.type) orelse return error.ArithmeticOverflow;
                break :blk Value.fromInt(a.bitwiseAnd(b));
            },
            else => self.data,
        };
    }

    /// 原子按位或。仅对整数类型有效。
    pub fn fetchOr(self: *AtomicValue, operand: Value) AtomicError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.data = switch (self.data) {
            .int => blk: {
                const a = self.data.asInt();
                const b = operand.asInt().coerceTo(a.type) orelse return error.ArithmeticOverflow;
                break :blk Value.fromInt(a.bitwiseOr(b));
            },
            else => self.data,
        };
    }

    /// 比较并交换。当前值等于 `expected` 时替换为 `new`，返回是否成功。
    pub fn cas(self: *AtomicValue, expected: Value, new: Value) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (std.meta.eql(self.data, expected)) {
            self.data = new;
            return true;
        }
        return false;
    }

    /// 原子交换，返回旧值并写入新值。
    pub fn xchg(self: *AtomicValue, new: Value) Value {
        self.mutex.lock();
        defer self.mutex.unlock();
        const old = self.data;
        self.data = new;
        return old;
    }

    /// 增加引用计数。
    pub fn ref(self: *AtomicValue) void {
        _ = self.ref_count.fetchAdd(1, .seq_cst);
    }

    /// 减少引用计数，返回是否为最后一次引用（计数归零）。
    pub fn unref(self: *AtomicValue) bool {
        return self.ref_count.fetchSub(1, .seq_cst) == 1;
    }
};

const testing = std.testing;

test "AtomicValue fetchAdd int type promotion (widen operand)" {
    var av = AtomicValue.init(Value.fromInt(Int.fromNative(.i32, @as(i32, 100))));
    const operand = Value.fromInt(Int.fromNative(.i8, @as(i8, 50)));
    try av.fetchAdd(operand);
    try testing.expectEqual(@as(i32, 150), av.load().asInt().toNative(i32));
    const operand2 = Value.fromInt(Int.fromNative(.i64, @as(i64, 200)));
    try av.fetchAdd(operand2);
    try testing.expectEqual(@as(i32, 350), av.load().asInt().toNative(i32));
}

test "AtomicValue fetchAdd int narrowing overflow returns error" {
    var av = AtomicValue.init(Value.fromInt(Int.fromNative(.i8, @as(i8, 100))));
    const operand = Value.fromInt(Int.fromNative(.i32, @as(i32, 1000)));
    try testing.expectError(error.ArithmeticOverflow, av.fetchAdd(operand));
    try testing.expectEqual(@as(i8, 100), av.load().asInt().toNative(i8));
}

test "AtomicValue fetchAdd int arithmetic overflow" {
    var av = AtomicValue.init(Value.fromInt(Int.fromNative(.i32, @as(i32, std.math.maxInt(i32)))));
    const operand = Value.fromInt(Int.fromNative(.i32, @as(i32, 1)));
    try testing.expectError(error.ArithmeticOverflow, av.fetchAdd(operand));
    try testing.expectEqual(@as(i32, std.math.maxInt(i32)), av.load().asInt().toNative(i32));
}

test "AtomicValue fetchSub int arithmetic overflow" {
    var av = AtomicValue.init(Value.fromInt(Int.fromNative(.i32, @as(i32, std.math.minInt(i32)))));
    const operand = Value.fromInt(Int.fromNative(.i32, @as(i32, 1)));
    try testing.expectError(error.ArithmeticOverflow, av.fetchSub(operand));
    try testing.expectEqual(@as(i32, std.math.minInt(i32)), av.load().asInt().toNative(i32));
}

test "AtomicValue fetchMul int arithmetic overflow" {
    var av = AtomicValue.init(Value.fromInt(Int.fromNative(.i32, @as(i32, std.math.maxInt(i32)))));
    const operand = Value.fromInt(Int.fromNative(.i32, @as(i32, 2)));
    try testing.expectError(error.ArithmeticOverflow, av.fetchMul(operand));
    try testing.expectEqual(@as(i32, std.math.maxInt(i32)), av.load().asInt().toNative(i32));
}

test "AtomicValue fetchDiv int divide by zero" {
    var av = AtomicValue.init(Value.fromInt(Int.fromNative(.i32, @as(i32, 100))));
    const zero = Value.fromInt(Int.fromNative(.i32, @as(i32, 0)));
    try testing.expectError(error.DivideByZero, av.fetchDiv(zero));
    try testing.expectEqual(@as(i32, 100), av.load().asInt().toNative(i32));
}

test "AtomicValue fetchMod int divide by zero" {
    var av = AtomicValue.init(Value.fromInt(Int.fromNative(.i32, @as(i32, 100))));
    const zero = Value.fromInt(Int.fromNative(.i32, @as(i32, 0)));
    try testing.expectError(error.DivideByZero, av.fetchMod(zero));
    try testing.expectEqual(@as(i32, 100), av.load().asInt().toNative(i32));
}

test "AtomicValue fetchAdd float type promotion" {
    var av = AtomicValue.init(Value.fromFloat(Float.fromNative(.f64, @as(f64, 1.5))));
    const operand = Value.fromFloat(Float.fromNative(.f32, @as(f32, 2.5)));
    try av.fetchAdd(operand);
    const result = av.load().asFloat().toNative(f64);
    try testing.expectApproxEqAbs(@as(f64, 4.0), result, 1e-9);
}

test "AtomicValue fetchMod float divide by zero" {
    var av = AtomicValue.init(Value.fromFloat(Float.fromNative(.f64, @as(f64, 10.0))));
    const zero = Value.fromFloat(Float.fromNative(.f64, @as(f64, 0.0)));
    try testing.expectError(error.DivideByZero, av.fetchMod(zero));
}

test "AtomicValue fetchMod float overflow returns error" {
    var av = AtomicValue.init(Value.fromFloat(Float.fromNative(.f64, @as(f64, 1e50))));
    const divisor = Value.fromFloat(Float.fromNative(.f64, @as(f64, 1.0)));
    try testing.expectError(error.ArithmeticOverflow, av.fetchMod(divisor));
}

test "AtomicValue fetchAnd/fetchOr int type promotion" {
    var av = AtomicValue.init(Value.fromInt(Int.fromNative(.i32, @as(i32, 0xFF))));
    const operand = Value.fromInt(Int.fromNative(.i8, @as(i8, 0x0F)));
    try av.fetchAnd(operand);
    try testing.expectEqual(@as(i32, 0x0F), av.load().asInt().toNative(i32));
    const operand2 = Value.fromInt(Int.fromNative(.i16, @as(i16, 0x100)));
    try av.fetchOr(operand2);
    try testing.expectEqual(@as(i32, 0x10F), av.load().asInt().toNative(i32));
}

test "AtomicValue fetchAnd int narrowing overflow returns error" {
    var av = AtomicValue.init(Value.fromInt(Int.fromNative(.i8, @as(i8, 0x0F))));
    const operand = Value.fromInt(Int.fromNative(.i32, @as(i32, 256)));
    try testing.expectError(error.ArithmeticOverflow, av.fetchAnd(operand));
}
