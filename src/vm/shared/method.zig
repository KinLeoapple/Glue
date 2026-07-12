//! 运行期内置方法分派。
//!
//! 提供按 MethodId 与按方法名字符串两种分派入口，支持数组、字符串、
//! 原子值与通道等接收者类型的常用方法（len/push/pop/send/recv 等），
//! 供 RegVM 在执行 op_call_method 时调用。

const std = @import("std");
const value = @import("value");

const Value = value.Value;
const Int = value.Int;

/// 方法调用可能产生的错误。
pub const MethodError = error{
    OutOfMemory,
    NoSuchMethod,
    TypeMismatch,
    WrongArity,
    ChannelClosed,
    ArithmeticOverflow,
};

/// 内置方法标识枚举，按方法名长度分组以便快速匹配。
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
    await_op,
    cancel,
    status,
    sender,
    receiver,
    prefix,

    /// 根据方法名返回对应的 MethodId，未匹配时返回 .unknown。
    /// 按名称长度分组后逐字节比较，避免重复哈希计算。
    pub fn fromName(name: []const u8) MethodId {
        if (name.len == 3) {
            if (name[0] == 'l' and name[1] == 'e' and name[2] == 'n') return .len;
            if (name[0] == 'p' and name[1] == 'o' and name[2] == 'p') return .pop;
            if (name[0] == 'c' and name[1] == 'a' and name[2] == 's') return .cas;
            return .unknown;
        }
        if (name.len == 4) {
            if (name[0] == 's' and name[1] == 'e' and name[2] == 'n' and name[3] == 'd') return .send;
            if (name[0] == 'r' and name[1] == 'e' and name[2] == 'c' and name[3] == 'v') return .recv;
            if (name[0] == 'p' and name[1] == 'u' and name[2] == 's' and name[3] == 'h') return .push;
            if (name[0] == 's' and name[1] == 'w' and name[2] == 'a' and name[3] == 'p') return .swap;
            return .unknown;
        }
        if (name.len == 5) {
            if (name[0] == 'f' and name[1] == 'i' and name[2] == 'r' and name[3] == 's' and name[4] == 't') return .first;
            if (name[0] == 'l' and name[1] == 'a' and name[2] == 's' and name[3] == 't') return .last;
            if (name[0] == 'c' and name[1] == 'l' and name[2] == 'o' and name[3] == 's' and name[4] == 'e') return .close;
            if (name[0] == 'a' and name[1] == 'w' and name[2] == 'a' and name[3] == 'i' and name[4] == 't') return .await_op;
            return .unknown;
        }
        if (name.len == 6) {
            if (name[0] == 's' and name[1] == 'e' and name[2] == 'n' and name[3] == 'd' and name[4] == 'e' and name[5] == 'r') return .sender;
            if (name[0] == 'c' and name[1] == 'a' and name[2] == 'n' and name[3] == 'c' and name[4] == 'e' and name[5] == 'l') return .cancel;
            if (name[0] == 's' and name[1] == 't' and name[2] == 'a' and name[3] == 't' and name[4] == 'u' and name[5] == 's') return .status;
            if (name[0] == 'p' and name[1] == 'r' and name[2] == 'e' and name[3] == 'f' and name[4] == 'i' and name[5] == 'x') return .prefix;
            return .unknown;
        }
        if (name.len == 7) {
            if (name[0] == 'm' and name[1] == 'e' and name[2] == 's' and name[3] == 's' and name[4] == 'a' and name[5] == 'g' and name[6] == 'e') return .message;
            return .unknown;
        }
        if (name.len == 8) {
            if (name[0] == 'c' and name[1] == 'o' and name[2] == 'n' and name[3] == 't' and name[4] == 'a' and name[5] == 'i' and name[6] == 'n' and name[7] == 's') return .contains;
            if (name[0] == 'i' and name[1] == 's' and name[2] == '_' and name[3] == 'e' and name[4] == 'm' and name[5] == 'p' and name[6] == 't' and name[7] == 'y') return .is_empty;
            if (name[0] == 't' and name[1] == 'y' and name[2] == 'p' and name[3] == 'e' and name[4] == '_' and name[5] == 'n' and name[6] == 'a' and name[7] == 'm' and name[8 - 1] == 'e') return .type_name;
            if (name[0] == 'r' and name[1] == 'e' and name[2] == 'c' and name[3] == 'e' and name[4] == 'i' and name[5] == 'v' and name[6] == 'e' and name[7] == 'r') return .receiver;
            return .unknown;
        }
        if (name.len == 9) {
            if (name[0] == 'd' and name[1] == 'r' and name[2] == 'o' and name[3] == 'p' and name[4] == '_' and name[5] == 'l' and name[6] == 'a' and name[7] == 's' and name[8] == 't') return .drop_last;
            return .unknown;
        }
        return .unknown;
    }
};

/// 按 MethodId 分派方法调用，返回结果值或 null（表示方法不适用）。
/// 对参数个数与接收者类型进行校验，失败时返回对应错误。
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
        // 原子值的比较交换与交换操作，仅接受标量参数
        .cas, .swap => {
            if (receiver != .atomic_val) return null;
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
        // 通道相关方法：send/recv/close，根据接收者类型分派
        .send, .recv, .close => {
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
                        else => break :blk null,
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
                else => null,
            };
        },
        // 以下方法由 VM 层直接处理，此处返回 null
        .message, .type_name => {
            return null;
        },
        .await_op, .cancel, .status, .sender, .receiver, .prefix => return null,
    }
}

/// 比较两个 Value 是否结构相等，委托给 value.equals。
fn structEquals(a: Value, b: Value) bool {
    return value.equals(a, b);
}

/// 对 Value 执行引用计数保留，返回保留后的新引用。
fn retainOwned(allocator: std.mem.Allocator, v: Value) MethodError!Value {
    _ = allocator;
    return v.retain();
}

/// 按方法名字符串分派方法调用。
/// 与 dispatchById 功能对应，但通过字符串比较匹配方法名，
/// 供无法预先解析 MethodId 的调用路径使用。
pub fn dispatch(allocator: std.mem.Allocator, receiver: Value, method: []const u8, args: []const Value) MethodError!Value {
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
    if (std.mem.eql(u8, method, "is_empty")) {
        if (args.len != 0) return error.WrongArity;
        return switch (receiver) {
            .string => Value.fromBool(receiver.string.bytes().len == 0),
            .array => Value.fromBool(receiver.array.elements.len == 0),
            else => error.TypeMismatch,
        };
    }
    if (std.mem.eql(u8, method, "push")) {
        if (args.len != 1) return error.WrongArity;
        if (receiver != .array) return error.TypeMismatch;
        const arr = receiver.array;
        const new_elems = try allocator.alloc(Value, arr.elements.len + 1);
        for (arr.elements, 0..) |e, i| new_elems[i] = try retainOwned(allocator, e);
        new_elems[arr.elements.len] = try retainOwned(allocator, args[0]);
        return value.Value.makeArray(allocator, new_elems, null) catch error.OutOfMemory;
    }
    if (std.mem.eql(u8, method, "pop")) {
        if (args.len != 0) return error.WrongArity;
        if (receiver != .array) return error.TypeMismatch;
        const arr = receiver.array;
        if (arr.elements.len == 0) return Value.fromNull();
        return try retainOwned(allocator, arr.elements[arr.elements.len - 1]);
    }
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
    if (std.mem.eql(u8, method, "contains")) {
        if (args.len != 1) return error.WrongArity;
        if (receiver != .array) return error.TypeMismatch;
        const arr = receiver.array;
        for (arr.elements) |item| {
            if (structEquals(item, args[0])) return Value.fromBool(true);
        }
        return Value.fromBool(false);
    }
    if (std.mem.eql(u8, method, "drop_last")) {
        if (args.len != 0) return error.WrongArity;
        if (receiver != .array) return error.TypeMismatch;
        const arr = receiver.array;
        const n = if (arr.elements.len == 0) 0 else arr.elements.len - 1;
        const new_elems = try allocator.alloc(Value, n);
        for (arr.elements[0..n], 0..) |e, i| new_elems[i] = try retainOwned(allocator, e);
        return value.Value.makeArray(allocator, new_elems, null) catch error.OutOfMemory;
    }
    // 原子值方法：cas / swap
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
    // 通道方法：send / recv
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
    // 发送端方法：send / close
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
    // 接收端方法：recv
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

/// 计算 UTF-8 字符串的码点数量（而非字节数）。
/// 先以 8 字节为块扫描 ASCII 快速路径，遇非 ASCII 再回退到码点迭代。
fn utf8Len(s: []const u8) u64 {
    // 按 8 字节块检查是否有非 ASCII 字节（高位为 1）
    var i: usize = 0;
    while (i + 8 <= s.len) : (i += 8) {
        const chunk = std.mem.readInt(u64, s[i..][0..8], .little);
        if (chunk & 0x8080_8080_8080_8080 != 0) break;
    }
    if (i < s.len) {
        var has_non_ascii = false;
        for (s[i..]) |b| {
            if (b >= 0x80) {
                has_non_ascii = true;
                break;
            }
        }
        if (!has_non_ascii) return @intCast(s.len);
    } else {
        return @intCast(s.len);
    }
    // 非 ASCII 路径：逐码点迭代计数
    const view = std.unicode.Utf8View.init(s) catch return @intCast(s.len);
    var count: u64 = 0;
    var it = view.iterator();
    while (it.nextCodepoint() != null) count += 1;
    return count;
}

const testing = std.testing;

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
    const s = try Value.fromStringBytes(allocator, "你好世界");
    defer freeStringVal(allocator, s);
    const result = try dispatch(allocator, s, "len", &.{});
    try testing.expectEqual(@as(i32, 4), result.asInt().toNative(i32));
}

test "len() string with emoji (4-byte UTF-8)" {
    const allocator = testing.allocator;
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
    const allocator = testing.allocator;
    const s = try Value.fromStringBytes(allocator, "test");
    defer freeStringVal(allocator, s);
    const result = try dispatch(allocator, s, "len", &.{});
    try testing.expect(result == .int);
    try testing.expectEqual(value.IntType.i32, result.asInt().type);
}
