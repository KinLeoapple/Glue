//! 16B Value 单元测试（内嵌在 value_new.zig 末尾）

const testing = std.testing;

// ============================================================
// 基本类型测试
// ============================================================

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

test "smart int encoding - small values inline" {
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
    defer v.release(allocator);

    const box = v.asBoxed();
    try testing.expectEqual(@as(u32, 1), box.rc);

    _ = v.retain();
    try testing.expectEqual(@as(u32, 2), box.rc);

    _ = v.retain();
    try testing.expectEqual(@as(u32, 3), box.rc);
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

test "array value" {
    const allocator = testing.allocator;

    var elements = try allocator.alloc(Value, 3);
    elements[0] = Value.fromSmallInt(1);
    elements[1] = Value.fromSmallInt(2);
    elements[2] = Value.fromSmallInt(3);

    const v = try Value.makeArray(allocator, elements, null);
    defer v.release(allocator);

    try testing.expect(v.isBoxed());
    try testing.expectEqual(ValueTag.array, v.tag);

    const arr = v.asBoxed().payload.array;
    try testing.expectEqual(@as(usize, 3), arr.elements.len);
    try testing.expectEqual(@as(i48, 1), arr.elements[0].asSmallInt());
}

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

test "inferIntType" {
    try testing.expectEqual(IntType.i8, inferIntType(42));
    try testing.expectEqual(IntType.u8, inferIntType(200));
    try testing.expectEqual(IntType.i32, inferIntType(40000));

    const neg: u128 = @bitCast(@as(i128, -100));
    try testing.expectEqual(IntType.i8, inferIntType(neg));
}

test "promoteIntTypes" {
    try testing.expectEqual(IntType.i32, promoteIntTypes(.i8, .i32));
    try testing.expectEqual(IntType.i32, promoteIntTypes(.i32, .i8));
    try testing.expectEqual(IntType.i16, promoteIntTypes(.i8, .u8));
}

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
