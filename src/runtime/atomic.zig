//! Atomic<T> 原子操作
//!
//! 文档 §3.4: Atomic<T> 是跨协程共享原子状态的唯一方式，替代 Arc<T>
//!
//! 内部存储直接持 Glue Value（内联标量 int/float/bool/char，POD 无装箱），
//! 用 sync.Mutex（spinlock）保护读写——避免 std.atomic.Value(i128) 触发
//! LLVM i128 codegen bug。atomic 不在任何 benchmark 热路径，spinlock 开销可接受。
//! 算术调用 Glue Int/Float 的纯字节运算（无 i128/f128 原生算术）。

const std = @import("std");
const value = @import("value");
const sync = @import("sync");

const Value = value.Value;
const Int = value.Int;
const Float = value.Float;
const Mutex = sync.Mutex;

pub const AtomicError = error{
    ArithmeticOverflow,
    DivideByZero,
};

/// Atomic<T> 值 — 跨协程共享原子状态
/// 文档 §3.4: Atomic<T> 是引用类型，atomic expr 创建堆上原子值
/// T 限制为原始标量：int/float/bool/char（均内联在 Value 中，无装箱）
pub const AtomicValue = struct {
    /// 原子存储的值 — Glue Value（内联标量，POD）
    data: Value,
    /// 互斥锁 — 保护 data 的读写（spinlock）
    mutex: Mutex,
    /// 引用计数 — 归零时自动释放
    ref_count: std.atomic.Value(usize),

    /// 从 Glue Value 创建 AtomicValue（标量：int/float/bool/char）
    pub fn init(val: Value) AtomicValue {
        return AtomicValue{
            .data = val,
            .mutex = .{},
            .ref_count = std.atomic.Value(usize).init(1),
        };
    }

    /// 加载当前值（返回 Value 副本，内联标量无需 retain）
    pub fn load(self: *AtomicValue) Value {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.data;
    }

    /// 原子存储 Value
    pub fn store(self: *AtomicValue, val: Value) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.data = val;
    }

    /// 原子 fetch_add（int 用 Int.add，float 用 Float.add）
    /// 类型提升：operand coerceTo self.data 类型（保持 atomic 类型不变），溢出返回错误。
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

    /// 原子 fetch_sub
    /// 类型提升：operand coerceTo self.data 类型，溢出返回错误。
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

    /// 原子 fetch_mul
    /// 类型提升：operand coerceTo self.data 类型，溢出返回错误。
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

    /// 原子 fetch_div（整数除零返回 DivideByZero 错误）
    /// 类型提升：operand coerceTo self.data 类型。
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

    /// 原子 fetch_mod（整数除零返回 DivideByZero 错误）
    /// float 分支全软件：a - b × trunc(a/b)，trunc 通过软件 i128 中转（不丢精度）。
    /// 类型提升：operand toFloatTo self.data 类型。浮点截断溢出返回错误（不静默返回零）。
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

    /// 原子 fetch_and（位与，仅整数）
    /// 类型提升：operand coerceTo self.data 类型。
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

    /// 原子 fetch_or（位或，仅整数）
    /// 类型提升：operand coerceTo self.data 类型。
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

    /// CAS (compare-and-swap)，位精确比较（std.meta.eql），返回是否成功
    pub fn cas(self: *AtomicValue, expected: Value, new: Value) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (std.meta.eql(self.data, expected)) {
            self.data = new;
            return true;
        }
        return false;
    }

    /// 原子交换，返回旧值
    pub fn xchg(self: *AtomicValue, new: Value) Value {
        self.mutex.lock();
        defer self.mutex.unlock();
        const old = self.data;
        self.data = new;
        return old;
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

// ============================================================
// 测试：支撑 §2.15 类型转换规范 + 溢出检测（F2/F3）
// ============================================================

const testing = std.testing;

test "AtomicValue fetchAdd int type promotion (widen operand)" {
    // F2: operand 宽于 atomic 类型时，coerceTo 应安全 narrowing
    // i32 atomic + i8 operand（小转大后大转小，值在范围内）
    var av = AtomicValue.init(Value.fromInt(Int.fromNative(.i32, @as(i32, 100))));
    const operand = Value.fromInt(Int.fromNative(.i8, @as(i8, 50)));
    try av.fetchAdd(operand);
    try testing.expectEqual(@as(i32, 150), av.load().asInt().toNative(i32));

    // i32 atomic + i64 operand（大转小，值在 i32 范围内）
    const operand2 = Value.fromInt(Int.fromNative(.i64, @as(i64, 200)));
    try av.fetchAdd(operand2);
    try testing.expectEqual(@as(i32, 350), av.load().asInt().toNative(i32));
}

test "AtomicValue fetchAdd int narrowing overflow returns error" {
    // F2: operand 值超出 atomic 类型范围 → coerceTo 返回 null → ArithmeticOverflow
    var av = AtomicValue.init(Value.fromInt(Int.fromNative(.i8, @as(i8, 100))));
    // i32 值 1000 无法 coerceTo i8
    const operand = Value.fromInt(Int.fromNative(.i32, @as(i32, 1000)));
    try testing.expectError(error.ArithmeticOverflow, av.fetchAdd(operand));
    // 原值不变
    try testing.expectEqual(@as(i8, 100), av.load().asInt().toNative(i8));
}

test "AtomicValue fetchAdd int arithmetic overflow" {
    // F3: i32 max + 1 → 溢出
    var av = AtomicValue.init(Value.fromInt(Int.fromNative(.i32, @as(i32, std.math.maxInt(i32)))));
    const operand = Value.fromInt(Int.fromNative(.i32, @as(i32, 1)));
    try testing.expectError(error.ArithmeticOverflow, av.fetchAdd(operand));
    try testing.expectEqual(@as(i32, std.math.maxInt(i32)), av.load().asInt().toNative(i32));
}

test "AtomicValue fetchSub int arithmetic overflow" {
    // F3: i32 min - 1 → 溢出
    var av = AtomicValue.init(Value.fromInt(Int.fromNative(.i32, @as(i32, std.math.minInt(i32)))));
    const operand = Value.fromInt(Int.fromNative(.i32, @as(i32, 1)));
    try testing.expectError(error.ArithmeticOverflow, av.fetchSub(operand));
    try testing.expectEqual(@as(i32, std.math.minInt(i32)), av.load().asInt().toNative(i32));
}

test "AtomicValue fetchMul int arithmetic overflow" {
    // F3: i32 max × 2 → 溢出
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
    // F2: f32 operand + f64 atomic → toFloatType 提升到 f64
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
    // F5: 被除数极大、除数极小 → 商超出 i128 范围 → ArithmeticOverflow（不静默返回零）
    // 注意：商必须在 f64 范围内（不能是 Infinity），但超出 i128 范围（~1.7e38）。
    // 1e50 / 1.0 = 1e50，> i128 max 但 < f64 max（~1.8e308）。
    var av = AtomicValue.init(Value.fromFloat(Float.fromNative(.f64, @as(f64, 1e50))));
    const divisor = Value.fromFloat(Float.fromNative(.f64, @as(f64, 1.0)));
    try testing.expectError(error.ArithmeticOverflow, av.fetchMod(divisor));
}

test "AtomicValue fetchAnd/fetchOr int type promotion" {
    // F2: 位运算也需类型提升
    var av = AtomicValue.init(Value.fromInt(Int.fromNative(.i32, @as(i32, 0xFF))));
    const operand = Value.fromInt(Int.fromNative(.i8, @as(i8, 0x0F)));
    try av.fetchAnd(operand);
    try testing.expectEqual(@as(i32, 0x0F), av.load().asInt().toNative(i32));

    const operand2 = Value.fromInt(Int.fromNative(.i16, @as(i16, 0x100)));
    try av.fetchOr(operand2);
    try testing.expectEqual(@as(i32, 0x10F), av.load().asInt().toNative(i32));
}

test "AtomicValue fetchAnd int narrowing overflow returns error" {
    // F2: operand 值超出 atomic i8 范围
    var av = AtomicValue.init(Value.fromInt(Int.fromNative(.i8, @as(i8, 0x0F))));
    const operand = Value.fromInt(Int.fromNative(.i32, @as(i32, 256))); // 超 i8 范围
    try testing.expectError(error.ArithmeticOverflow, av.fetchAnd(operand));
}
