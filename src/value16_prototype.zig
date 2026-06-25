//! 16B Tagged Union 原型验证
//!
//! 目标：验证 Value 从 64B → 16B 的可行性和性能提升
//! 方案：tag(u8) + payload(u64) 分离存储

const std = @import("std");

/// 16B Value 设计
pub const Value16 = struct {
    tag: ValueTag,
    _pad: [7]u8 = undefined, // 对齐到 8 字节边界
    payload: u64,

    /// 类型标签（8 位，256 种类型）
    pub const ValueTag = enum(u8) {
        // 内联类型（payload 直接存值）
        null_val = 0,
        unit = 1,
        boolean = 2, // payload: 0=false, 1=true
        small_int = 3, // payload: i48 (-2^47 ~ 2^47-1)
        char_val = 4, // payload: u21 Unicode 码点
        float = 5, // payload: f64 位模式

        // 装箱类型（payload 存指针）
        big_int = 10, // payload: *BigInt (i128 + type_tag)
        string = 11, // payload: *String ([]const u8)
        array = 12, // payload: *ArrayValue
        record = 13, // payload: *RecordValue
        adt = 14, // payload: *AdtValue
        newtype = 15, // payload: *NewtypeValue
        range = 16, // payload: *Range
        vm_closure = 17, // payload: *VmClosure
        partial = 18, // payload: *PartialApplication
        builtin = 19, // payload: *Builtin
        error_val = 20, // payload: *ErrorValue
        throw_val = 21, // payload: *ThrowValue

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

    // ============================================================
    // 编码函数（构造 Value16）
    // ============================================================

    pub inline fn fromNull() Value16 {
        return .{ .tag = .null_val, .payload = 0 };
    }

    pub inline fn fromUnit() Value16 {
        return .{ .tag = .unit, .payload = 0 };
    }

    pub inline fn fromBool(b: bool) Value16 {
        return .{ .tag = .boolean, .payload = if (b) 1 else 0 };
    }

    pub inline fn fromSmallInt(i: i48) Value16 {
        return .{ .tag = .small_int, .payload = @bitCast(@as(i64, i)) };
    }

    pub inline fn fromChar(c: u21) Value16 {
        return .{ .tag = .char_val, .payload = c };
    }

    pub inline fn fromFloat(f: f64) Value16 {
        return .{ .tag = .float, .payload = @bitCast(f) };
    }

    pub inline fn fromPointer(tag: ValueTag, ptr: *anyopaque) Value16 {
        return .{ .tag = tag, .payload = @intFromPtr(ptr) };
    }

    // ============================================================
    // 解码函数（提取值）
    // ============================================================

    pub inline fn isNull(self: Value16) bool {
        return self.tag == .null_val;
    }

    pub inline fn isUnit(self: Value16) bool {
        return self.tag == .unit;
    }

    pub inline fn asBool(self: Value16) bool {
        std.debug.assert(self.tag == .boolean);
        return self.payload != 0;
    }

    pub inline fn asSmallInt(self: Value16) i48 {
        std.debug.assert(self.tag == .small_int);
        const i64_val: i64 = @bitCast(self.payload);
        return @intCast(i64_val);
    }

    pub inline fn asChar(self: Value16) u21 {
        std.debug.assert(self.tag == .char_val);
        return @intCast(self.payload);
    }

    pub inline fn asFloat(self: Value16) f64 {
        std.debug.assert(self.tag == .float);
        return @bitCast(self.payload);
    }

    pub inline fn asPointer(self: Value16, comptime T: type) *T {
        return @ptrFromInt(self.payload);
    }

    // ============================================================
    // 类型检查
    // ============================================================

    pub inline fn isInline(self: Value16) bool {
        return @intFromEnum(self.tag) < 10;
    }

    pub inline fn isBoxed(self: Value16) bool {
        return @intFromEnum(self.tag) >= 10;
    }

    // ============================================================
    // 引用计数（装箱类型）
    // ============================================================

    pub fn retain(self: Value16) Value16 {
        if (self.isBoxed()) {
            const box: *BoxedValue = @ptrFromInt(self.payload);
            box.rc += 1;
        }
        return self;
    }

    pub fn release(self: Value16, allocator: std.mem.Allocator) void {
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
};

/// 装箱值统一头部（所有堆分配类型的包装）
pub const BoxedValue = struct {
    tag: Value16.ValueTag,
    rc: u32,
    payload: union {
        big_int: struct { value: i128, type_tag: u8 },
        string: []const u8,
        ptr: *anyopaque, // 其他类型的泛型指针
    },

    pub fn releasePayload(self: *BoxedValue, allocator: std.mem.Allocator) void {
        switch (self.tag) {
            .string => allocator.free(self.payload.string),
            .big_int => {}, // 值类型，无需释放
            else => {
                // 其他类型需递归释放（这里简化）
                // 实际需要按类型调用对应的释放函数
            },
        }
    }
};

// ============================================================
// 性能微基准
// ============================================================

pub fn benchmarkStackCopy(allocator: std.mem.Allocator) !void {
    const iterations = 10_000_000;

    // 测试 1: 64B Value (模拟当前)
    {
        const Value64 = [8]u64; // 8×8 = 64 字节
        var stack = try std.ArrayList(Value64).initCapacity(allocator, 100);
        defer stack.deinit();

        const start = std.time.nanoTimestamp();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const val: Value64 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
            try stack.append(val);
            _ = stack.pop();
        }
        const elapsed = std.time.nanoTimestamp() - start;
        std.debug.print("64B copy: {d}ms ({d}ns/op)\n", .{
            @divTrunc(elapsed, 1_000_000),
            @divTrunc(elapsed, iterations),
        });
    }

    // 测试 2: 16B Value16
    {
        var stack = try std.ArrayList(Value16).initCapacity(allocator, 100);
        defer stack.deinit();

        const start = std.time.nanoTimestamp();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const val = Value16.fromSmallInt(42);
            try stack.append(val);
            _ = stack.pop();
        }
        const elapsed = std.time.nanoTimestamp() - start;
        std.debug.print("16B copy: {d}ms ({d}ns/op)\n", .{
            @divTrunc(elapsed, 1_000_000),
            @divTrunc(elapsed, iterations),
        });
    }

    // 测试 3: 8B u64（极限）
    {
        var stack = try std.ArrayList(u64).initCapacity(allocator, 100);
        defer stack.deinit();

        const start = std.time.nanoTimestamp();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            try stack.append(42);
            _ = stack.pop();
        }
        const elapsed = std.time.nanoTimestamp() - start;
        std.debug.print("8B copy:  {d}ms ({d}ns/op)\n", .{
            @divTrunc(elapsed, 1_000_000),
            @divTrunc(elapsed, iterations),
        });
    }
}

// ============================================================
// 单元测试
// ============================================================

test "Value16 size" {
    try std.testing.expectEqual(16, @sizeOf(Value16));
}

test "encode/decode null" {
    const v = Value16.fromNull();
    try std.testing.expect(v.isNull());
    try std.testing.expectEqual(Value16.ValueTag.null_val, v.tag);
}

test "encode/decode unit" {
    const v = Value16.fromUnit();
    try std.testing.expect(v.isUnit());
}

test "encode/decode bool" {
    const t = Value16.fromBool(true);
    const f = Value16.fromBool(false);
    try std.testing.expect(t.asBool());
    try std.testing.expect(!f.asBool());
}

test "encode/decode small int" {
    const v1 = Value16.fromSmallInt(42);
    const v2 = Value16.fromSmallInt(-12345);
    try std.testing.expectEqual(@as(i48, 42), v1.asSmallInt());
    try std.testing.expectEqual(@as(i48, -12345), v2.asSmallInt());
}

test "encode/decode char" {
    const v = Value16.fromChar('A');
    try std.testing.expectEqual(@as(u21, 'A'), v.asChar());
}

test "encode/decode float" {
    const v = Value16.fromFloat(3.14159);
    try std.testing.expectApproxEqRel(3.14159, v.asFloat(), 0.00001);
}

test "pointer round-trip" {
    var box = BoxedValue{
        .tag = .string,
        .rc = 1,
        .payload = .{ .string = "hello" },
    };
    const v = Value16.fromPointer(.string, &box);
    const recovered: *BoxedValue = @ptrFromInt(v.payload);
    try std.testing.expectEqual(@intFromPtr(&box), @intFromPtr(recovered));
}

test "inline vs boxed" {
    const inline_val = Value16.fromSmallInt(42);
    const boxed_val = Value16.fromPointer(.string, @ptrFromInt(0x1000));

    try std.testing.expect(inline_val.isInline());
    try std.testing.expect(!inline_val.isBoxed());

    try std.testing.expect(!boxed_val.isInline());
    try std.testing.expect(boxed_val.isBoxed());
}

test "refcount increment" {
    var box = BoxedValue{
        .tag = .array,
        .rc = 1,
        .payload = .{ .ptr = undefined },
    };
    const v = Value16.fromPointer(.array, &box);

    _ = v.retain();
    try std.testing.expectEqual(@as(u32, 2), box.rc);

    _ = v.retain();
    try std.testing.expectEqual(@as(u32, 3), box.rc);
}
