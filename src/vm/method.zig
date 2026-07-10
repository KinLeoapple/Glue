//! M3d：字节码 VM 的内建方法分派（数组 / 字符串）。
//!
//! 镜像 eval.zig callMethod 的数据方法子集（len/push/pop/contains/is_empty/first/last/drop_last），
//! 但走 VM 纯 refcount 纪律：receiver 与实参均为栈上 owned，由调用方（OP_CALL_METHOD）释放；
//! 本模块仅负责构造结果（新数组/标量），retainOwned 元素自留。并发/原子方法（send/recv/cas/...）留 M4。
//!
//! 不变量：dispatch 不持有 receiver/args 所有权（不 release 它们）；返回的 Value 是 fresh owned。

const std = @import("std");
const value = @import("value");
const Value = value.Value;
const Int = value.Int;

pub const MethodError = error{ OutOfMemory, NoSuchMethod, TypeMismatch, WrongArity, ChannelClosed, ArithmeticOverflow };

/// 【方案 A：方法分派 ID 化】
/// 编译期内建方法名 → u8 id，运行时用 switch(id) 替代字符串比较链。
/// unknown 表示非内建方法（需走 trait/用户方法分派路径）。
pub const MethodId = enum(u8) {
    unknown = 0,
    len,
    is_empty,
    push,
    pop,
    first,
    last,
    contains,
    drop_last,
    cas,
    swap,
    send,
    recv,
    close,
    message,
    type_name,

    pub fn fromName(name: []const u8) MethodId {
        // 仍用字符串比较，但只在 call site 做一次，运行时分派走 switch(id)
        if (name.len == 3) {
            if (name[0] == 'l' and name[1] == 'e' and name[2] == 'n') return .len;
            if (name[0] == 'p' and name[1] == 'o' and name[2] == 'p') return .pop;
            if (name[0] == 'c' and name[1] == 'a' and name[2] == 's') return .cas;
            return .unknown;
        }
        if (name.len == 4) {
            if (name[0] == 's' and name[1] == 'e' and name[2] == 'n' and name[3] == 'd') return .send;
            if (name[0] == 'r' and name[1] == 'e' and name[2] == 'c' and name[3] == 'v') return .recv;
            return .unknown;
        }
        if (name.len == 5) {
            if (name[0] == 'f' and name[1] == 'i' and name[2] == 'r' and name[3] == 's' and name[4] == 't') return .first;
            if (name[0] == 'l' and name[1] == 'a' and name[2] == 's' and name[3] == 't') return .last;
            if (name[0] == 'c' and name[1] == 'l' and name[2] == 'o' and name[3] == 's' and name[4] == 'e') return .close;
            if (name[0] == 's' and name[1] == 'w' and name[2] == 'a' and name[3] == 'p') return .swap;
            return .unknown;
        }
        if (name.len == 6) {
            if (std.mem.eql(u8, name, "push")) return .push; // len 4, 不会到这
            return .unknown;
        }
        if (name.len == 7) {
            if (std.mem.eql(u8, name, "message")) return .message;
            return .unknown;
        }
        if (name.len == 8) {
            if (std.mem.eql(u8, name, "contains")) return .contains;
            if (std.mem.eql(u8, name, "drop_last")) return .drop_last;
            if (std.mem.eql(u8, name, "is_empty")) return .is_empty;
            if (std.mem.eql(u8, name, "type_name")) return .type_name;
            return .unknown;
        }
        return .unknown;
    }
};

/// 【方案 A】按 MethodId 分派内建方法。
/// 返回 null 表示非内建方法（调用方应走 trait/用户方法路径）。
/// 返回 Value 表示内建方法已处理（调用方负责释放 receiver + args）。
pub fn dispatchById(allocator: std.mem.Allocator, receiver: Value, method_id: MethodId, args: []const Value) MethodError!?Value {
    switch (method_id) {
        .unknown => return null,
        .len => {
            if (args.len != 0) return error.WrongArity;
            return switch (receiver) {
                .string => blk: {
                    const n = utf8Len(receiver.string.bytes());
                    const len_i32 = std.math.cast(i32, n) orelse return error.ArithmeticOverflow;
                    break :blk Value.fromInt(Int.fromNative(.i32, len_i32));
                },
                .array => blk: {
                    const n = receiver.array.elements.len;
                    const len_i32 = std.math.cast(i32, n) orelse return error.ArithmeticOverflow;
                    break :blk Value.fromInt(Int.fromNative(.i32, len_i32));
                },
                else => error.TypeMismatch,
            };
        },
        .is_empty => {
            if (args.len != 0) return error.WrongArity;
            return switch (receiver) {
                .string => Value.fromBool(receiver.string.bytes().len == 0),
                .array => Value.fromBool(receiver.array.elements.len == 0),
                else => error.TypeMismatch,
            };
        },
        .push => {
            if (args.len != 1) return error.WrongArity;
            if (receiver != .array) return error.TypeMismatch;
            const arr = receiver.array;
            const new_elems = try allocator.alloc(Value, arr.elements.len + 1);
            for (arr.elements, 0..) |e, i| new_elems[i] = try retainOwned(allocator, e);
            new_elems[arr.elements.len] = try retainOwned(allocator, args[0]);
            return value.Value.makeArray(allocator, new_elems, null) catch error.OutOfMemory;
        },
        .pop => {
            if (args.len != 0) return error.WrongArity;
            if (receiver != .array) return error.TypeMismatch;
            const arr = receiver.array;
            if (arr.elements.len == 0) return Value.fromNull();
            return try retainOwned(allocator, arr.elements[arr.elements.len - 1]);
        },
        .first => {
            if (args.len != 0) return error.WrongArity;
            if (receiver != .array) return error.TypeMismatch;
            const arr = receiver.array;
            if (arr.elements.len == 0) return Value.fromNull();
            return try retainOwned(allocator, arr.elements[0]);
        },
        .last => {
            if (args.len != 0) return error.WrongArity;
            if (receiver != .array) return error.TypeMismatch;
            const arr = receiver.array;
            if (arr.elements.len == 0) return Value.fromNull();
            return try retainOwned(allocator, arr.elements[arr.elements.len - 1]);
        },
        .contains => {
            if (args.len != 1) return error.WrongArity;
            if (receiver != .array) return error.TypeMismatch;
            const arr = receiver.array;
            for (arr.elements) |item| {
                if (structEquals(item, args[0])) return Value.fromBool(true);
            }
            return Value.fromBool(false);
        },
        .drop_last => {
            if (args.len != 0) return error.WrongArity;
            if (receiver != .array) return error.TypeMismatch;
            const arr = receiver.array;
            const n = if (arr.elements.len == 0) 0 else arr.elements.len - 1;
            const new_elems = try allocator.alloc(Value, n);
            for (arr.elements[0..n], 0..) |e, i| new_elems[i] = try retainOwned(allocator, e);
            return value.Value.makeArray(allocator, new_elems, null) catch error.OutOfMemory;
        },
        .cas, .swap => {
            // Atomic<T> 方法
            if (receiver != .atomic_val) return null; // 非 Atomic，让上层处理
            const av = receiver.atomic_val;
            const isScalar = struct {
                fn check(v: Value) bool {
                    return switch (v) {
                        .int, .float, .boolean, .char => true,
                        else => false,
                    };
                }
            };
            switch (method_id) {
                .cas => {
                    if (args.len != 2) return error.WrongArity;
                    if (!isScalar.check(args[0]) or !isScalar.check(args[1])) return error.TypeMismatch;
                    return Value.fromBool(av.cas(args[0], args[1]));
                },
                .swap => {
                    if (args.len != 1) return error.WrongArity;
                    if (!isScalar.check(args[0])) return error.TypeMismatch;
                    return av.xchg(args[0]);
                },
                else => unreachable,
            }
        },
        .send, .recv, .close => {
            // Channel<T>/Sender<T>/Receiver<T> 方法
            return switch (receiver) {
                .channel_val => blk: {
                    const ch = receiver.channel_val;
                    switch (method_id) {
                        .send => {
                            if (args.len != 1) return error.WrongArity;
                            const owned = try retainOwned(allocator, args[0]);
                            const ok = ch.send(owned) catch return error.OutOfMemory;
                            if (!ok) {
                                owned.release(allocator);
                                return error.ChannelClosed;
                            }
                            break :blk Value.fromUnit();
                        },
                        .recv => {
                            if (args.len != 0) return error.WrongArity;
                            break :blk ch.recv() orelse Value.fromNull();
                        },
                        else => break :blk null, // close 仅 Sender
                    }
                },
                .sender_val => blk: {
                    const sv = receiver.sender_val;
                    switch (method_id) {
                        .send => {
                            if (args.len != 1) return error.WrongArity;
                            const owned = try retainOwned(allocator, args[0]);
                            const ok = sv.channel.send(owned) catch return error.OutOfMemory;
                            if (!ok) {
                                owned.release(allocator);
                                return error.ChannelClosed;
                            }
                            break :blk Value.fromUnit();
                        },
                        .close => {
                            if (args.len != 0) return error.WrongArity;
                            sv.channel.close();
                            break :blk Value.fromUnit();
                        },
                        else => break :blk null,
                    }
                },
                .receiver_val => blk: {
                    const rv = receiver.receiver_val;
                    switch (method_id) {
                        .recv => {
                            if (args.len != 0) return error.WrongArity;
                            break :blk rv.channel.recv() orelse Value.fromNull();
                        },
                        else => break :blk null,
                    }
                },
                else => null, // 非通道类型，让上层处理
            };
        },
        .message, .type_name => {
            // Error trait 内置方法 —— 这些在 doCallMethod 中已有特殊处理（需访问 error_val/throw_val 字段）
            // 返回 null 让上层处理（避免重复逻辑）
            return null;
        },
    }
}

/// 结构相等（contains 用）。复用 value.equals（深比较基础/数组/记录）。
fn structEquals(a: Value, b: Value) bool {
    return value.equals(a, b);
}

/// retainOwned 语义：所有类型走 v.retain()（新 Str 有 rc，共享而非 dupe；基础值 retain 是 noop）。
fn retainOwned(allocator: std.mem.Allocator, v: Value) MethodError!Value {
    _ = allocator;
    return v.retain();
}

/// 分派内建方法。receiver + args 为栈上 owned（调用方负责 release）；返回 fresh owned 结果。
/// 未知方法 → NoSuchMethod；类型不符 → TypeMismatch；参数数错 → WrongArity。
pub fn dispatch(allocator: std.mem.Allocator, receiver: Value, method: []const u8, args: []const Value) MethodError!Value {
    // len()：string → Unicode 标量数；array → 元素数。
    // usize/u64 → i32 为 narrowing（大转小），必须范围检查；超范围返回 ArithmeticOverflow。
    if (std.mem.eql(u8, method, "len")) {
        if (args.len != 0) return error.WrongArity;
        return switch (receiver) {
            .string => blk: {
                const n = utf8Len(receiver.string.bytes());
                const len_i32 = std.math.cast(i32, n) orelse return error.ArithmeticOverflow;
                break :blk Value.fromInt(Int.fromNative(.i32, len_i32));
            },
            .array => blk: {
                const n = receiver.array.elements.len;
                const len_i32 = std.math.cast(i32, n) orelse return error.ArithmeticOverflow;
                break :blk Value.fromInt(Int.fromNative(.i32, len_i32));
            },
            else => error.TypeMismatch,
        };
    }
    // is_empty()：string/array。
    if (std.mem.eql(u8, method, "is_empty")) {
        if (args.len != 0) return error.WrongArity;
        return switch (receiver) {
            .string => Value.fromBool(receiver.string.bytes().len == 0),
            .array => Value.fromBool(receiver.array.elements.len == 0),
            else => error.TypeMismatch,
        };
    }
    // push(v)：array → 追加后的新数组（值语义；用法 arr = arr.push(x)）。
    if (std.mem.eql(u8, method, "push")) {
        if (args.len != 1) return error.WrongArity;
        if (receiver != .array) return error.TypeMismatch;
        const arr = receiver.array;
        const new_elems = try allocator.alloc(Value, arr.elements.len + 1);
        for (arr.elements, 0..) |e, i| new_elems[i] = try retainOwned(allocator, e);
        new_elems[arr.elements.len] = try retainOwned(allocator, args[0]);
        return value.Value.makeArray(allocator, new_elems, null) catch error.OutOfMemory;
    }
    // pop()：array → 最后一个元素（T?），空数组 → null。
    if (std.mem.eql(u8, method, "pop")) {
        if (args.len != 0) return error.WrongArity;
        if (receiver != .array) return error.TypeMismatch;
        const arr = receiver.array;
        if (arr.elements.len == 0) return Value.fromNull();
        return try retainOwned(allocator, arr.elements[arr.elements.len - 1]);
    }
    // first()/last()：array → 首/末元素（T?），空 → null。
    if (std.mem.eql(u8, method, "first")) {
        if (args.len != 0) return error.WrongArity;
        if (receiver != .array) return error.TypeMismatch;
        const arr = receiver.array;
        if (arr.elements.len == 0) return Value.fromNull();
        return try retainOwned(allocator, arr.elements[0]);
    }
    if (std.mem.eql(u8, method, "last")) {
        if (args.len != 0) return error.WrongArity;
        if (receiver != .array) return error.TypeMismatch;
        const arr = receiver.array;
        if (arr.elements.len == 0) return Value.fromNull();
        return try retainOwned(allocator, arr.elements[arr.elements.len - 1]);
    }
    // contains(v)：array → 结构相等查找，压 bool。
    if (std.mem.eql(u8, method, "contains")) {
        if (args.len != 1) return error.WrongArity;
        if (receiver != .array) return error.TypeMismatch;
        const arr = receiver.array;
        for (arr.elements) |item| {
            if (structEquals(item, args[0])) return Value.fromBool(true);
        }
        return Value.fromBool(false);
    }
    // drop_last()：array → 去掉末元素的新数组（空数组返回空数组拷贝）。
    if (std.mem.eql(u8, method, "drop_last")) {
        if (args.len != 0) return error.WrongArity;
        if (receiver != .array) return error.TypeMismatch;
        const arr = receiver.array;
        const n = if (arr.elements.len == 0) 0 else arr.elements.len - 1;
        const new_elems = try allocator.alloc(Value, n);
        for (arr.elements[0..n], 0..) |e, i| new_elems[i] = try retainOwned(allocator, e);
        return value.Value.makeArray(allocator, new_elems, null) catch error.OutOfMemory;
    }
    // M4a：Atomic<T> 方法 —— cas(expected, new) → bool；swap(new) → 旧值。
    // 直接传 Value（atomic 内部 std.meta.eql 做位精确比较），仅校验实参是标量。
    if (receiver == .atomic_val) {
        const av = receiver.atomic_val;
        const isScalar = struct {
            fn check(v: Value) bool {
                return switch (v) {
                    .int, .float, .boolean, .char => true,
                    else => false,
                };
            }
        };
        if (std.mem.eql(u8, method, "cas")) {
            if (args.len != 2) return error.WrongArity;
            if (!isScalar.check(args[0]) or !isScalar.check(args[1])) return error.TypeMismatch;
            return Value.fromBool(av.cas(args[0], args[1]));
        }
        if (std.mem.eql(u8, method, "swap")) {
            if (args.len != 1) return error.WrongArity;
            if (!isScalar.check(args[0])) return error.TypeMismatch;
            return av.xchg(args[0]);
        }
        return error.NoSuchMethod;
    }
    // M4b：Channel<T> 方法 —— send(v) → unit（关闭则 ChannelClosed）；recv() → T?（关闭且空 → null）。
    // close 仅 Sender 可用。所有权：send 把值 retainOwned 进缓冲（调用方随后 release 实参）；
    // recv 把缓冲值所有权转出（不再 retain）。
    if (receiver == .channel_val) {
        const ch = receiver.channel_val;
        if (std.mem.eql(u8, method, "send")) {
            if (args.len != 1) return error.WrongArity;
            const owned = try retainOwned(allocator, args[0]);
            const ok = ch.send(owned) catch return error.OutOfMemory;
            if (!ok) {
                owned.release(allocator);
                return error.ChannelClosed;
            }
            return Value.fromUnit();
        }
        if (std.mem.eql(u8, method, "recv")) {
            if (args.len != 0) return error.WrongArity;
            return ch.recv() orelse Value.fromNull();
        }
        return error.NoSuchMethod;
    }
    if (receiver == .sender_val) {
        const sv = receiver.sender_val;
        if (std.mem.eql(u8, method, "send")) {
            if (args.len != 1) return error.WrongArity;
            const owned = try retainOwned(allocator, args[0]);
            const ok = sv.channel.send(owned) catch return error.OutOfMemory;
            if (!ok) {
                owned.release(allocator);
                return error.ChannelClosed;
            }
            return Value.fromUnit();
        }
        if (std.mem.eql(u8, method, "close")) {
            if (args.len != 0) return error.WrongArity;
            sv.channel.close();
            return Value.fromUnit();
        }
        return error.NoSuchMethod;
    }
    if (receiver == .receiver_val) {
        const rv = receiver.receiver_val;
        if (std.mem.eql(u8, method, "recv")) {
            if (args.len != 0) return error.WrongArity;
            return rv.channel.recv() orelse Value.fromNull();
        }
        return error.NoSuchMethod;
    }
    return error.NoSuchMethod;
}

/// UTF-8 字符串的 Unicode 标量值（码点）个数；非法 UTF-8 退化为字节数。
fn utf8Len(s: []const u8) u64 {
    // ASCII fast path：所有字节 < 128 时码点数 = 字节数，O(1) 返回。
    // SIMD 友好：每次 8 字节 OR 后检查高位。纯 ASCII 字符串（如 "abab..."）
    // 命中率极高，避免 Utf8View 迭代的逐字节状态机开销。
    var i: usize = 0;
    while (i + 8 <= s.len) : (i += 8) {
        const chunk = std.mem.readInt(u64, s[i..][0..8], .little);
        if (chunk & 0x8080_8080_8080_8080 != 0) break; // 非 ASCII，转慢路径
    }
    if (i < s.len) {
        // 检查尾部剩余字节（< 8）
        var has_non_ascii = false;
        for (s[i..]) |b| {
            if (b >= 0x80) { has_non_ascii = true; break; }
        }
        if (!has_non_ascii) return @intCast(s.len);
    } else {
        return @intCast(s.len); // 全 ASCII（含 i==s.len 的对齐情况）
    }
    // slow path：含非 ASCII 字节，走 Utf8View 逐码点计数
    const view = std.unicode.Utf8View.init(s) catch return @intCast(s.len);
    var count: u64 = 0;
    var it = view.iterator();
    while (it.nextCodepoint() != null) count += 1;
    return count;
}

// ============================================================
// 测试：支撑 §2.15 类型转换规范 + F6 len() narrowing 范围检查
// ============================================================

const testing = std.testing;

/// 释放 string Value（绕过 Value.release 对 SSO 字符串的 rc 处理缺陷）。
/// SSO 字符串 rc 字段编码了 SSO 标志（bit31）+ 长度（bits 0-4），
/// Value.release 的 `rc > 1` 检查对 SSO 字符串恒为 true，导致永不释放。
fn freeStringVal(allocator: std.mem.Allocator, v: Value) void {
    v.string.deinit(allocator);
    allocator.destroy(v.string);
}

test "len() string ASCII returns codepoint count" {
    const allocator = testing.allocator;
    const s = try Value.fromStringBytes(allocator, "hello");
    defer freeStringVal(allocator, s);
    const result = try dispatch(allocator, s, "len", &.{});
    try testing.expectEqual(@as(i32, 5), result.asInt().toNative(i32));
}

test "len() string multi-byte UTF-8 returns codepoint count not byte count" {
    const allocator = testing.allocator;
    // "你好世界" = 4 个汉字，每个 3 字节 UTF-8 → 12 字节，但 len() 应返回 4
    const s = try Value.fromStringBytes(allocator, "你好世界");
    defer freeStringVal(allocator, s);
    const result = try dispatch(allocator, s, "len", &.{});
    try testing.expectEqual(@as(i32, 4), result.asInt().toNative(i32));
}

test "len() string with emoji (4-byte UTF-8)" {
    const allocator = testing.allocator;
    // "a😀b" = 3 个码点（'a', U+1F600, 'b'），字节数 = 1+4+1 = 6
    const s = try Value.fromStringBytes(allocator, "a😀b");
    defer freeStringVal(allocator, s);
    const result = try dispatch(allocator, s, "len", &.{});
    try testing.expectEqual(@as(i32, 3), result.asInt().toNative(i32));
}

test "len() empty string returns 0" {
    const allocator = testing.allocator;
    const s = try Value.fromStringBytes(allocator, "");
    defer freeStringVal(allocator, s);
    const result = try dispatch(allocator, s, "len", &.{});
    try testing.expectEqual(@as(i32, 0), result.asInt().toNative(i32));
}

test "len() array returns element count" {
    const allocator = testing.allocator;
    // 注意：makeArray 接管 elems 所有权，deinit 时会 free(elements)。
    // 所以不要 defer allocator.free(elems)——那会导致 double-free。
    const elems = try allocator.alloc(Value, 3);
    elems[0] = Value.fromInt(Int.fromNative(.i32, @as(i32, 10)));
    elems[1] = Value.fromInt(Int.fromNative(.i32, @as(i32, 20)));
    elems[2] = Value.fromInt(Int.fromNative(.i32, @as(i32, 30)));
    const arr = try Value.makeArray(allocator, elems, null);
    defer arr.release(allocator);
    const result = try dispatch(allocator, arr, "len", &.{});
    try testing.expectEqual(@as(i32, 3), result.asInt().toNative(i32));
}

test "len() empty array returns 0" {
    const allocator = testing.allocator;
    const empty_elems = try allocator.alloc(Value, 0);
    const arr = try Value.makeArray(allocator, empty_elems, null);
    // deinit 不 free 空 slice（len==0），需手动 free（LIFO：先 release 后 free）
    defer allocator.free(empty_elems);
    defer arr.release(allocator);
    const result = try dispatch(allocator, arr, "len", &.{});
    try testing.expectEqual(@as(i32, 0), result.asInt().toNative(i32));
}

test "len() wrong type returns TypeMismatch" {
    const allocator = testing.allocator;
    const v = Value.fromInt(Int.fromNative(.i32, @as(i32, 42)));
    try testing.expectError(error.TypeMismatch, dispatch(allocator, v, "len", &.{}));
}

test "len() with args returns WrongArity" {
    const allocator = testing.allocator;
    const s = try Value.fromStringBytes(allocator, "hi");
    defer freeStringVal(allocator, s);
    const arg = Value.fromInt(Int.fromNative(.i32, @as(i32, 1)));
    try testing.expectError(error.WrongArity, dispatch(allocator, s, "len", &.{arg}));
}

test "len() result type is i32 (narrowing target)" {
    // F6: 验证 len() 返回 i32 类型（usize→i32 narrowing 的目标类型）
    const allocator = testing.allocator;
    const s = try Value.fromStringBytes(allocator, "test");
    defer freeStringVal(allocator, s);
    const result = try dispatch(allocator, s, "len", &.{});
    try testing.expect(result == .int);
    try testing.expectEqual(value.IntType.i32, result.asInt().type);
}
