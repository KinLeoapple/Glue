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

pub const MethodError = error{ OutOfMemory, NoSuchMethod, TypeMismatch, WrongArity, ChannelClosed };

/// 结构相等（contains 用）。复用 value.zig 的 equals（深比较基础/数组/记录）。
fn structEq(a: Value, b: Value) bool {
    return a.equals(b);
}

/// retainOwned 语义：string dupe；array/record/adt/newtype rc+1；基础值原样。
/// 与 vm.zig retainOwned 一致（此处无 throw_val/error_val，方法不返回它们的内值）。
fn retainOwned(allocator: std.mem.Allocator, v: Value) MethodError!Value {
    if (v == .string) return Value{ .string = try allocator.dupe(u8, v.string) };
    return v.retain();
}

/// 分派内建方法。receiver + args 为栈上 owned（调用方负责 release）；返回 fresh owned 结果。
/// 未知方法 → NoSuchMethod；类型不符 → TypeMismatch；参数数错 → WrongArity。
pub fn dispatch(allocator: std.mem.Allocator, receiver: Value, method: []const u8, args: []const Value) MethodError!Value {
    // len()：string → Unicode 标量数；array → 元素数。
    if (std.mem.eql(u8, method, "len")) {
        if (args.len != 0) return error.WrongArity;
        return switch (receiver) {
            .string => |s| Value{ .integer = .{ .value = utf8Len(s), .type_tag = .i64 } },
            .array => |arr| Value{ .integer = .{ .value = @intCast(arr.elements.len), .type_tag = .i64 } },
            else => error.TypeMismatch,
        };
    }
    // is_empty()：string/array。
    if (std.mem.eql(u8, method, "is_empty")) {
        if (args.len != 0) return error.WrongArity;
        return switch (receiver) {
            .string => |s| Value{ .boolean = s.len == 0 },
            .array => |arr| Value{ .boolean = arr.elements.len == 0 },
            else => error.TypeMismatch,
        };
    }
    // push(v)：array → 追加后的新数组（值语义；用法 arr = arr.push(x)）。
    if (std.mem.eql(u8, method, "push")) {
        if (args.len != 1) return error.WrongArity;
        return switch (receiver) {
            .array => |arr| {
                const new_elems = try allocator.alloc(Value, arr.elements.len + 1);
                for (arr.elements, 0..) |e, i| new_elems[i] = try retainOwned(allocator, e);
                new_elems[arr.elements.len] = try retainOwned(allocator, args[0]);
                return value.Value.makeArray(allocator, new_elems, null) catch error.OutOfMemory;
            },
            else => error.TypeMismatch,
        };
    }
    // pop()：array → 最后一个元素（T?），空数组 → null。
    if (std.mem.eql(u8, method, "pop")) {
        if (args.len != 0) return error.WrongArity;
        return switch (receiver) {
            .array => |arr| if (arr.elements.len == 0) Value.null_val else try retainOwned(allocator, arr.elements[arr.elements.len - 1]),
            else => error.TypeMismatch,
        };
    }
    // first()/last()：array → 首/末元素（T?），空 → null。
    if (std.mem.eql(u8, method, "first")) {
        if (args.len != 0) return error.WrongArity;
        return switch (receiver) {
            .array => |arr| if (arr.elements.len == 0) Value.null_val else try retainOwned(allocator, arr.elements[0]),
            else => error.TypeMismatch,
        };
    }
    if (std.mem.eql(u8, method, "last")) {
        if (args.len != 0) return error.WrongArity;
        return switch (receiver) {
            .array => |arr| if (arr.elements.len == 0) Value.null_val else try retainOwned(allocator, arr.elements[arr.elements.len - 1]),
            else => error.TypeMismatch,
        };
    }
    // contains(v)：array → 结构相等查找，压 bool。
    if (std.mem.eql(u8, method, "contains")) {
        if (args.len != 1) return error.WrongArity;
        return switch (receiver) {
            .array => |arr| {
                for (arr.elements) |item| {
                    if (structEq(item, args[0])) return Value{ .boolean = true };
                }
                return Value{ .boolean = false };
            },
            else => error.TypeMismatch,
        };
    }
    // drop_last()：array → 去掉末元素的新数组（空数组返回空数组拷贝）。
    if (std.mem.eql(u8, method, "drop_last")) {
        if (args.len != 0) return error.WrongArity;
        return switch (receiver) {
            .array => |arr| {
                const n = if (arr.elements.len == 0) 0 else arr.elements.len - 1;
                const new_elems = try allocator.alloc(Value, n);
                for (arr.elements[0..n], 0..) |e, i| new_elems[i] = try retainOwned(allocator, e);
                return value.Value.makeArray(allocator, new_elems, null) catch error.OutOfMemory;
            },
            else => error.TypeMismatch,
        };
    }
    // M4a：Atomic<T> 方法 —— cas(expected, new) → bool；swap(new) → 旧值。
    if (receiver == .atomic_val) {
        const av = receiver.atomic_val;
        if (std.mem.eql(u8, method, "cas")) {
            if (args.len != 2) return error.WrongArity;
            if (args[0] != .integer or args[1] != .integer) return error.TypeMismatch;
            const expected: i128 = @bitCast(args[0].integer.value);
            const new_val: i128 = @bitCast(args[1].integer.value);
            return Value{ .boolean = av.cas(expected, new_val) };
        }
        if (std.mem.eql(u8, method, "swap")) {
            if (args.len != 1) return error.WrongArity;
            if (args[0] != .integer) return error.TypeMismatch;
            const new_val: i128 = @bitCast(args[0].integer.value);
            const old_raw = av.xchg(new_val);
            return Value{ .integer = .{ .value = @bitCast(old_raw), .type_tag = value.atomicTypeToIntType(av.type_tag) } };
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
                owned.releaseVM(allocator);
                return error.ChannelClosed;
            }
            return Value.unit;
        }
        if (std.mem.eql(u8, method, "recv")) {
            if (args.len != 0) return error.WrongArity;
            return ch.recv() orelse Value.null_val;
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
                owned.releaseVM(allocator);
                return error.ChannelClosed;
            }
            return Value.unit;
        }
        if (std.mem.eql(u8, method, "close")) {
            if (args.len != 0) return error.WrongArity;
            sv.channel.close();
            return Value.unit;
        }
        return error.NoSuchMethod;
    }
    if (receiver == .receiver_val) {
        const rv = receiver.receiver_val;
        if (std.mem.eql(u8, method, "recv")) {
            if (args.len != 0) return error.WrongArity;
            return rv.channel.recv() orelse Value.null_val;
        }
        return error.NoSuchMethod;
    }
    return error.NoSuchMethod;
}

/// UTF-8 字符串的 Unicode 标量值（码点）个数；非法 UTF-8 退化为字节数。
fn utf8Len(s: []const u8) u128 {
    const view = std.unicode.Utf8View.init(s) catch return @intCast(s.len);
    var count: u128 = 0;
    var it = view.iterator();
    while (it.nextCodepoint() != null) count += 1;
    return count;
}
