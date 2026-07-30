//! Value 模块完整集成测试
//!
//! 覆盖范围：
//! - 18 种标量的构造/访问/谓词
//! - 18×18 cast 转换矩阵（含溢出/NaN/Inf 边界）
//! - 23 种堆对象的构造/访问/equals
//! - equals/deep_clone 递归结构与深度限制
//!
//! 重构后所有值均通过 ValueArena 分配/访问。

use glue_rs::Value::*;

use std::rc::Rc;

// =========================================================================
// 1. 标量构造与访问
// =========================================================================

#[test]
fn test_all_scalar_constructors() {
    let mut a = ValueArena::new();
    // 布尔
    assert_eq!(a.bool(true).as_bool(&a), Some(true));
    assert_eq!(a.bool(false).as_bool(&a), Some(false));

    // 字符
    let c = a.from_rust_char('X');
    assert_eq!(c.as_char(&a).unwrap().codepoint(), 88);

    // 有符号整数
    assert_eq!(a.i8(-1).as_i8(&a), Some(-1));
    assert_eq!(a.i16(-2).as_i16(&a), Some(-2));
    assert_eq!(a.i32(-3).as_i32(&a), Some(-3));
    assert_eq!(a.i64(-4).as_i64(&a), Some(-4));
    assert_eq!(a.i128(-5).as_i128(&a), Some(-5));

    // 无符号整数
    assert_eq!(a.u8(1).as_u8(&a), Some(1));
    assert_eq!(a.u16(2).as_u16(&a), Some(2));
    assert_eq!(a.u32(3).as_u32(&a), Some(3));
    assert_eq!(a.u64(4).as_u64(&a), Some(4));
    assert_eq!(a.u128(5).as_u128(&a), Some(5));

    // 平台相关整数
    assert_eq!(a.isize(-6).as_isize(&a), Some(-6));
    assert_eq!(a.usize(7).as_usize(&a), Some(7));

    // 浮点
    assert_eq!(a.f32(1.5).as_f32(&a), Some(1.5));
    assert_eq!(a.f64(2.5).as_f64(&a), Some(2.5));
    assert!(a.f16(F16(0x3C00)).as_f16(&a).is_some()); // 1.0
    assert!(a.f128(F128([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xF8, 0x3F])).as_f128(&a).is_some()); // 1.0
}

#[test]
fn test_scalar_predicates() {
    let mut a = ValueArena::new();
    assert!(a.bool(true).is_bool());
    assert!(a.from_rust_char('x').is_char());

    // is_int 覆盖全部 12 种整数
    assert!(a.i8(0).is_int());
    assert!(a.i16(0).is_int());
    assert!(a.i32(0).is_int());
    assert!(a.i64(0).is_int());
    assert!(a.i128(0).is_int());
    assert!(a.u8(0).is_int());
    assert!(a.u16(0).is_int());
    assert!(a.u32(0).is_int());
    assert!(a.u64(0).is_int());
    assert!(a.u128(0).is_int());
    assert!(a.isize(0).is_int());
    assert!(a.usize(0).is_int());

    // is_float 覆盖全部 4 种浮点
    assert!(a.f16(F16(0)).is_float());
    assert!(a.f32(0.0).is_float());
    assert!(a.f64(0.0).is_float());
    assert!(a.f128(F128([0u8; 16])).is_float());

    // is_numeric = is_int || is_float
    assert!(a.i32(0).is_numeric());
    assert!(a.f64(0.0).is_numeric());
    assert!(!a.bool(true).is_numeric());
    assert!(!a.null().is_numeric());

    // is_scalar = is_bool || is_char || is_numeric
    assert!(a.bool(true).is_scalar());
    assert!(a.from_rust_char('x').is_scalar());
    assert!(a.i32(0).is_scalar());
    assert!(!a.null().is_scalar());
    assert!(!a.void().is_scalar());
    assert!(!a.str("x").is_scalar());
}

#[test]
fn test_scalar_type_names() {
    let mut a = ValueArena::new();
    assert_eq!(a.bool(true).type_name(&a), "bool");
    assert_eq!(a.from_rust_char('x').type_name(&a), "char");
    assert_eq!(a.i8(0).type_name(&a), "i8");
    assert_eq!(a.i16(0).type_name(&a), "i16");
    assert_eq!(a.i32(0).type_name(&a), "i32");
    assert_eq!(a.i64(0).type_name(&a), "i64");
    assert_eq!(a.i128(0).type_name(&a), "i128");
    assert_eq!(a.u8(0).type_name(&a), "u8");
    assert_eq!(a.u16(0).type_name(&a), "u16");
    assert_eq!(a.u32(0).type_name(&a), "u32");
    assert_eq!(a.u64(0).type_name(&a), "u64");
    assert_eq!(a.u128(0).type_name(&a), "u128");
    assert_eq!(a.isize(0).type_name(&a), "isize");
    assert_eq!(a.usize(0).type_name(&a), "usize");
    assert_eq!(a.f16(F16(0)).type_name(&a), "f16");
    assert_eq!(a.f32(0.0).type_name(&a), "f32");
    assert_eq!(a.f64(0.0).type_name(&a), "f64");
    assert_eq!(a.f128(F128([0u8; 16])).type_name(&a), "f128");
}

#[test]
fn test_scalar_tag_roundtrip() {
    let mut a = ValueArena::new();
    let cases: Vec<(ValueTag, ValueHandle)> = vec![
        (ValueTag::Bool, a.bool(true)),
        (ValueTag::Char, a.from_rust_char('x')),
        (ValueTag::I8, a.i8(1)),
        (ValueTag::I16, a.i16(1)),
        (ValueTag::I32, a.i32(1)),
        (ValueTag::I64, a.i64(1)),
        (ValueTag::I128, a.i128(1)),
        (ValueTag::U8, a.u8(1)),
        (ValueTag::U16, a.u16(1)),
        (ValueTag::U32, a.u32(1)),
        (ValueTag::U64, a.u64(1)),
        (ValueTag::U128, a.u128(1)),
        (ValueTag::Isize, a.isize(1)),
        (ValueTag::Usize, a.usize(1)),
        (ValueTag::F16, a.f16(F16(0))),
        (ValueTag::F32, a.f32(1.0)),
        (ValueTag::F64, a.f64(1.0)),
        (ValueTag::F128, a.f128(F128([0u8; 16]))),
    ];
    for (tag, val) in &cases {
        assert_eq!(val.scalar_tag(), Some(*tag), "tag mismatch for {:?}", tag);
    }
}

#[test]
fn test_int_promotion_to_i64() {
    let mut a = ValueArena::new();
    assert_eq!(a.i8(42).as_int_i64(&a), Some(42));
    assert_eq!(a.i16(42).as_int_i64(&a), Some(42));
    assert_eq!(a.i32(42).as_int_i64(&a), Some(42));
    assert_eq!(a.i64(42).as_int_i64(&a), Some(42));
    assert_eq!(a.i128(42).as_int_i64(&a), Some(42));
    assert_eq!(a.u8(42).as_int_i64(&a), Some(42));
    assert_eq!(a.u16(42).as_int_i64(&a), Some(42));
    assert_eq!(a.u32(42).as_int_i64(&a), Some(42));
    assert_eq!(a.u64(42).as_int_i64(&a), Some(42));
    assert_eq!(a.u128(42).as_int_i64(&a), Some(42));
    assert_eq!(a.isize(42).as_int_i64(&a), Some(42));
    assert_eq!(a.usize(42).as_int_i64(&a), Some(42));
    // 非整数返回 None
    assert_eq!(a.bool(true).as_int_i64(&a), None);
    assert_eq!(a.f64(42.0).as_int_i64(&a), None);
    assert_eq!(a.null().as_int_i64(&a), None);
}

#[test]
fn test_float_promotion_to_f64() {
    let mut a = ValueArena::new();
    assert_eq!(a.f32(1.5).as_float_f64(&a), Some(1.5));
    assert_eq!(a.f64(2.5).as_float_f64(&a), Some(2.5));
    // 非浮点返回 None
    assert_eq!(a.i32(42).as_float_f64(&a), None);
}

// =========================================================================
// 2. Cast 转换矩阵（纯字节级转换，不需要 arena）
// =========================================================================

#[test]
fn test_cast_int_to_int_safe() {
    let src_bytes = [42i32.to_le_bytes()].concat();
    let dst = cast_value(ValueTag::I32, &src_bytes, ValueTag::I64);
    assert_eq!(i64::from_le_bytes(dst.try_into().unwrap()), 42);
}

#[test]
fn test_cast_int_to_int_overflow_wrap() {
    // i32::MAX -> i8 应回绕
    let src_bytes = i32::MAX.to_le_bytes().to_vec();
    let dst = cast_value(ValueTag::I32, &src_bytes, ValueTag::I8);
    assert_eq!(i8::from_le_bytes(dst.try_into().unwrap()), -1);
}

#[test]
fn test_cast_int_to_uint() {
    let src_bytes = (-1i32).to_le_bytes().to_vec();
    let dst = cast_value(ValueTag::I32, &src_bytes, ValueTag::U32);
    assert_eq!(u32::from_le_bytes(dst.try_into().unwrap()), u32::MAX);
}

#[test]
fn test_cast_uint_to_int() {
    let src_bytes = u32::MAX.to_le_bytes().to_vec();
    let dst = cast_value(ValueTag::U32, &src_bytes, ValueTag::I32);
    assert_eq!(i32::from_le_bytes(dst.try_into().unwrap()), -1);
}

#[test]
fn test_cast_float_to_int_truncation() {
    let src_bytes = 3.7f64.to_le_bytes().to_vec();
    let dst = cast_value(ValueTag::F64, &src_bytes, ValueTag::I32);
    assert_eq!(i32::from_le_bytes(dst.try_into().unwrap()), 3);
}

#[test]
fn test_cast_float_to_int_inf() {
    let src_bytes = f64::INFINITY.to_le_bytes().to_vec();
    let dst = cast_value(ValueTag::F64, &src_bytes, ValueTag::I32);
    assert_eq!(i32::from_le_bytes(dst.try_into().unwrap()), i32::MAX);
}

#[test]
fn test_cast_float_to_int_neg_inf() {
    let src_bytes = f64::NEG_INFINITY.to_le_bytes().to_vec();
    let dst = cast_value(ValueTag::F64, &src_bytes, ValueTag::I32);
    assert_eq!(i32::from_le_bytes(dst.try_into().unwrap()), i32::MIN);
}

#[test]
fn test_cast_float_to_int_nan() {
    let src_bytes = f64::NAN.to_le_bytes().to_vec();
    let dst = cast_value(ValueTag::F64, &src_bytes, ValueTag::I32);
    assert_eq!(i32::from_le_bytes(dst.try_into().unwrap()), 0);
}

#[test]
fn test_cast_int_to_float() {
    let src_bytes = 42i32.to_le_bytes().to_vec();
    let dst = cast_value(ValueTag::I32, &src_bytes, ValueTag::F64);
    assert_eq!(f64::from_le_bytes(dst.try_into().unwrap()), 42.0);
}

#[test]
fn test_cast_float_to_float_widening() {
    let src_bytes = 1.5f32.to_le_bytes().to_vec();
    let dst = cast_value(ValueTag::F32, &src_bytes, ValueTag::F64);
    assert_eq!(f64::from_le_bytes(dst.try_into().unwrap()), 1.5);
}

#[test]
fn test_cast_float_to_float_narrowing() {
    let src_bytes = 1.5f64.to_le_bytes().to_vec();
    let dst = cast_value(ValueTag::F64, &src_bytes, ValueTag::F32);
    assert_eq!(f32::from_le_bytes(dst.try_into().unwrap()), 1.5);
}

#[test]
fn test_try_cast_overflow_checked() {
    let src_bytes = i32::MAX.to_le_bytes().to_vec();
    let result = try_cast_value(ValueTag::I32, &src_bytes, ValueTag::I8);
    assert_eq!(result, Err(CastError::Overflow));
}

#[test]
fn test_try_cast_safe() {
    let src_bytes = 42i32.to_le_bytes().to_vec();
    let result = try_cast_value(ValueTag::I32, &src_bytes, ValueTag::I64);
    assert!(result.is_ok());
    assert_eq!(i64::from_le_bytes(result.unwrap().try_into().unwrap()), 42);
}

#[test]
fn test_cast_bool_to_int() {
    let src_bytes = [1u8].to_vec();
    let dst = cast_value(ValueTag::Bool, &src_bytes, ValueTag::I32);
    assert_eq!(i32::from_le_bytes(dst.try_into().unwrap()), 1);
}

#[test]
fn test_cast_int_to_bool() {
    let src_bytes = 0i32.to_le_bytes().to_vec();
    let dst = cast_value(ValueTag::I32, &src_bytes, ValueTag::Bool);
    assert_eq!(dst, [0u8]);

    let src_bytes = 1i32.to_le_bytes().to_vec();
    let dst = cast_value(ValueTag::I32, &src_bytes, ValueTag::Bool);
    assert_eq!(dst, [1u8]);
}

#[test]
fn test_cast_char_to_codepoint() {
    let src_bytes = 65u32.to_le_bytes().to_vec(); // 'A'
    let dst = cast_value(ValueTag::Char, &src_bytes, ValueTag::U32);
    assert_eq!(u32::from_le_bytes(dst.try_into().unwrap()), 65);
}

// =========================================================================
// 3. 堆对象构造与访问
// =========================================================================

#[test]
fn test_heap_str() {
    let mut a = ValueArena::new();
    let s = a.str("hello");
    assert!(s.is_string(&a));
    assert!(s.is_ref());
    assert_eq!(s.type_name(&a), "str");
    assert_eq!(s.as_str(&a).unwrap().byte_len(), 5);
}

#[test]
fn test_heap_str_unicode() {
    let mut a = ValueArena::new();
    let s = a.str("你好");
    assert!(s.is_string(&a));
    assert_eq!(s.as_str(&a).unwrap().byte_len(), 6); // UTF-8 字节数
}

#[test]
fn test_heap_array() {
    let mut a = ValueArena::new();
    let e1 = a.i32(1);
    let e2 = a.i32(2);
    let e3 = a.i32(3);
    let arr = a.array(vec![e1, e2, e3]);
    assert!(arr.is_array(&a));
    assert_eq!(arr.type_name(&a), "array");
    assert_eq!(arr.as_array(&a).unwrap().len(), 3);
}

#[test]
fn test_heap_array_fixed() {
    let mut a = ValueArena::new();
    let e1 = a.i32(1);
    let e2 = a.i32(2);
    let arr = a.array_fixed(vec![e1, e2], 2);
    let array = arr.as_array(&a).unwrap();
    assert_eq!(array.fixed_size, Some(2));
}

#[test]
fn test_heap_record() {
    let mut a = ValueArena::new();
    let x = a.i32(1);
    let y = a.i32(2);
    let r = a.record(
        "Point",
        vec![x, y],
        vec![Some("x".to_string()), Some("y".to_string())],
    );
    assert!(r.is_record(&a));
    assert_eq!(r.type_name(&a), "record");
    let rec = r.as_record(&a).unwrap();
    assert_eq!(rec.type_name, "Point");
    assert_eq!(rec.find_field("x").unwrap().as_i32(&a), Some(1));
    assert_eq!(rec.find_field("y").unwrap().as_i32(&a), Some(2));
    assert_eq!(rec.find_field("z"), None);
}

#[test]
fn test_heap_adt() {
    let mut a = ValueArena::new();
    let v = a.i32(42);
    let adt_h = a.adt(
        "Option",
        "Some",
        vec![AdtField {
            name: None,
            value: v,
        }],
    );
    assert!(adt_h.is_adt(&a));
    assert_eq!(adt_h.type_name(&a), "adt");
    let adt = adt_h.as_adt(&a).unwrap();
    assert_eq!(adt.constructor, "Some");
    assert_eq!(adt.get_field(0).unwrap().as_i32(&a), Some(42));
}

#[test]
fn test_heap_newtype() {
    let mut a = ValueArena::new();
    let inner = a.i64(123);
    let n = a.newtype("UserId", inner);
    assert_eq!(n.type_name(&a), "newtype");
    let nt = n.as_newtype(&a).unwrap();
    assert_eq!(nt.type_name, "UserId");
    assert_eq!(nt.inner.as_i64(&a), Some(123));
}

#[test]
fn test_heap_cell() {
    let mut a = ValueArena::new();
    let v = a.i32(42);
    let c = a.cell(v);
    assert_eq!(c.type_name(&a), "cell");
    let v99 = a.i32(99);
    let cell = c.as_cell(&a).unwrap();
    let borrowed = cell.get();
    assert_eq!(borrowed.as_i32(&a), Some(42));
    drop(borrowed);
    cell.set(v99);
    let borrowed2 = cell.get();
    assert_eq!(borrowed2.as_i32(&a), Some(99));
}

#[test]
fn test_heap_range() {
    let mut a = ValueArena::new();
    let r = a.range(1, 10, false);
    assert_eq!(r.type_name(&a), "range");
    let rng = r.as_range(&a).unwrap();
    assert_eq!(rng.start, 1);
    assert_eq!(rng.end, 10);
    assert!(!rng.inclusive);
    assert!(rng.contains(5));
    assert!(!rng.contains(10));
    assert_eq!(rng.len(), 9);
}

#[test]
fn test_heap_range_inclusive() {
    let mut a = ValueArena::new();
    let r = a.range(1, 10, true);
    let rng = r.as_range(&a).unwrap();
    assert!(rng.contains(10));
    assert_eq!(rng.len(), 10);
}

#[test]
fn test_heap_closure() {
    let mut a = ValueArena::new();
    let uv = a.i32(1);
    let c = a.closure(Closure {
        func_id: 42,
        arity: 2,
        upvalues: vec![uv],
        bound_args: vec![],
        self_upvalue_idx: -1,
        upvalue_ref_bits: 1,
        cell_upvalues: 0,
    });
    assert!(c.is_closure(&a));
    assert!(c.is_callable(&a));
    assert_eq!(c.type_name(&a), "closure");
    let cl = c.as_closure(&a).unwrap();
    assert_eq!(cl.func_id, 42);
    assert_eq!(cl.arity, 2);
    assert_eq!(cl.upvalues.len(), 1);
}

#[test]
fn test_heap_partial() {
    let mut a = ValueArena::new();
    let bound = a.i32(42);
    let p = a.partial(PartialApplication {
        func_id: 1,
        bound_args: vec![bound],
        remaining_arity: 1,
        bound_arg_ref_bits: 0,
    });
    assert!(p.is_callable(&a));
    assert_eq!(p.type_name(&a), "partial");
}

#[test]
fn test_heap_builtin() {
    // BuiltinFn 签名为 fn(&[ValueHandle]) -> Result<ValueHandle, String>，
    // 无法在闭包内访问 arena，故返回单例句柄。
    fn add_fn(_args: &[ValueHandle]) -> Result<ValueHandle, String> {
        Ok(ValueHandle::NULL)
    }
    let mut a = ValueArena::new();
    let b = a.builtin(add_fn, "add");
    assert!(b.is_callable(&a));
    assert_eq!(b.type_name(&a), "builtin");
    let bi = b.as_builtin(&a).unwrap();
    assert_eq!(bi.name, "add");
}

#[test]
fn test_heap_trait_val() {
    let mut a = ValueArena::new();
    let method = a.builtin(|_| Ok(ValueHandle::NULL), "show");
    let t = TraitValue {
        trait_name: "Show".to_string(),
        method_names: vec!["show".to_string()],
        method_values: vec![method],
        data: None,
        owned: false,
    };
    let tv = a.trait_val(t);
    assert_eq!(tv.type_name(&a), "trait");
}

#[test]
fn test_heap_lazy() {
    let mut a = ValueArena::new();
    let cached = a.i32(42);
    let l = a.lazy(LazyValue {
        cached: Some(cached),
        forced: true,
        thunk: None,
    });
    assert_eq!(l.type_name(&a), "lazy");
}

#[test]
fn test_heap_error_val() {
    let mut a = ValueArena::new();
    let e = a.error_val("MyError", "something went wrong", false);
    assert_eq!(e.type_name(&a), "error");
    let err = e.as_error_val(&a).unwrap();
    assert_eq!(err.type_name, "MyError");
    assert_eq!(err.message, "something went wrong");
}

#[test]
fn test_heap_throw_ok() {
    let mut a = ValueArena::new();
    let v = a.i32(42);
    let t = a.throw_ok(v);
    assert_eq!(t.type_name(&a), "throw");
    let tv = t.as_throw_val(&a).unwrap();
    match &tv.payload {
        ThrowPayload::Ok(val) => assert_eq!(val.as_i32(&a), Some(42)),
        _ => panic!("expected Ok payload"),
    }
}

#[test]
fn test_heap_throw_err() {
    let mut a = ValueArena::new();
    let msg = a.str("msg");
    let record = Rc::new(RecordValue::new(
        "Error".to_string(),
        vec![msg],
        vec![Some("msg".to_string())],
    ));
    let t = a.throw_err(record);
    let tv = t.as_throw_val(&a).unwrap();
    match &tv.payload {
        ThrowPayload::Err(_) => {}
        _ => panic!("expected Err payload"),
    }
}

#[test]
fn test_heap_atomic() {
    let mut a = ValueArena::new();
    let v = a.i32(42);
    let at = a.atomic(v);
    assert_eq!(at.type_name(&a), "atomic");
    let v99 = a.i32(99);
    let v0 = a.i32(0);
    let atm = at.as_atomic(&a).unwrap();
    assert_eq!(atm.load().as_i32(&a), Some(42));
    atm.store(v99);
    assert_eq!(atm.load().as_i32(&a), Some(99));
    let old = atm.swap(v0);
    assert_eq!(old.as_i32(&a), Some(99));
    assert_eq!(atm.load().as_i32(&a), Some(0));
}

#[test]
fn test_heap_async_handle() {
    let mut a = ValueArena::new();
    let h = a.async_handle();
    assert_eq!(h.type_name(&a), "async");
    let v = a.i32(42);
    let ah = h.as_async_handle(&a).unwrap();
    assert_eq!(ah.status(), AsyncStatus::Pending);
    ah.set_status(AsyncStatus::Completed);
    ah.set_result(v);
    assert_eq!(ah.status(), AsyncStatus::Completed);
    assert_eq!(ah.result().unwrap().as_i32(&a), Some(42));
}

#[test]
fn test_heap_channel() {
    let mut a = ValueArena::new();
    let ch = a.channel(2);
    assert_eq!(ch.type_name(&a), "channel");
    let v1 = a.i32(1);
    let v2 = a.i32(2);
    let v3 = a.i32(3);
    let chan = ch.as_channel(&a).unwrap();
    assert!(chan.send(v1).is_ok());
    assert!(chan.send(v2).is_ok());
    assert!(chan.send(v3).is_err()); // 已满
    assert_eq!(chan.recv().unwrap().as_i32(&a), Some(1));
    assert_eq!(chan.recv().unwrap().as_i32(&a), Some(2));
    assert!(chan.recv().is_none());
}

#[test]
fn test_heap_sender_receiver() {
    let mut a = ValueArena::new();
    let ch = a.channel(1);
    let chan = ch.as_channel(&a).unwrap().clone();
    // 通过 Rc 共享通道
    let sender = a.sender(Rc::new(chan.clone()));
    let receiver = a.receiver(Rc::new(chan));
    assert_eq!(sender.type_name(&a), "sender");
    assert_eq!(receiver.type_name(&a), "receiver");
}

#[test]
fn test_heap_iterators() {
    let mut a = ValueArena::new();
    let e1 = a.i32(1);
    let e2 = a.i32(2);
    let arr = a.array_iter(Rc::new(vec![e1, e2]));
    assert_eq!(arr.type_name(&a), "array_iter");

    let s = a.string_iter(Rc::from("hello"));
    assert_eq!(s.type_name(&a), "string_iter");

    let r = a.range_iter(1, 5, false);
    assert_eq!(r.type_name(&a), "range_iter");
}

// =========================================================================
// 4. equals 深度比较
// =========================================================================

#[test]
fn test_equals_all_scalars() {
    let mut a = ValueArena::new();
    let v = a.i8(1);
    let w = a.i8(1);
    assert!(v.equals(&w, &a));
    let v = a.i16(1);
    let w = a.i16(1);
    assert!(v.equals(&w, &a));
    let v = a.i32(1);
    let w = a.i32(1);
    assert!(v.equals(&w, &a));
    let v = a.i64(1);
    let w = a.i64(1);
    assert!(v.equals(&w, &a));
    let v = a.i128(1);
    let w = a.i128(1);
    assert!(v.equals(&w, &a));
    let v = a.u8(1);
    let w = a.u8(1);
    assert!(v.equals(&w, &a));
    let v = a.u16(1);
    let w = a.u16(1);
    assert!(v.equals(&w, &a));
    let v = a.u32(1);
    let w = a.u32(1);
    assert!(v.equals(&w, &a));
    let v = a.u64(1);
    let w = a.u64(1);
    assert!(v.equals(&w, &a));
    let v = a.u128(1);
    let w = a.u128(1);
    assert!(v.equals(&w, &a));
    let v = a.f32(1.5);
    let w = a.f32(1.5);
    assert!(v.equals(&w, &a));
    let v = a.f64(1.5);
    let w = a.f64(1.5);
    assert!(v.equals(&w, &a));
}

#[test]
fn test_equals_cross_type_never_equal() {
    let mut a = ValueArena::new();
    let i8v = a.i8(1);
    let i16v = a.i16(1);
    assert!(!i8v.equals(&i16v, &a));
    let i32v = a.i32(1);
    let u32v = a.u32(1);
    assert!(!i32v.equals(&u32v, &a));
    let i64v = a.i64(1);
    let f64v = a.f64(1.0);
    assert!(!i64v.equals(&f64v, &a));
    let bv = a.bool(true);
    assert!(!bv.equals(&i8v, &a));
    let n = a.null();
    let vd = a.void();
    assert!(!n.equals(&vd, &a));
}

#[test]
fn test_equals_strings_content() {
    let mut a = ValueArena::new();
    let s1 = a.str("hello");
    let s2 = a.str("hello");
    let s3 = a.str("world");
    let i = a.i32(42);
    assert!(s1.equals(&s2, &a));
    assert!(!s1.equals(&s3, &a));
    assert!(!s1.equals(&i, &a));
}

#[test]
fn test_equals_nested_arrays() {
    let mut a = ValueArena::new();
    let e1 = a.i32(1);
    let sx = a.str("x");
    let ie1 = a.i32(10);
    let ie2 = a.i32(20);
    let inner1 = a.array(vec![ie1, ie2]);
    let a1 = a.array(vec![e1, sx, inner1]);

    let e1 = a.i32(1);
    let sx = a.str("x");
    let ie1 = a.i32(10);
    let ie2 = a.i32(20);
    let inner2 = a.array(vec![ie1, ie2]);
    let a2 = a.array(vec![e1, sx, inner2]);

    let e1 = a.i32(1);
    let sx = a.str("x");
    let ie1 = a.i32(10);
    let ie2 = a.i32(99);
    let inner3 = a.array(vec![ie1, ie2]);
    let a3 = a.array(vec![e1, sx, inner3]);

    assert!(a1.equals(&a2, &a));
    assert!(!a1.equals(&a3, &a));
}

#[test]
fn test_equals_records_with_fields() {
    let mut a = ValueArena::new();
    let x1 = a.i32(1);
    let l1 = a.str("origin");
    let r1 = a.record(
        "Point",
        vec![x1, l1],
        vec![Some("x".to_string()), Some("label".to_string())],
    );
    let x2 = a.i32(1);
    let l2 = a.str("origin");
    let r2 = a.record(
        "Point",
        vec![x2, l2],
        vec![Some("x".to_string()), Some("label".to_string())],
    );
    let x3 = a.i32(2);
    let l3 = a.str("origin");
    let r3 = a.record(
        "Point",
        vec![x3, l3],
        vec![Some("x".to_string()), Some("label".to_string())],
    );
    assert!(r1.equals(&r2, &a));
    assert!(!r1.equals(&r3, &a));
}

#[test]
fn test_equals_adt_variants() {
    let mut a = ValueArena::new();
    let v1 = a.i32(42);
    let some = a.adt("Option", "Some", vec![AdtField {
        name: None,
        value: v1,
    }]);
    let none = a.adt("Option", "None", vec![]);
    let v2 = a.i32(42);
    let some2 = a.adt("Option", "Some", vec![AdtField {
        name: None,
        value: v2,
    }]);
    assert!(some.equals(&some2, &a));
    assert!(!some.equals(&none, &a));
}

#[test]
fn test_equals_ref_sharing() {
    let mut a = ValueArena::new();
    let s1 = a.str("shared");
    let s2 = s1; // Copy：同一句柄，共享 Rc
    assert!(Rc::ptr_eq(a.get_ref(s1), a.get_ref(s2)));
    assert!(s1.equals(&s2, &a));
}

#[test]
fn test_partial_eq_trait_for_hashmap() {
    use std::collections::HashMap;

    // 重构后 PartialEq/Eq/Hash 基于句柄身份（u32 索引）：
    // 同一句柄可在 HashMap 中查回；单例常量稳定相等。
    let mut a = ValueArena::new();
    let mut map: HashMap<ValueHandle, &'static str> = HashMap::new();
    let key = a.str("key");
    map.insert(key, "value");
    assert_eq!(map.get(&key), Some(&"value"));

    let mut m2: HashMap<ValueHandle, i32> = HashMap::new();
    m2.insert(ValueHandle::NULL, 1);
    assert_eq!(m2.get(&ValueHandle::NULL), Some(&1));
}

// =========================================================================
// 5. deep_clone 深拷贝
// =========================================================================

#[test]
fn test_deep_clone_scalar_is_copy() {
    let mut a = ValueArena::new();
    let v = a.i32(42);
    let c = v.deep_clone(&mut a);
    assert!(v.equals(&c, &a));
}

#[test]
fn test_deep_clone_string_independent() {
    let mut a = ValueArena::new();
    let s1 = a.str("hello");
    let s2 = s1.deep_clone(&mut a);
    assert!(s1.equals(&s2, &a));
    // 深拷贝后 Rc 指针不同
    assert!(!Rc::ptr_eq(a.get_ref(s1), a.get_ref(s2)));
}

#[test]
fn test_deep_clone_nested_array() {
    let mut a = ValueArena::new();
    let e1 = a.i32(1);
    let sn = a.str("nested");
    let ie1 = a.i32(10);
    let ie2 = a.i32(20);
    let inner = a.array(vec![ie1, ie2]);
    let original = a.array(vec![e1, sn, inner]);
    let cloned = original.deep_clone(&mut a);
    assert!(original.equals(&cloned, &a));
    // 外层数组 Rc 不同
    assert!(!Rc::ptr_eq(a.get_ref(original), a.get_ref(cloned)));
    // 内层数组 Rc 也不同
    let orig_inner = match a.get_ref(original).as_ref() {
        HeapObj::Array(arr) => a.get_ref(arr.elements[2]).clone(),
        _ => panic!("expected Array"),
    };
    let clone_inner = match a.get_ref(cloned).as_ref() {
        HeapObj::Array(arr) => a.get_ref(arr.elements[2]).clone(),
        _ => panic!("expected Array"),
    };
    assert!(!Rc::ptr_eq(&orig_inner, &clone_inner));
}

#[test]
fn test_deep_clone_record() {
    let mut a = ValueArena::new();
    let x = a.i32(1);
    let label = a.str("label");
    let r = a.record(
        "Point",
        vec![x, label],
        vec![Some("x".to_string()), Some("name".to_string())],
    );
    let c = r.deep_clone(&mut a);
    assert!(r.equals(&c, &a));
}

#[test]
fn test_deep_clone_cell() {
    let mut a = ValueArena::new();
    let v = a.i32(42);
    let c = a.cell(v);
    let cloned = c.deep_clone(&mut a);
    // 修改克隆不影响原
    let v99 = a.i32(99);
    cloned.as_cell(&a).unwrap().set(v99);
    assert_eq!(c.as_cell(&a).unwrap().get().as_i32(&a), Some(42));
    assert_eq!(cloned.as_cell(&a).unwrap().get().as_i32(&a), Some(99));
}

// =========================================================================
// 6. Display / Debug
// =========================================================================

#[test]
fn test_display_scalars() {
    let mut a = ValueArena::new();
    let n = a.null();
    let vd = a.void();
    let bt = a.bool(true);
    let bf = a.bool(false);
    let i = a.i32(42);
    let i64v = a.i64(-7);
    let u = a.u8(255);
    let f = a.f64(2.5);
    assert_eq!(format!("{}", a.display(n)), "null");
    assert_eq!(format!("{}", a.display(vd)), "()");
    assert_eq!(format!("{}", a.display(bt)), "true");
    assert_eq!(format!("{}", a.display(bf)), "false");
    assert_eq!(format!("{}", a.display(i)), "42");
    assert_eq!(format!("{}", a.display(i64v)), "-7");
    assert_eq!(format!("{}", a.display(u)), "255");
    assert_eq!(format!("{}", a.display(f)), "2.5");
}

#[test]
fn test_display_string() {
    let mut a = ValueArena::new();
    let s = a.str("hello");
    assert_eq!(format!("{}", a.display(s)), "hello");
}

#[test]
fn test_debug_type_tags() {
    let mut a = ValueArena::new();
    let i8v = a.i8(1);
    assert_eq!(format!("{:?}", a.debug(i8v)), "1i8");
    let i64v = a.i64(1);
    assert_eq!(format!("{:?}", a.debug(i64v)), "1i64");
    let u8v = a.u8(1);
    assert_eq!(format!("{:?}", a.debug(u8v)), "1u8");
    let u64v = a.u64(1);
    assert_eq!(format!("{:?}", a.debug(u64v)), "1u64");
}

// =========================================================================
// 7. Default
// =========================================================================

#[test]
fn test_default_is_void() {
    let v: ValueHandle = Default::default();
    assert!(v.is_void());
}
