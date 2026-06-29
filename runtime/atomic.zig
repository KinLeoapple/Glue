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
const Mutex = sync.Mutex;

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
    pub fn fetchAdd(self: *AtomicValue, operand: Value) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.data = switch (self.data) {
            .int => Value.fromInt(self.data.asInt().add(operand.asInt()).result),
            .float => Value.fromFloat(self.data.asFloat().add(operand.asFloat())),
            else => self.data,
        };
    }

    /// 原子 fetch_sub
    pub fn fetchSub(self: *AtomicValue, operand: Value) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.data = switch (self.data) {
            .int => Value.fromInt(self.data.asInt().subtract(operand.asInt()).result),
            .float => Value.fromFloat(self.data.asFloat().subtract(operand.asFloat())),
            else => self.data,
        };
    }

    /// 原子 fetch_mul
    pub fn fetchMul(self: *AtomicValue, operand: Value) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.data = switch (self.data) {
            .int => Value.fromInt(self.data.asInt().multiply(operand.asInt()).result),
            .float => Value.fromFloat(self.data.asFloat().multiply(operand.asFloat())),
            else => self.data,
        };
    }

    /// 原子 fetch_div（整数除零返回 DivideByZero 错误）
    pub fn fetchDiv(self: *AtomicValue, operand: Value) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.data = switch (self.data) {
            .int => Value.fromInt(try self.data.asInt().divideTruncating(operand.asInt())),
            .float => Value.fromFloat(self.data.asFloat().divide(operand.asFloat())),
            else => self.data,
        };
    }

    /// 原子 fetch_mod（整数除零返回 DivideByZero 错误）
    pub fn fetchMod(self: *AtomicValue, operand: Value) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.data = switch (self.data) {
            .int => Value.fromInt(try self.data.asInt().remainder(operand.asInt())),
            .float => Value.fromFloat(self.data.asFloat().divide(operand.asFloat())),
            else => self.data,
        };
    }

    /// 原子 fetch_and（位与，仅整数）
    pub fn fetchAnd(self: *AtomicValue, operand: Value) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.data = switch (self.data) {
            .int => Value.fromInt(self.data.asInt().bitwiseAnd(operand.asInt())),
            else => self.data,
        };
    }

    /// 原子 fetch_or（位或，仅整数）
    pub fn fetchOr(self: *AtomicValue, operand: Value) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.data = switch (self.data) {
            .int => Value.fromInt(self.data.asInt().bitwiseOr(operand.asInt())),
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
