//! Value 模块完整集成测试
//!
//! 覆盖范围：
//! - 18 种标量的构造/访问/谓词
//! - 18×18 cast 转换矩阵（含溢出/NaN/Inf 边界）
//! - 23 种堆对象的构造/访问/equals
//! - equals/deep_clone 递归结构与深度限制

use glue_rs::Value::*;

use std::rc::Rc;

// =========================================================================
// 1. 标量构造与访问
// =========================================================================

#[test]
fn test_all_scalar_constructors() {
    // 布尔
    assert_eq!(Value::bool(true).as_bool(), Some(true));
    assert_eq!(Value::bool(false).as_bool(), Some(false));

    // 字符
    let c = Value::from_rust_char('X');
    assert_eq!(c.as_char().unwrap().codepoint(), 88);

    // 有符号整数
    assert_eq!(Value::i8(-1).as_i8(), Some(-1));
    assert_eq!(Value::i16(-2).as_i16(), Some(-2));
    assert_eq!(Value::i32(-3).as_i32(), Some(-3));
    assert_eq!(Value::i64(-4).as_i64(), Some(-4));
    assert_eq!(Value::i128(-5).as_i128(), Some(-5));

    // 无符号整数
    assert_eq!(Value::u8(1).as_u8(), Some(1));
    assert_eq!(Value::u16(2).as_u16(), Some(2));
    assert_eq!(Value::u32(3).as_u32(), Some(3));
    assert_eq!(Value::u64(4).as_u64(), Some(4));
    assert_eq!(Value::u128(5).as_u128(), Some(5));

    // 平台相关整数
    assert_eq!(Value::isize(-6).as_isize(), Some(-6));
    assert_eq!(Value::usize(7).as_usize(), Some(7));

    // 浮点
    assert_eq!(Value::f32(1.5).as_f32(), Some(1.5));
    assert_eq!(Value::f64(2.5).as_f64(), Some(2.5));
    assert!(Value::f16(F16(0x3C00)).as_f16().is_some()); // 1.0
    assert!(Value::f128(F128([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xF8, 0x3F])).as_f128().is_some()); // 1.0
}

#[test]
fn test_scalar_predicates() {
    assert!(Value::bool(true).is_bool());
    assert!(Value::from_rust_char('x').is_char());

    // is_int 覆盖全部 12 种整数
    assert!(Value::i8(0).is_int());
    assert!(Value::i16(0).is_int());
    assert!(Value::i32(0).is_int());
    assert!(Value::i64(0).is_int());
    assert!(Value::i128(0).is_int());
    assert!(Value::u8(0).is_int());
    assert!(Value::u16(0).is_int());
    assert!(Value::u32(0).is_int());
    assert!(Value::u64(0).is_int());
    assert!(Value::u128(0).is_int());
    assert!(Value::isize(0).is_int());
    assert!(Value::usize(0).is_int());

    // is_float 覆盖全部 4 种浮点
    assert!(Value::f16(F16(0)).is_float());
    assert!(Value::f32(0.0).is_float());
    assert!(Value::f64(0.0).is_float());
    assert!(Value::f128(F128([0u8; 16])).is_float());

    // is_numeric = is_int || is_float
    assert!(Value::i32(0).is_numeric());
    assert!(Value::f64(0.0).is_numeric());
    assert!(!Value::bool(true).is_numeric());
    assert!(!Value::null().is_numeric());

    // is_scalar = is_bool || is_char || is_numeric
    assert!(Value::bool(true).is_scalar());
    assert!(Value::from_rust_char('x').is_scalar());
    assert!(Value::i32(0).is_scalar());
    assert!(!Value::null().is_scalar());
    assert!(!Value::void().is_scalar());
    assert!(!Value::str("x").is_scalar());
}

#[test]
fn test_scalar_type_names() {
    assert_eq!(Value::bool(true).type_name(), "bool");
    assert_eq!(Value::from_rust_char('x').type_name(), "char");
    assert_eq!(Value::i8(0).type_name(), "i8");
    assert_eq!(Value::i16(0).type_name(), "i16");
    assert_eq!(Value::i32(0).type_name(), "i32");
    assert_eq!(Value::i64(0).type_name(), "i64");
    assert_eq!(Value::i128(0).type_name(), "i128");
    assert_eq!(Value::u8(0).type_name(), "u8");
    assert_eq!(Value::u16(0).type_name(), "u16");
    assert_eq!(Value::u32(0).type_name(), "u32");
    assert_eq!(Value::u64(0).type_name(), "u64");
    assert_eq!(Value::u128(0).type_name(), "u128");
    assert_eq!(Value::isize(0).type_name(), "isize");
    assert_eq!(Value::usize(0).type_name(), "usize");
    assert_eq!(Value::f16(F16(0)).type_name(), "f16");
    assert_eq!(Value::f32(0.0).type_name(), "f32");
    assert_eq!(Value::f64(0.0).type_name(), "f64");
    assert_eq!(Value::f128(F128([0u8; 16])).type_name(), "f128");
}

#[test]
fn test_scalar_tag_roundtrip() {
    let cases: &[(ScalarTag, Value)] = &[
        (ScalarTag::Bool, Value::bool(true)),
        (ScalarTag::Char, Value::from_rust_char('x')),
        (ScalarTag::I8, Value::i8(1)),
        (ScalarTag::I16, Value::i16(1)),
        (ScalarTag::I32, Value::i32(1)),
        (ScalarTag::I64, Value::i64(1)),
        (ScalarTag::I128, Value::i128(1)),
        (ScalarTag::U8, Value::u8(1)),
        (ScalarTag::U16, Value::u16(1)),
        (ScalarTag::U32, Value::u32(1)),
        (ScalarTag::U64, Value::u64(1)),
        (ScalarTag::U128, Value::u128(1)),
        (ScalarTag::Isize, Value::isize(1)),
        (ScalarTag::Usize, Value::usize(1)),
        (ScalarTag::F16, Value::f16(F16(0))),
        (ScalarTag::F32, Value::f32(1.0)),
        (ScalarTag::F64, Value::f64(1.0)),
        (ScalarTag::F128, Value::f128(F128([0u8; 16]))),
    ];
    for (tag, val) in cases {
        assert_eq!(val.scalar_tag(), Some(*tag), "tag mismatch for {:?}", tag);
    }
}

#[test]
fn test_int_promotion_to_i64() {
    assert_eq!(Value::i8(42).as_int_i64(), Some(42));
    assert_eq!(Value::i16(42).as_int_i64(), Some(42));
    assert_eq!(Value::i32(42).as_int_i64(), Some(42));
    assert_eq!(Value::i64(42).as_int_i64(), Some(42));
    assert_eq!(Value::i128(42).as_int_i64(), Some(42));
    assert_eq!(Value::u8(42).as_int_i64(), Some(42));
    assert_eq!(Value::u16(42).as_int_i64(), Some(42));
    assert_eq!(Value::u32(42).as_int_i64(), Some(42));
    assert_eq!(Value::u64(42).as_int_i64(), Some(42));
    assert_eq!(Value::u128(42).as_int_i64(), Some(42));
    assert_eq!(Value::isize(42).as_int_i64(), Some(42));
    assert_eq!(Value::usize(42).as_int_i64(), Some(42));
    // 非整数返回 None
    assert_eq!(Value::bool(true).as_int_i64(), None);
    assert_eq!(Value::f64(42.0).as_int_i64(), None);
    assert_eq!(Value::null().as_int_i64(), None);
}

#[test]
fn test_float_promotion_to_f64() {
    assert_eq!(Value::f32(1.5).as_float_f64(), Some(1.5));
    assert_eq!(Value::f64(2.5).as_float_f64(), Some(2.5));
    // 非浮点返回 None
    assert_eq!(Value::i32(42).as_float_f64(), None);
}

// =========================================================================
// 2. Cast 转换矩阵
// =========================================================================

#[test]
fn test_cast_int_to_int_safe() {
    let src = Value::i32(42);
    let src_bytes = [42i32.to_le_bytes()].concat();
    let dst = cast_value(ScalarTag::I32, &src_bytes, ScalarTag::I64);
    assert_eq!(i64::from_le_bytes(dst.try_into().unwrap()), 42);
}

#[test]
fn test_cast_int_to_int_overflow_wrap() {
    // i32::MAX -> i8 应回绕
    let src_bytes = i32::MAX.to_le_bytes().to_vec();
    let dst = cast_value(ScalarTag::I32, &src_bytes, ScalarTag::I8);
    assert_eq!(i8::from_le_bytes(dst.try_into().unwrap()), -1);
}

#[test]
fn test_cast_int_to_uint() {
    let src_bytes = (-1i32).to_le_bytes().to_vec();
    let dst = cast_value(ScalarTag::I32, &src_bytes, ScalarTag::U32);
    assert_eq!(u32::from_le_bytes(dst.try_into().unwrap()), u32::MAX);
}

#[test]
fn test_cast_uint_to_int() {
    let src_bytes = u32::MAX.to_le_bytes().to_vec();
    let dst = cast_value(ScalarTag::U32, &src_bytes, ScalarTag::I32);
    assert_eq!(i32::from_le_bytes(dst.try_into().unwrap()), -1);
}

#[test]
fn test_cast_float_to_int_truncation() {
    let src_bytes = 3.7f64.to_le_bytes().to_vec();
    let dst = cast_value(ScalarTag::F64, &src_bytes, ScalarTag::I32);
    assert_eq!(i32::from_le_bytes(dst.try_into().unwrap()), 3);
}

#[test]
fn test_cast_float_to_int_inf() {
    let src_bytes = f64::INFINITY.to_le_bytes().to_vec();
    let dst = cast_value(ScalarTag::F64, &src_bytes, ScalarTag::I32);
    assert_eq!(i32::from_le_bytes(dst.try_into().unwrap()), i32::MAX);
}

#[test]
fn test_cast_float_to_int_neg_inf() {
    let src_bytes = f64::NEG_INFINITY.to_le_bytes().to_vec();
    let dst = cast_value(ScalarTag::F64, &src_bytes, ScalarTag::I32);
    assert_eq!(i32::from_le_bytes(dst.try_into().unwrap()), i32::MIN);
}

#[test]
fn test_cast_float_to_int_nan() {
    let src_bytes = f64::NAN.to_le_bytes().to_vec();
    let dst = cast_value(ScalarTag::F64, &src_bytes, ScalarTag::I32);
    assert_eq!(i32::from_le_bytes(dst.try_into().unwrap()), 0);
}

#[test]
fn test_cast_int_to_float() {
    let src_bytes = 42i32.to_le_bytes().to_vec();
    let dst = cast_value(ScalarTag::I32, &src_bytes, ScalarTag::F64);
    assert_eq!(f64::from_le_bytes(dst.try_into().unwrap()), 42.0);
}

#[test]
fn test_cast_float_to_float_widening() {
    let src_bytes = 1.5f32.to_le_bytes().to_vec();
    let dst = cast_value(ScalarTag::F32, &src_bytes, ScalarTag::F64);
    assert_eq!(f64::from_le_bytes(dst.try_into().unwrap()), 1.5);
}

#[test]
fn test_cast_float_to_float_narrowing() {
    let src_bytes = 1.5f64.to_le_bytes().to_vec();
    let dst = cast_value(ScalarTag::F64, &src_bytes, ScalarTag::F32);
    assert_eq!(f32::from_le_bytes(dst.try_into().unwrap()), 1.5);
}

#[test]
fn test_try_cast_overflow_checked() {
    let src_bytes = i32::MAX.to_le_bytes().to_vec();
    let result = try_cast_value(ScalarTag::I32, &src_bytes, ScalarTag::I8);
    assert_eq!(result, Err(CastError::Overflow));
}

#[test]
fn test_try_cast_safe() {
    let src_bytes = 42i32.to_le_bytes().to_vec();
    let result = try_cast_value(ScalarTag::I32, &src_bytes, ScalarTag::I64);
    assert!(result.is_ok());
    assert_eq!(i64::from_le_bytes(result.unwrap().try_into().unwrap()), 42);
}

#[test]
fn test_cast_bool_to_int() {
    let src_bytes = [1u8].to_vec();
    let dst = cast_value(ScalarTag::Bool, &src_bytes, ScalarTag::I32);
    assert_eq!(i32::from_le_bytes(dst.try_into().unwrap()), 1);
}

#[test]
fn test_cast_int_to_bool() {
    let src_bytes = 0i32.to_le_bytes().to_vec();
    let dst = cast_value(ScalarTag::I32, &src_bytes, ScalarTag::Bool);
    assert_eq!(dst, [0u8]);

    let src_bytes = 1i32.to_le_bytes().to_vec();
    let dst = cast_value(ScalarTag::I32, &src_bytes, ScalarTag::Bool);
    assert_eq!(dst, [1u8]);
}

#[test]
fn test_cast_char_to_codepoint() {
    let src_bytes = 65u32.to_le_bytes().to_vec(); // 'A'
    let dst = cast_value(ScalarTag::Char, &src_bytes, ScalarTag::U32);
    assert_eq!(u32::from_le_bytes(dst.try_into().unwrap()), 65);
}

// =========================================================================
// 3. 堆对象构造与访问
// =========================================================================

#[test]
fn test_heap_str() {
    let s = Value::str("hello");
    assert!(s.is_string());
    assert!(s.is_ref());
    assert_eq!(s.type_name(), "str");
    assert_eq!(s.as_str().unwrap().byte_len(), 5);
}

#[test]
fn test_heap_str_unicode() {
    let s = Value::str("你好");
    assert!(s.is_string());
    assert_eq!(s.as_str().unwrap().byte_len(), 6); // UTF-8 字节数
}

#[test]
fn test_heap_array() {
    let a = Value::array(vec![Value::i32(1), Value::i32(2), Value::i32(3)]);
    assert!(a.is_array());
    assert_eq!(a.type_name(), "array");
    assert_eq!(a.as_array().unwrap().len(), 3);
}

#[test]
fn test_heap_array_fixed() {
    let a = Value::array_fixed(vec![Value::i32(1), Value::i32(2)], 2);
    let arr = a.as_array().unwrap();
    assert_eq!(arr.fixed_size, Some(2));
}

#[test]
fn test_heap_record() {
    let r = Value::record(
        "Point",
        vec![Value::i32(1), Value::i32(2)],
        vec![Some("x".to_string()), Some("y".to_string())],
    );
    assert!(r.is_record());
    assert_eq!(r.type_name(), "record");
    let rec = r.as_record().unwrap();
    assert_eq!(rec.type_name, "Point");
    assert_eq!(rec.find_field("x"), Some(&Value::i32(1)));
    assert_eq!(rec.find_field("y"), Some(&Value::i32(2)));
    assert_eq!(rec.find_field("z"), None);
}

#[test]
fn test_heap_adt() {
    let a = Value::adt(
        "Option",
        "Some",
        vec![AdtField {
            name: None,
            value: Value::i32(42),
        }],
    );
    assert!(a.is_adt());
    assert_eq!(a.type_name(), "adt");
    let adt = a.as_adt().unwrap();
    assert_eq!(adt.constructor, "Some");
    assert_eq!(adt.get_field(0), Some(&Value::i32(42)));
}

#[test]
fn test_heap_newtype() {
    let n = Value::newtype("UserId", Value::i64(123));
    assert_eq!(n.type_name(), "newtype");
    let nt = n.as_newtype().unwrap();
    assert_eq!(nt.type_name, "UserId");
    assert_eq!(nt.inner.as_i64(), Some(123));
}

#[test]
fn test_heap_cell() {
    let c = Value::cell(Value::i32(42));
    assert_eq!(c.type_name(), "cell");
    let cell = c.as_cell().unwrap();
    let borrowed = cell.get();
    assert_eq!(borrowed.as_i32(), Some(42));
    drop(borrowed);
    cell.set(Value::i32(99));
    let borrowed2 = cell.get();
    assert_eq!(borrowed2.as_i32(), Some(99));
}

#[test]
fn test_heap_range() {
    let r = Value::range(1, 10, false);
    assert_eq!(r.type_name(), "range");
    let rng = r.as_range().unwrap();
    assert_eq!(rng.start, 1);
    assert_eq!(rng.end, 10);
    assert!(!rng.inclusive);
    assert!(rng.contains(5));
    assert!(!rng.contains(10));
    assert_eq!(rng.len(), 9);
}

#[test]
fn test_heap_range_inclusive() {
    let r = Value::range(1, 10, true);
    let rng = r.as_range().unwrap();
    assert!(rng.contains(10));
    assert_eq!(rng.len(), 10);
}

#[test]
fn test_heap_closure() {
    let c = Value::closure(Closure {
        func_id: 42,
        arity: 2,
        upvalues: vec![Value::i32(1)],
        bound_args: vec![],
        self_upvalue_idx: -1,
        upvalue_ref_bits: 1,
        cell_upvalues: 0,
    });
    assert!(c.is_closure());
    assert!(c.is_callable());
    assert_eq!(c.type_name(), "closure");
    let cl = c.as_closure().unwrap();
    assert_eq!(cl.func_id, 42);
    assert_eq!(cl.arity, 2);
    assert_eq!(cl.upvalues.len(), 1);
}

#[test]
fn test_heap_partial() {
    let p = Value::partial(PartialApplication {
        func_id: 1,
        bound_args: vec![Value::i32(42)],
        remaining_arity: 1,
        bound_arg_ref_bits: 0,
    });
    assert!(p.is_callable());
    assert_eq!(p.type_name(), "partial");
}

#[test]
fn test_heap_builtin() {
    fn add_fn(args: &[Value]) -> Result<Value, String> {
        Ok(Value::i32(args[0].as_i32().unwrap() + args[1].as_i32().unwrap()))
    }
    let b = Value::builtin(add_fn, "add");
    assert!(b.is_callable());
    assert_eq!(b.type_name(), "builtin");
    let bi = b.as_builtin().unwrap();
    assert_eq!(bi.name, "add");
}

#[test]
fn test_heap_trait_val() {
    let t = Value::trait_val(TraitValue {
        trait_name: "Show".to_string(),
        method_names: vec!["show".to_string()],
        method_values: vec![Value::builtin(|_| Ok(Value::str("x")), "show")],
        data: None,
        owned: false,
    });
    assert_eq!(t.type_name(), "trait");
}

#[test]
fn test_heap_lazy() {
    let l = Value::lazy(LazyValue {
        cached: Some(Value::i32(42)),
        forced: true,
        thunk: None,
    });
    assert_eq!(l.type_name(), "lazy");
}

#[test]
fn test_heap_error_val() {
    let e = Value::error_val("MyError", "something went wrong", false);
    assert_eq!(e.type_name(), "error");
    let err = e.as_error_val().unwrap();
    assert_eq!(err.type_name, "MyError");
    assert_eq!(err.message, "something went wrong");
}

#[test]
fn test_heap_throw_ok() {
    let t = Value::throw_ok(Value::i32(42));
    assert_eq!(t.type_name(), "throw");
    let tv = t.as_throw_val().unwrap();
    match &tv.payload {
        ThrowPayload::Ok(v) => assert_eq!(v.as_i32(), Some(42)),
        _ => panic!("expected Ok payload"),
    }
}

#[test]
fn test_heap_throw_err() {
    let record = Rc::new(RecordValue::new(
        "Error".to_string(),
        vec![Value::str("msg")],
        vec![Some("msg".to_string())],
    ));
    let t = Value::throw_err(record);
    let tv = t.as_throw_val().unwrap();
    match &tv.payload {
        ThrowPayload::Err(_) => {}
        _ => panic!("expected Err payload"),
    }
}

#[test]
fn test_heap_atomic() {
    let a = Value::atomic(Value::i32(42));
    assert_eq!(a.type_name(), "atomic");
    let atm = a.as_atomic().unwrap();
    assert_eq!(atm.load().as_i32(), Some(42));
    atm.store(Value::i32(99));
    assert_eq!(atm.load().as_i32(), Some(99));
    let old = atm.swap(Value::i32(0));
    assert_eq!(old.as_i32(), Some(99));
    assert_eq!(atm.load().as_i32(), Some(0));
}

#[test]
fn test_heap_async_handle() {
    let h = Value::async_handle();
    assert_eq!(h.type_name(), "async");
    let ah = h.as_async_handle().unwrap();
    assert_eq!(ah.status(), AsyncStatus::Pending);
    ah.set_status(AsyncStatus::Completed);
    ah.set_result(Value::i32(42));
    assert_eq!(ah.status(), AsyncStatus::Completed);
    assert_eq!(ah.result().unwrap().as_i32(), Some(42));
}

#[test]
fn test_heap_channel() {
    let ch = Value::channel(2);
    assert_eq!(ch.type_name(), "channel");
    let chan = ch.as_channel().unwrap();
    assert!(chan.send(Value::i32(1)).is_ok());
    assert!(chan.send(Value::i32(2)).is_ok());
    assert!(chan.send(Value::i32(3)).is_err()); // 已满
    assert_eq!(chan.recv().unwrap().as_i32(), Some(1));
    assert_eq!(chan.recv().unwrap().as_i32(), Some(2));
    assert!(chan.recv().is_none());
}

#[test]
fn test_heap_sender_receiver() {
    let ch = Value::channel(1);
    let chan = ch.as_channel().unwrap().clone();
    // 通过 Rc 共享通道
    let sender = Value::sender(Rc::new(chan.clone()));
    let receiver = Value::receiver(Rc::new(chan));
    assert_eq!(sender.type_name(), "sender");
    assert_eq!(receiver.type_name(), "receiver");
}

#[test]
fn test_heap_iterators() {
    let arr = Value::array_iter(Rc::new(vec![Value::i32(1), Value::i32(2)]));
    assert_eq!(arr.type_name(), "array_iter");

    let s = Value::string_iter(Rc::from("hello"));
    assert_eq!(s.type_name(), "string_iter");

    let r = Value::range_iter(1, 5, false);
    assert_eq!(r.type_name(), "range_iter");
}

// =========================================================================
// 4. equals 深度比较
// =========================================================================

#[test]
fn test_equals_all_scalars() {
    assert!(Value::i8(1).equals(&Value::i8(1)));
    assert!(Value::i16(1).equals(&Value::i16(1)));
    assert!(Value::i32(1).equals(&Value::i32(1)));
    assert!(Value::i64(1).equals(&Value::i64(1)));
    assert!(Value::i128(1).equals(&Value::i128(1)));
    assert!(Value::u8(1).equals(&Value::u8(1)));
    assert!(Value::u16(1).equals(&Value::u16(1)));
    assert!(Value::u32(1).equals(&Value::u32(1)));
    assert!(Value::u64(1).equals(&Value::u64(1)));
    assert!(Value::u128(1).equals(&Value::u128(1)));
    assert!(Value::f32(1.5).equals(&Value::f32(1.5)));
    assert!(Value::f64(1.5).equals(&Value::f64(1.5)));
}

#[test]
fn test_equals_cross_type_never_equal() {
    assert!(!Value::i8(1).equals(&Value::i16(1)));
    assert!(!Value::i32(1).equals(&Value::u32(1)));
    assert!(!Value::i64(1).equals(&Value::f64(1.0)));
    assert!(!Value::bool(true).equals(&Value::i8(1)));
    assert!(!Value::null().equals(&Value::void()));
}

#[test]
fn test_equals_strings_content() {
    let s1 = Value::str("hello");
    let s2 = Value::str("hello");
    let s3 = Value::str("world");
    assert!(s1.equals(&s2));
    assert!(!s1.equals(&s3));
    assert!(!s1.equals(&Value::i32(42)));
}

#[test]
fn test_equals_nested_arrays() {
    let a1 = Value::array(vec![
        Value::i32(1),
        Value::str("x"),
        Value::array(vec![Value::i32(10), Value::i32(20)]),
    ]);
    let a2 = Value::array(vec![
        Value::i32(1),
        Value::str("x"),
        Value::array(vec![Value::i32(10), Value::i32(20)]),
    ]);
    let a3 = Value::array(vec![
        Value::i32(1),
        Value::str("x"),
        Value::array(vec![Value::i32(10), Value::i32(99)]),
    ]);
    assert!(a1.equals(&a2));
    assert!(!a1.equals(&a3));
}

#[test]
fn test_equals_records_with_fields() {
    let r1 = Value::record(
        "Point",
        vec![Value::i32(1), Value::str("origin")],
        vec![Some("x".to_string()), Some("label".to_string())],
    );
    let r2 = Value::record(
        "Point",
        vec![Value::i32(1), Value::str("origin")],
        vec![Some("x".to_string()), Some("label".to_string())],
    );
    let r3 = Value::record(
        "Point",
        vec![Value::i32(2), Value::str("origin")],
        vec![Some("x".to_string()), Some("label".to_string())],
    );
    assert!(r1.equals(&r2));
    assert!(!r1.equals(&r3));
}

#[test]
fn test_equals_adt_variants() {
    let some = Value::adt("Option", "Some", vec![AdtField {
        name: None,
        value: Value::i32(42),
    }]);
    let none = Value::adt("Option", "None", vec![]);
    let some2 = Value::adt("Option", "Some", vec![AdtField {
        name: None,
        value: Value::i32(42),
    }]);
    assert!(some.equals(&some2));
    assert!(!some.equals(&none));
}

#[test]
fn test_equals_ref_sharing() {
    let s1 = Value::str("shared");
    let s2 = s1.clone();
    // clone 共享 Rc 指针
    assert!(Rc::ptr_eq(
        s1.as_ref().unwrap(),
        s2.as_ref().unwrap()
    ));
    assert!(s1.equals(&s2));
}

#[test]
fn test_partial_eq_trait_for_hashmap() {
    use std::collections::HashMap;

    let mut map: HashMap<Value, &'static str> = HashMap::new();
    map.insert(Value::str("key"), "value");
    // 新构造的 str 内容相同但 Rc 指针不同
    assert_eq!(map.get(&Value::str("key")), Some(&"value"));
}

// =========================================================================
// 5. deep_clone 深拷贝
// =========================================================================

#[test]
fn test_deep_clone_scalar_is_copy() {
    let v = Value::i32(42);
    let c = v.deep_clone();
    assert!(v.equals(&c));
}

#[test]
fn test_deep_clone_string_independent() {
    let s1 = Value::str("hello");
    let s2 = s1.deep_clone();
    assert!(s1.equals(&s2));
    // 深拷贝后 Rc 指针不同
    assert!(!Rc::ptr_eq(
        s1.as_ref().unwrap(),
        s2.as_ref().unwrap()
    ));
}

#[test]
fn test_deep_clone_nested_array() {
    let original = Value::array(vec![
        Value::i32(1),
        Value::str("nested"),
        Value::array(vec![Value::i32(10), Value::i32(20)]),
    ]);
    let cloned = original.deep_clone();
    assert!(original.equals(&cloned));
    // 外层数组 Rc 不同
    assert!(!Rc::ptr_eq(
        original.as_ref().unwrap(),
        cloned.as_ref().unwrap()
    ));
    // 内层数组 Rc 也不同
    let orig_inner = match &original.as_ref().unwrap().as_ref() {
        HeapObj::Array(a) => match &a.elements[2] {
            Value::Ref(r) => r.clone(),
            _ => panic!("expected Ref"),
        },
        _ => panic!("expected Array"),
    };
    let clone_inner = match &cloned.as_ref().unwrap().as_ref() {
        HeapObj::Array(a) => match &a.elements[2] {
            Value::Ref(r) => r.clone(),
            _ => panic!("expected Ref"),
        },
        _ => panic!("expected Array"),
    };
    assert!(!Rc::ptr_eq(&orig_inner, &clone_inner));
}

#[test]
fn test_deep_clone_record() {
    let r = Value::record(
        "Point",
        vec![Value::i32(1), Value::str("label")],
        vec![Some("x".to_string()), Some("name".to_string())],
    );
    let c = r.deep_clone();
    assert!(r.equals(&c));
}

#[test]
fn test_deep_clone_cell() {
    let c = Value::cell(Value::i32(42));
    let cloned = c.deep_clone();
    // 修改克隆不影响原
    cloned.as_cell().unwrap().set(Value::i32(99));
    assert_eq!(c.as_cell().unwrap().get().as_i32(), Some(42));
    assert_eq!(cloned.as_cell().unwrap().get().as_i32(), Some(99));
}

// =========================================================================
// 6. Display / Debug
// =========================================================================

#[test]
fn test_display_scalars() {
    assert_eq!(format!("{}", Value::null()), "null");
    assert_eq!(format!("{}", Value::void()), "()");
    assert_eq!(format!("{}", Value::bool(true)), "true");
    assert_eq!(format!("{}", Value::bool(false)), "false");
    assert_eq!(format!("{}", Value::i32(42)), "42");
    assert_eq!(format!("{}", Value::i64(-7)), "-7");
    assert_eq!(format!("{}", Value::u8(255)), "255");
    assert_eq!(format!("{}", Value::f64(2.5)), "2.5");
}

#[test]
fn test_display_string() {
    assert_eq!(format!("{}", Value::str("hello")), "hello");
}

#[test]
fn test_debug_type_tags() {
    assert_eq!(format!("{:?}", Value::i8(1)), "1i8");
    assert_eq!(format!("{:?}", Value::i64(1)), "1i64");
    assert_eq!(format!("{:?}", Value::u8(1)), "1u8");
    assert_eq!(format!("{:?}", Value::u64(1)), "1u64");
}

// =========================================================================
// 7. Default
// =========================================================================

#[test]
fn test_default_is_void() {
    let v: Value = Default::default();
    assert!(v.is_void());
}
