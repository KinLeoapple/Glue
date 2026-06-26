//! 16B Value 单元测试
//!
//! 验证所有编码/解码路径的正确性

const std = @import("std");
const testing = std.testing;
const value = @import("../src/value_new.zig");

const Value = value.Value;
const IntValue = value.IntValue;
const IntType = value.IntType;

// ============================================================
// 基本类型测试
// ============================================================

test "Value size is 16 bytes" {
    try testing.expectEqual(16, @sizeOf(Value));
}

test "null value" {
    const v = Value.fromNull();
    try testing.expect(v.isNull());
    try testing.expectEqual(value.ValueTag.null_val, v.tag);
}

test "unit value" {
    const v = Value.fromUnit();
    try testing.expect(v.isUnit());
    try testing.expectEqual(value.ValueTag.unit, v.tag);
}

test "boolean values" {
    const t = Value.fromBool(true);
    const f = Value.fromBool(false);

    try testing.expect(t.asBool());
    try testing.expect(!f.asBool());
    try testing.expectEqual(value.ValueTag.boolean, t.tag);
}

test "char value" {
    const v = Value.fromChar('A');
    try testing.expectEqual(@as(u21, 'A'), v.asChar());
    try testing.expectEqual(value.ValueTag.char_val, v.tag);
}

test "float value" {
    const v = Value.fromFloat(3.14159);
    try testing.expectApproxEqRel(3.14159, v.asFloat(), 0.00001);
    try testing.expectEqual(value.ValueTag.float_val, v.tag);
}

// ============================================================
// 小整数测试（内联）
// ============================================================

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

test "small int - boundary" {
    const max_i48 = std.math.maxInt(i48);
    const min_i48 = std.math.minInt(i48);

    const v_max = Value.fromSmallInt(max_i48);
    const v_min = Value.fromSmallInt(min_i48);

    try testing.expectEqual(max_i48, v_max.asSmallInt());
    try testing.expectEqual(min_i48, v_min.asSmallInt());
}

// ============================================================
// 大整数测试（装箱）
// ============================================================

test "big int - i64 out of i48 range" {
    const allocator = testing.allocator;

    const big_val = IntValue{ .value = @bitCast(@as(i128, 1 << 50)), .type_tag = .i64 };
    const v = try Value.fromBigInt(allocator, big_val);
    defer v.release(allocator);

    try testing.expect(v.isBoxed());
    try testing.expectEqual(value.ValueTag.big_int, v.tag);

    const retrieved = v.asInt();
    try testing.expectEqual(big_val.value, retrieved.value);
    try testing.expectEqual(big_val.type_tag, retrieved.type_tag);
}

test "smart int encoding - small values inline" {
    const allocator = testing.allocator;

    const small = IntValue{ .value = 100, .type_tag = .i32 };
    const v = try Value.fromInt(allocator, small);

    try testing.expect(v.isInline());
    try testing.expectEqual(value.ValueTag.small_int, v.tag);
}

test "smart int encoding - big values boxed" {
    const allocator = testing.allocator;

    const big = IntValue{ .value = @bitCast(@as(i128, 1 << 60)), .type_tag = .i64 };
    const v = try Value.fromInt(allocator, big);
    defer v.release(allocator);

    try testing.expect(v.isBoxed());
    try testing.expectEqual(value.ValueTag.big_int, v.tag);
}

// ============================================================
// 字符串测试
// ============================================================

test "string value" {
    const allocator = testing.allocator;

    const s = try allocator.dupe(u8, "hello");
    const v = try Value.fromString(allocator, s);
    defer v.release(allocator);

    try testing.expect(v.isBoxed());
    try testing.expectEqual(value.ValueTag.string, v.tag);

    const retrieved = v.asBoxed().payload.string;
    try testing.expectEqualStrings("hello", retrieved);
}

// ============================================================
// 引用计数测试
// ============================================================

test "refcount - retain increments" {
    const allocator = testing.allocator;

    const s = try allocator.dupe(u8, "test");
    const v = try Value.fromString(allocator, s);
    defer v.release(allocator);

    const box = v.asBoxed();
    try testing.expectEqual(@as(u32, 1), box.rc);

    _ = v.retain();
    try testing.expectEqual(@as(u32, 2), box.rc);

    _ = v.retain();
    try testing.expectEqual(@as(u32, 3), box.rc);
}

test "refcount - release decrements" {
    const allocator = testing.allocator;

    const s = try allocator.dupe(u8, "test");
    const v = try Value.fromString(allocator, s);

    _ = v.retain(); // rc = 2
    _ = v.retain(); // rc = 3

    const box = v.asBoxed();
    try testing.expectEqual(@as(u32, 3), box.rc);

    v.release(allocator); // rc = 2
    try testing.expectEqual(@as(u32, 2), box.rc);

    v.release(allocator); // rc = 1
    try testing.expectEqual(@as(u32, 1), box.rc);

    v.release(allocator); // rc = 0, freed
}

test "refcount - inline values no-op" {
    const allocator = testing.allocator;

    const v = Value.fromSmallInt(42);

    // retain/release 应该是 no-op
    _ = v.retain();
    _ = v.retain();
    v.release(allocator);
    v.release(allocator);

    // 仍然可用
    try testing.expectEqual(@as(i48, 42), v.asSmallInt());
}

// ============================================================
// 数组测试
// ============================================================

test "array value" {
    const allocator = testing.allocator;

    var elements = try allocator.alloc(Value, 3);
    elements[0] = Value.fromSmallInt(1);
    elements[1] = Value.fromSmallInt(2);
    elements[2] = Value.fromSmallInt(3);

    const v = try Value.makeArray(allocator, elements, null);
    defer v.release(allocator);

    try testing.expect(v.isBoxed());
    try testing.expectEqual(value.ValueTag.array, v.tag);

    const arr = v.asBoxed().payload.array;
    try testing.expectEqual(@as(usize, 3), arr.elements.len);
    try testing.expectEqual(@as(i48, 1), arr.elements[0].asSmallInt());
}

// ============================================================
// 类型检查测试
// ============================================================

test "inline vs boxed classification" {
    const allocator = testing.allocator;

    const inline_vals = [_]Value{
        Value.fromNull(),
        Value.fromUnit(),
        Value.fromBool(true),
        Value.fromSmallInt(42),
        Value.fromChar('A'),
        Value.fromFloat(3.14),
    };

    for (inline_vals) |v| {
        try testing.expect(v.isInline());
        try testing.expect(!v.isBoxed());
    }

    const s = try allocator.dupe(u8, "test");
    const boxed_val = try Value.fromString(allocator, s);
    defer boxed_val.release(allocator);

    try testing.expect(!boxed_val.isInline());
    try testing.expect(boxed_val.isBoxed());
}

test "integer type check" {
    const allocator = testing.allocator;

    const small = Value.fromSmallInt(42);
    try testing.expect(small.isInteger());

    const big = IntValue{ .value = @bitCast(@as(i128, 1 << 50)), .type_tag = .i64 };
    const big_v = try Value.fromBigInt(allocator, big);
    defer big_v.release(allocator);
    try testing.expect(big_v.isInteger());

    const not_int = Value.fromFloat(3.14);
    try testing.expect(!not_int.isInteger());
}

// ============================================================
// 相等性测试
// ============================================================

test "value equality" {
    const v1 = Value.fromSmallInt(42);
    const v2 = Value.fromSmallInt(42);
    const v3 = Value.fromSmallInt(43);

    try testing.expect(v1.equals(v2));
    try testing.expect(!v1.equals(v3));

    const n1 = Value.fromNull();
    const n2 = Value.fromNull();
    try testing.expect(n1.equals(n2));

    const b1 = Value.fromBool(true);
    const b2 = Value.fromBool(true);
    const b3 = Value.fromBool(false);
    try testing.expect(b1.equals(b2));
    try testing.expect(!b1.equals(b3));
}

// ============================================================
// IntType 工具函数测试（确保向后兼容）
// ============================================================

test "inferIntType" {
    try testing.expectEqual(IntType.i8, value.inferIntType(42));
    try testing.expectEqual(IntType.u8, value.inferIntType(200));
    try testing.expectEqual(IntType.i32, value.inferIntType(40000));

    const neg: u128 = @bitCast(@as(i128, -100));
    try testing.expectEqual(IntType.i8, value.inferIntType(neg));
}

test "promoteIntTypes" {
    try testing.expectEqual(IntType.i32, value.promoteIntTypes(.i8, .i32));
    try testing.expectEqual(IntType.i32, value.promoteIntTypes(.i32, .i8));
    try testing.expectEqual(IntType.i16, value.promoteIntTypes(.i8, .u8));
}

// ============================================================
// 记录测试
// ============================================================

test "record value" {
    const allocator = testing.allocator;

    var fields = std.StringHashMap(Value).init(allocator);
    defer fields.deinit();

    const name_key = try allocator.dupe(u8, "name");
    const age_key = try allocator.dupe(u8, "age");

    try fields.put(name_key, try Value.fromString(allocator, try allocator.dupe(u8, "Alice")));
    try fields.put(age_key, Value.fromSmallInt(30));

    const v = try Value.makeRecord(allocator, "Person", fields);
    defer v.release(allocator);

    try testing.expect(v.isBoxed());
    try testing.expectEqual(value.ValueTag.record, v.tag);
}

// ============================================================
// retainOwned 测试（重要：string 需要 dupe）
// ============================================================

test "retainOwned - string duplicates" {
    const allocator = testing.allocator;

    const s1 = try allocator.dupe(u8, "hello");
    const v1 = try Value.fromString(allocator, s1);
    defer v1.release(allocator);

    const v2 = try v1.retainOwned(allocator);
    defer v2.release(allocator);

    // 不同的指针（独立所有权）
    const ptr1 = v1.asBoxed().payload.string.ptr;
    const ptr2 = v2.asBoxed().payload.string.ptr;
    try testing.expect(ptr1 != ptr2);

    // 但内容相同
    try testing.expectEqualStrings(v1.asBoxed().payload.string, v2.asBoxed().payload.string);
}

test "retainOwned - non-string just retains" {
    const allocator = testing.allocator;

    const arr = try Value.makeArray(allocator, &.{}, null);
    defer arr.release(allocator);

    const arr2 = try arr.retainOwned(allocator);

    // 相同指针（共享 rc）
    try testing.expectEqual(arr.payload, arr2.payload);

    const box = arr.asBoxed();
    try testing.expectEqual(@as(u32, 2), box.rc);

    arr2.release(allocator);
}
