// =========================================================================
// ValueHandle —— Value trait 实现（通过 ValueArena 访问桶内数据）
// =========================================================================

impl Value for ValueHandle {
    // ---- 谓词（仅看 tag，不需要 arena）----
    #[inline]
    fn is_null(&self) -> bool {
        self.tag() == ValueTag::Null
    }
    #[inline]
    fn is_void(&self) -> bool {
        self.tag() == ValueTag::Void
    }
    #[inline]
    fn is_bool(&self) -> bool {
        self.tag() == ValueTag::Bool
    }
    #[inline]
    fn is_char(&self) -> bool {
        self.tag() == ValueTag::Char
    }
    #[inline]
    fn is_int(&self) -> bool {
        self.tag().is_int()
    }
    #[inline]
    fn is_float(&self) -> bool {
        self.tag().is_float()
    }
    #[inline]
    fn is_numeric(&self) -> bool {
        self.tag().is_numeric()
    }
    #[inline]
    fn is_scalar(&self) -> bool {
        self.tag().is_scalar()
    }
    #[inline]
    fn is_ref(&self) -> bool {
        self.tag() == ValueTag::Ref
    }
    #[inline]
    fn requires_release(&self) -> bool {
        !matches!(self.tag(), ValueTag::Null | ValueTag::Void | ValueTag::Bool)
    }

    // ---- 堆谓词（需要 arena 解引用 HeapObj）----
    #[inline]
    fn is_string(&self, arena: &ValueArena) -> bool {
        matches!(arena.heap_obj_opt(*self), Some(HeapObj::Str(_)))
    }
    #[inline]
    fn is_array(&self, arena: &ValueArena) -> bool {
        matches!(arena.heap_obj_opt(*self), Some(HeapObj::Array(_)))
    }
    #[inline]
    fn is_record(&self, arena: &ValueArena) -> bool {
        matches!(arena.heap_obj_opt(*self), Some(HeapObj::Record(_)))
    }
    #[inline]
    fn is_adt(&self, arena: &ValueArena) -> bool {
        matches!(arena.heap_obj_opt(*self), Some(HeapObj::Adt(_)))
    }
    #[inline]
    fn is_closure(&self, arena: &ValueArena) -> bool {
        matches!(arena.heap_obj_opt(*self), Some(HeapObj::Closure(_)))
    }
    #[inline]
    fn is_callable(&self, arena: &ValueArena) -> bool {
        matches!(
            arena.heap_obj_opt(*self),
            Some(HeapObj::Closure(_) | HeapObj::Builtin(_) | HeapObj::Partial(_))
        )
    }

    // ---- 类型信息 ----
    fn type_name(&self, arena: &ValueArena) -> &'static str {
        match self.tag() {
            ValueTag::Null => "null",
            ValueTag::Void => "void",
            ValueTag::Ref => arena.get_ref(*self).type_name(),
            t => t.name(),
        }
    }
    #[inline]
    fn scalar_tag(&self) -> Option<ValueTag> {
        let t = self.tag();
        if t.is_scalar() {
            Some(t)
        } else {
            None
        }
    }

    // ---- 标量访问器（需要 arena 取值）----
    #[inline]
    fn as_bool(&self, arena: &ValueArena) -> Option<bool> {
        if self.tag() == ValueTag::Bool {
            Some(arena.get_bool(*self))
        } else {
            None
        }
    }
    #[inline]
    fn as_i8(&self, arena: &ValueArena) -> Option<i8> {
        if self.tag() == ValueTag::I8 {
            Some(arena.get_i8(*self))
        } else {
            None
        }
    }
    #[inline]
    fn as_i16(&self, arena: &ValueArena) -> Option<i16> {
        if self.tag() == ValueTag::I16 {
            Some(arena.get_i16(*self))
        } else {
            None
        }
    }
    #[inline]
    fn as_i32(&self, arena: &ValueArena) -> Option<i32> {
        if self.tag() == ValueTag::I32 {
            Some(arena.get_i32(*self))
        } else {
            None
        }
    }
    #[inline]
    fn as_i64(&self, arena: &ValueArena) -> Option<i64> {
        if self.tag() == ValueTag::I64 {
            Some(arena.get_i64(*self))
        } else {
            None
        }
    }
    #[inline]
    fn as_i128(&self, arena: &ValueArena) -> Option<i128> {
        if self.tag() == ValueTag::I128 {
            Some(arena.get_i128(*self))
        } else {
            None
        }
    }
    #[inline]
    fn as_u8(&self, arena: &ValueArena) -> Option<u8> {
        if self.tag() == ValueTag::U8 {
            Some(arena.get_u8(*self))
        } else {
            None
        }
    }
    #[inline]
    fn as_u16(&self, arena: &ValueArena) -> Option<u16> {
        if self.tag() == ValueTag::U16 {
            Some(arena.get_u16(*self))
        } else {
            None
        }
    }
    #[inline]
    fn as_u32(&self, arena: &ValueArena) -> Option<u32> {
        if self.tag() == ValueTag::U32 {
            Some(arena.get_u32(*self))
        } else {
            None
        }
    }
    #[inline]
    fn as_u64(&self, arena: &ValueArena) -> Option<u64> {
        if self.tag() == ValueTag::U64 {
            Some(arena.get_u64(*self))
        } else {
            None
        }
    }
    #[inline]
    fn as_u128(&self, arena: &ValueArena) -> Option<u128> {
        if self.tag() == ValueTag::U128 {
            Some(arena.get_u128(*self))
        } else {
            None
        }
    }
    #[inline]
    fn as_isize(&self, arena: &ValueArena) -> Option<isize> {
        if self.tag() == ValueTag::Isize {
            Some(arena.get_isize(*self))
        } else {
            None
        }
    }
    #[inline]
    fn as_usize(&self, arena: &ValueArena) -> Option<usize> {
        if self.tag() == ValueTag::Usize {
            Some(arena.get_usize(*self))
        } else {
            None
        }
    }
    #[inline]
    fn as_f32(&self, arena: &ValueArena) -> Option<f32> {
        if self.tag() == ValueTag::F32 {
            Some(arena.get_f32(*self))
        } else {
            None
        }
    }
    #[inline]
    fn as_f64(&self, arena: &ValueArena) -> Option<f64> {
        if self.tag() == ValueTag::F64 {
            Some(arena.get_f64(*self))
        } else {
            None
        }
    }
    #[inline]
    fn as_char(&self, arena: &ValueArena) -> Option<Char> {
        if self.tag() == ValueTag::Char {
            Some(Char::from_codepoint_unchecked(arena.get_char(*self)))
        } else {
            None
        }
    }
    #[inline]
    fn as_f16(&self, arena: &ValueArena) -> Option<F16> {
        if self.tag() == ValueTag::F16 {
            Some(F16(arena.get_f16(*self)))
        } else {
            None
        }
    }
    #[inline]
    fn as_f128(&self, arena: &ValueArena) -> Option<F128> {
        if self.tag() == ValueTag::F128 {
            Some(arena.get_f128(*self))
        } else {
            None
        }
    }

    // ---- 堆访问器 ----
    #[inline]
    fn as_str<'a>(&self, arena: &'a ValueArena) -> Option<&'a GlueStr> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::Str(s) => Some(s),
            _ => None,
        }
    }
    #[inline]
    fn as_array<'a>(&self, arena: &'a ValueArena) -> Option<&'a ArrayValue> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::Array(a) => Some(a),
            _ => None,
        }
    }
    #[inline]
    fn as_record<'a>(&self, arena: &'a ValueArena) -> Option<&'a RecordValue> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::Record(r) => Some(r),
            _ => None,
        }
    }
    #[inline]
    fn as_adt<'a>(&self, arena: &'a ValueArena) -> Option<&'a AdtValue> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::Adt(a) => Some(a),
            _ => None,
        }
    }
    #[inline]
    fn as_newtype<'a>(&self, arena: &'a ValueArena) -> Option<&'a NewtypeValue> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::Newtype(n) => Some(n),
            _ => None,
        }
    }
    #[inline]
    fn as_cell<'a>(&self, arena: &'a ValueArena) -> Option<&'a Cell> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::Cell(c) => Some(c),
            _ => None,
        }
    }
    #[inline]
    fn as_range<'a>(&self, arena: &'a ValueArena) -> Option<&'a Range> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::Range(r) => Some(r),
            _ => None,
        }
    }
    #[inline]
    fn as_closure<'a>(&self, arena: &'a ValueArena) -> Option<&'a Closure> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::Closure(c) => Some(c),
            _ => None,
        }
    }
    #[inline]
    fn as_partial<'a>(&self, arena: &'a ValueArena) -> Option<&'a PartialApplication> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::Partial(p) => Some(p),
            _ => None,
        }
    }
    #[inline]
    fn as_builtin<'a>(&self, arena: &'a ValueArena) -> Option<&'a Builtin> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::Builtin(b) => Some(b),
            _ => None,
        }
    }
    #[inline]
    fn as_trait_val<'a>(&self, arena: &'a ValueArena) -> Option<&'a TraitValue> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::TraitVal(t) => Some(t),
            _ => None,
        }
    }
    #[inline]
    fn as_lazy<'a>(&self, arena: &'a ValueArena) -> Option<&'a LazyValue> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::LazyVal(l) => Some(l),
            _ => None,
        }
    }
    #[inline]
    fn as_error_val<'a>(&self, arena: &'a ValueArena) -> Option<&'a ErrorValue> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::ErrorVal(e) => Some(e),
            _ => None,
        }
    }
    #[inline]
    fn as_throw_val<'a>(&self, arena: &'a ValueArena) -> Option<&'a ThrowValue> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::ThrowVal(t) => Some(t),
            _ => None,
        }
    }
    #[inline]
    fn as_array_iter<'a>(&self, arena: &'a ValueArena) -> Option<&'a ArrayIterator> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::ArrayIter(i) => Some(i),
            _ => None,
        }
    }
    #[inline]
    fn as_string_iter<'a>(&self, arena: &'a ValueArena) -> Option<&'a StringIterator> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::StringIter(i) => Some(i),
            _ => None,
        }
    }
    #[inline]
    fn as_range_iter_obj<'a>(&self, arena: &'a ValueArena) -> Option<&'a RangeIterator> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::RangeIter(i) => Some(i),
            _ => None,
        }
    }
    #[inline]
    fn as_atomic<'a>(&self, arena: &'a ValueArena) -> Option<&'a AtomicValue> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::AtomicVal(a) => Some(a),
            _ => None,
        }
    }
    #[inline]
    fn as_async_handle<'a>(&self, arena: &'a ValueArena) -> Option<&'a AsyncHandle> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::AsyncVal(a) => Some(a),
            _ => None,
        }
    }
    #[inline]
    fn as_channel<'a>(&self, arena: &'a ValueArena) -> Option<&'a ChannelValue> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::ChannelVal(c) => Some(c),
            _ => None,
        }
    }
    #[inline]
    fn as_sender<'a>(&self, arena: &'a ValueArena) -> Option<&'a SenderValue> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::SenderVal(s) => Some(s),
            _ => None,
        }
    }
    #[inline]
    fn as_receiver<'a>(&self, arena: &'a ValueArena) -> Option<&'a ReceiverValue> {
        match arena.heap_obj_opt(*self)? {
            HeapObj::ReceiverVal(r) => Some(r),
            _ => None,
        }
    }
    #[inline]
    fn as_ref<'a>(&self, arena: &'a ValueArena) -> Option<&'a HeapRef> {
        if self.tag() == ValueTag::Ref {
            Some(arena.get_ref(*self))
        } else {
            None
        }
    }
    #[inline]
    fn ref_kind(&self, arena: &ValueArena) -> Option<RefKind> {
        arena.heap_obj_opt(*self).map(|o| o.ref_kind())
    }

    // ---- 数值提升 ----
    fn as_int_i64(&self, arena: &ValueArena) -> Option<i64> {
        match self.tag() {
            ValueTag::I8 => Some(arena.get_i8(*self) as i64),
            ValueTag::I16 => Some(arena.get_i16(*self) as i64),
            ValueTag::I32 => Some(arena.get_i32(*self) as i64),
            ValueTag::I64 => Some(arena.get_i64(*self)),
            ValueTag::I128 => Some(arena.get_i128(*self) as i64),
            ValueTag::U8 => Some(arena.get_u8(*self) as i64),
            ValueTag::U16 => Some(arena.get_u16(*self) as i64),
            ValueTag::U32 => Some(arena.get_u32(*self) as i64),
            ValueTag::U64 => Some(arena.get_u64(*self) as i64),
            ValueTag::U128 => Some(arena.get_u128(*self) as i64),
            ValueTag::Isize => Some(arena.get_isize(*self) as i64),
            ValueTag::Usize => Some(arena.get_usize(*self) as i64),
            _ => None,
        }
    }
    fn as_int_i128(&self, arena: &ValueArena) -> Option<i128> {
        match self.tag() {
            ValueTag::I8 => Some(arena.get_i8(*self) as i128),
            ValueTag::I16 => Some(arena.get_i16(*self) as i128),
            ValueTag::I32 => Some(arena.get_i32(*self) as i128),
            ValueTag::I64 => Some(arena.get_i64(*self) as i128),
            ValueTag::I128 => Some(arena.get_i128(*self)),
            ValueTag::U8 => Some(arena.get_u8(*self) as i128),
            ValueTag::U16 => Some(arena.get_u16(*self) as i128),
            ValueTag::U32 => Some(arena.get_u32(*self) as i128),
            ValueTag::U64 => Some(arena.get_u64(*self) as i128),
            ValueTag::U128 => Some(arena.get_u128(*self) as i128),
            ValueTag::Isize => Some(arena.get_isize(*self) as i128),
            ValueTag::Usize => Some(arena.get_usize(*self) as i128),
            _ => None,
        }
    }
    fn as_float_f64(&self, arena: &ValueArena) -> Option<f64> {
        match self.tag() {
            ValueTag::F16 => Some(F16(arena.get_f16(*self)).to_f64()),
            ValueTag::F32 => Some(arena.get_f32(*self) as f64),
            ValueTag::F64 => Some(arena.get_f64(*self)),
            ValueTag::F128 => Some(arena.get_f128(*self).to_f64()),
            _ => None,
        }
    }

    // ---- 相等与深克隆 ----
    fn equals(&self, other: &Self, arena: &ValueArena) -> bool {
        if self.tag() != other.tag() {
            return false;
        }
        match self.tag() {
            ValueTag::Null | ValueTag::Void => true,
            ValueTag::Bool => arena.get_bool(*self) == arena.get_bool(*other),
            ValueTag::Char => arena.get_char(*self) == arena.get_char(*other),
            ValueTag::I8 => arena.get_i8(*self) == arena.get_i8(*other),
            ValueTag::I16 => arena.get_i16(*self) == arena.get_i16(*other),
            ValueTag::I32 => arena.get_i32(*self) == arena.get_i32(*other),
            ValueTag::I64 => arena.get_i64(*self) == arena.get_i64(*other),
            ValueTag::I128 => arena.get_i128(*self) == arena.get_i128(*other),
            ValueTag::U8 => arena.get_u8(*self) == arena.get_u8(*other),
            ValueTag::U16 => arena.get_u16(*self) == arena.get_u16(*other),
            ValueTag::U32 => arena.get_u32(*self) == arena.get_u32(*other),
            ValueTag::U64 => arena.get_u64(*self) == arena.get_u64(*other),
            ValueTag::U128 => arena.get_u128(*self) == arena.get_u128(*other),
            ValueTag::Isize => arena.get_isize(*self) == arena.get_isize(*other),
            ValueTag::Usize => arena.get_usize(*self) == arena.get_usize(*other),
            ValueTag::F16 => arena.get_f16(*self) == arena.get_f16(*other),
            ValueTag::F32 => {
                arena.get_f32(*self).to_bits() == arena.get_f32(*other).to_bits()
            }
            ValueTag::F64 => {
                arena.get_f64(*self).to_bits() == arena.get_f64(*other).to_bits()
            }
            ValueTag::F128 => arena.get_f128(*self) == arena.get_f128(*other),
            ValueTag::Ref => {
                let a = arena.get_ref(*self);
                let b = arena.get_ref(*other);
                Rc::ptr_eq(a, b) || heap_equals(a, b, arena)
            }
        }
    }

    fn deep_clone(&self, arena: &mut ValueArena) -> Self {
        let mut cache: HashMap<*const HeapObj, ValueHandle> = HashMap::new();
        deep_clone_handle(*self, arena, &mut cache)
    }
}

// =========================================================================
// 堆对象深比较与深克隆（带 ptr_eq 缓存以共享子图）
// =========================================================================

fn heap_equals(a: &HeapObj, b: &HeapObj, arena: &ValueArena) -> bool {
    match (a, b) {
        (HeapObj::Str(x), HeapObj::Str(y)) => x.equals(y),
        (HeapObj::Array(x), HeapObj::Array(y)) => {
            x.fixed_size == y.fixed_size
                && x.elements.len() == y.elements.len()
                && x
                    .elements
                    .iter()
                    .zip(&y.elements)
                    .all(|(p, q)| p.equals(q, arena))
        }
        (HeapObj::Record(x), HeapObj::Record(y)) => {
            x.type_name == y.type_name
                && x.field_names == y.field_names
                && x.fields.len() == y.fields.len()
                && x.fields.iter().zip(&y.fields).all(|(p, q)| p.equals(q, arena))
        }
        (HeapObj::Adt(x), HeapObj::Adt(y)) => {
            x.type_name == y.type_name
                && x.constructor == y.constructor
                && x.fields.len() == y.fields.len()
                && x
                    .fields
                    .iter()
                    .zip(&y.fields)
                    .all(|(xf, yf)| xf.value.equals(&yf.value, arena))
        }
        (HeapObj::Newtype(x), HeapObj::Newtype(y)) => {
            x.type_name == y.type_name && x.inner.equals(&y.inner, arena)
        }
        (HeapObj::Cell(x), HeapObj::Cell(y)) => {
            let xb = x.inner.borrow().clone();
            let yb = y.inner.borrow().clone();
            xb.equals(&yb, arena)
        }
        (HeapObj::Range(x), HeapObj::Range(y)) => {
            x.start == y.start && x.end == y.end && x.inclusive == y.inclusive
        }
        (HeapObj::ErrorVal(x), HeapObj::ErrorVal(y)) => {
            x.type_name == y.type_name
                && x.message == y.message
                && x.is_error_subtype == y.is_error_subtype
        }
        (HeapObj::ThrowVal(x), HeapObj::ThrowVal(y)) => match (&x.payload, &y.payload) {
            (ThrowPayload::Ok(a), ThrowPayload::Ok(b)) => a.equals(b, arena),
            (ThrowPayload::Err(a), ThrowPayload::Err(b)) => Rc::ptr_eq(a, b),
            _ => false,
        },
        (HeapObj::Closure(x), HeapObj::Closure(y)) => {
            x.func_id == y.func_id
                && x.arity == y.arity
                && x.upvalues.len() == y.upvalues.len()
                && x
                    .upvalues
                    .iter()
                    .zip(&y.upvalues)
                    .all(|(p, q)| p.equals(q, arena))
        }
        (HeapObj::Builtin(x), HeapObj::Builtin(y)) => {
            (x.fn_ptr as usize) == (y.fn_ptr as usize) && x.name == y.name
        }
        (HeapObj::ArrayIter(x), HeapObj::ArrayIter(y)) => {
            Rc::ptr_eq(&x.array, &y.array) && x.index == y.index
        }
        (HeapObj::StringIter(x), HeapObj::StringIter(y)) => {
            Rc::ptr_eq(&x.string, &y.string) && x.byte_offset == y.byte_offset
        }
        (HeapObj::RangeIter(x), HeapObj::RangeIter(y)) => {
            x.current == y.current && x.end == y.end && x.inclusive == y.inclusive
        }
        _ => std::mem::discriminant(a) == std::mem::discriminant(b),
    }
}

fn deep_clone_handle(
    h: ValueHandle,
    arena: &mut ValueArena,
    cache: &mut HashMap<*const HeapObj, ValueHandle>,
) -> ValueHandle {
    match h.tag() {
        ValueTag::Null => ValueHandle::NULL,
        ValueTag::Void => ValueHandle::VOID,
        ValueTag::Bool => ValueArena::bool_val(arena.get_bool(h)),
        ValueTag::Char => arena.alloc_char(arena.get_char(h)),
        ValueTag::I8 => arena.alloc_i8(arena.get_i8(h)),
        ValueTag::I16 => arena.alloc_i16(arena.get_i16(h)),
        ValueTag::I32 => arena.alloc_i32(arena.get_i32(h)),
        ValueTag::I64 => arena.alloc_i64(arena.get_i64(h)),
        ValueTag::I128 => arena.alloc_i128(arena.get_i128(h)),
        ValueTag::U8 => arena.alloc_u8(arena.get_u8(h)),
        ValueTag::U16 => arena.alloc_u16(arena.get_u16(h)),
        ValueTag::U32 => arena.alloc_u32(arena.get_u32(h)),
        ValueTag::U64 => arena.alloc_u64(arena.get_u64(h)),
        ValueTag::U128 => arena.alloc_u128(arena.get_u128(h)),
        ValueTag::Isize => arena.alloc_isize(arena.get_isize(h)),
        ValueTag::Usize => arena.alloc_usize(arena.get_usize(h)),
        ValueTag::F16 => arena.alloc_f16(arena.get_f16(h)),
        ValueTag::F32 => arena.alloc_f32(arena.get_f32(h)),
        ValueTag::F64 => arena.alloc_f64(arena.get_f64(h)),
        ValueTag::F128 => arena.alloc_f128(arena.get_f128(h)),
        ValueTag::Ref => {
            let rc = arena.get_ref(h).clone();
            let key = Rc::as_ptr(&rc) as *const HeapObj;
            if let Some(&cached) = cache.get(&key) {
                return cached;
            }
            let new_obj = deep_clone_heap(&rc, arena, cache);
            let new_h = arena.alloc_ref_rc(Rc::new(new_obj));
            cache.insert(key, new_h);
            new_h
        }
    }
}

fn deep_clone_heap(
    obj: &HeapObj,
    arena: &mut ValueArena,
    cache: &mut HashMap<*const HeapObj, ValueHandle>,
) -> HeapObj {
    match obj {
        HeapObj::Str(s) => HeapObj::Str(s.clone()),
        HeapObj::Array(a) => {
            let elems: Vec<ValueHandle> = a
                .elements
                .iter()
                .map(|e| deep_clone_handle(*e, arena, cache))
                .collect();
            HeapObj::Array(ArrayValue {
                elements: elems,
                fixed_size: a.fixed_size,
                elem_is_ref: a.elem_is_ref,
                scalar_soa: a.scalar_soa.clone(),
            })
        }
        HeapObj::Record(r) => {
            let fields: Vec<ValueHandle> = r
                .fields
                .iter()
                .map(|e| deep_clone_handle(*e, arena, cache))
                .collect();
            HeapObj::Record(RecordValue {
                type_name: r.type_name.clone(),
                fields,
                field_names: r.field_names.clone(),
                field_ref_bits: r.field_ref_bits,
            })
        }
        HeapObj::Adt(a) => {
            let fields: Vec<AdtField> = a
                .fields
                .iter()
                .map(|f| AdtField {
                    name: f.name.clone(),
                    value: deep_clone_handle(f.value, arena, cache),
                })
                .collect();
            HeapObj::Adt(AdtValue {
                type_name: a.type_name.clone(),
                constructor: a.constructor.clone(),
                fields,
                field_ref_bits: a.field_ref_bits,
            })
        }
        HeapObj::Newtype(n) => HeapObj::Newtype(NewtypeValue {
            type_name: n.type_name.clone(),
            inner: deep_clone_handle(n.inner, arena, cache),
        }),
        HeapObj::Cell(c) => {
            let inner = c.inner.borrow().clone();
            HeapObj::Cell(Cell::new(deep_clone_handle(inner, arena, cache)))
        }
        HeapObj::Range(r) => HeapObj::Range(r.clone()),
        HeapObj::Closure(c) => {
            let upvalues: Vec<ValueHandle> = c
                .upvalues
                .iter()
                .map(|e| deep_clone_handle(*e, arena, cache))
                .collect();
            let bound_args: Vec<ValueHandle> = c
                .bound_args
                .iter()
                .map(|e| deep_clone_handle(*e, arena, cache))
                .collect();
            HeapObj::Closure(Closure {
                func_id: c.func_id,
                arity: c.arity,
                upvalues,
                bound_args,
                self_upvalue_idx: c.self_upvalue_idx,
                upvalue_ref_bits: c.upvalue_ref_bits,
                cell_upvalues: c.cell_upvalues,
            })
        }
        HeapObj::Partial(p) => {
            let bound_args: Vec<ValueHandle> = p
                .bound_args
                .iter()
                .map(|e| deep_clone_handle(*e, arena, cache))
                .collect();
            HeapObj::Partial(PartialApplication {
                func_id: p.func_id,
                bound_args,
                remaining_arity: p.remaining_arity,
                bound_arg_ref_bits: p.bound_arg_ref_bits,
            })
        }
        HeapObj::ThrowVal(t) => match &t.payload {
            ThrowPayload::Ok(v) => HeapObj::ThrowVal(ThrowValue {
                payload: ThrowPayload::Ok(deep_clone_handle(*v, arena, cache)),
            }),
            ThrowPayload::Err(r) => HeapObj::ThrowVal(ThrowValue {
                payload: ThrowPayload::Err(r.clone()),
            }),
        },
        HeapObj::ArrayIter(a) => HeapObj::ArrayIter(ArrayIterator::new(a.array.clone())),
        HeapObj::StringIter(s) => HeapObj::StringIter(StringIterator::new(s.string.clone())),
        HeapObj::RangeIter(r) => HeapObj::RangeIter(RangeIterator::new(r.current, r.end, r.inclusive)),
        HeapObj::Builtin(b) => HeapObj::Builtin(b.clone()),
        HeapObj::TraitVal(t) => HeapObj::TraitVal(t.clone()),
        HeapObj::LazyVal(l) => HeapObj::LazyVal(l.clone()),
        HeapObj::ErrorVal(e) => HeapObj::ErrorVal(e.clone()),
        HeapObj::AtomicVal(a) => HeapObj::AtomicVal(AtomicValue::new(a.inner.borrow().clone())),
        HeapObj::AsyncVal(a) => HeapObj::AsyncVal(a.clone()),
        HeapObj::ChannelVal(c) => HeapObj::ChannelVal(c.clone()),
        HeapObj::SenderVal(s) => HeapObj::SenderVal(s.clone()),
        HeapObj::ReceiverVal(r) => HeapObj::ReceiverVal(r.clone()),
        HeapObj::CoroutineFrame => HeapObj::CoroutineFrame,
    }
}

// =========================================================================
// ValueArena 便捷构造器（镜像旧 ValueHandle 构造器 API）+ 格式化/哈希辅助
// =========================================================================

impl ValueArena {
    /// 若句柄为 Ref，返回对应堆对象引用；否则返回 None。
    #[inline]
    pub fn heap_obj_opt(&self, h: ValueHandle) -> Option<&HeapObj> {
        if h.tag() == ValueTag::Ref {
            Some(self.get_ref(h).as_ref())
        } else {
            None
        }
    }

    // ---- 单例便捷构造器（无分配）----
    // null()/void() 由既有 impl ValueArena 提供（已改为 &self）。
    #[inline]
    pub fn bool(&self, v: bool) -> ValueHandle {
        Self::bool_val(v)
    }

    // ---- 标量分配便捷别名 ----
    #[inline]
    pub fn i8(&mut self, v: i8) -> ValueHandle {
        self.alloc_i8(v)
    }
    #[inline]
    pub fn i16(&mut self, v: i16) -> ValueHandle {
        self.alloc_i16(v)
    }
    #[inline]
    pub fn i32(&mut self, v: i32) -> ValueHandle {
        self.alloc_i32(v)
    }
    #[inline]
    pub fn i64(&mut self, v: i64) -> ValueHandle {
        self.alloc_i64(v)
    }
    #[inline]
    pub fn i128(&mut self, v: i128) -> ValueHandle {
        self.alloc_i128(v)
    }
    #[inline]
    pub fn u8(&mut self, v: u8) -> ValueHandle {
        self.alloc_u8(v)
    }
    #[inline]
    pub fn u16(&mut self, v: u16) -> ValueHandle {
        self.alloc_u16(v)
    }
    #[inline]
    pub fn u32(&mut self, v: u32) -> ValueHandle {
        self.alloc_u32(v)
    }
    #[inline]
    pub fn u64(&mut self, v: u64) -> ValueHandle {
        self.alloc_u64(v)
    }
    #[inline]
    pub fn u128(&mut self, v: u128) -> ValueHandle {
        self.alloc_u128(v)
    }
    #[inline]
    pub fn isize(&mut self, v: isize) -> ValueHandle {
        self.alloc_isize(v)
    }
    #[inline]
    pub fn usize(&mut self, v: usize) -> ValueHandle {
        self.alloc_usize(v)
    }
    #[inline]
    pub fn f16(&mut self, v: F16) -> ValueHandle {
        self.alloc_f16(v.0)
    }
    #[inline]
    pub fn f32(&mut self, v: f32) -> ValueHandle {
        self.alloc_f32(v)
    }
    #[inline]
    pub fn f64(&mut self, v: f64) -> ValueHandle {
        self.alloc_f64(v)
    }
    #[inline]
    pub fn f128(&mut self, v: F128) -> ValueHandle {
        self.alloc_f128(v)
    }
    #[inline]
    pub fn char(&mut self, c: Char) -> ValueHandle {
        self.alloc_char(c.codepoint)
    }
    #[inline]
    pub fn from_rust_char(&mut self, c: char) -> ValueHandle {
        self.alloc_char(c as u32)
    }

    // ---- 堆对象便捷构造器 ----
    pub fn str(&mut self, s: impl Into<String>) -> ValueHandle {
        self.alloc_ref(HeapObj::Str(GlueStr::new(s)))
    }
    pub fn str_from(&mut self, s: &str) -> ValueHandle {
        self.alloc_ref(HeapObj::Str(GlueStr::from_rust_str(s)))
    }
    pub fn from_glue_str(&mut self, s: GlueStr) -> ValueHandle {
        self.alloc_ref(HeapObj::Str(s))
    }
    pub fn heap(&mut self, obj: HeapObj) -> ValueHandle {
        self.alloc_ref(obj)
    }
    pub fn from_ref(&mut self, r: HeapRef) -> ValueHandle {
        self.alloc_ref_rc(r)
    }
    pub fn array(&mut self, elements: Vec<ValueHandle>) -> ValueHandle {
        self.alloc_ref(HeapObj::Array(ArrayValue::new(elements)))
    }
    pub fn array_fixed(&mut self, elements: Vec<ValueHandle>, size: u64) -> ValueHandle {
        self.alloc_ref(HeapObj::Array(ArrayValue::new_fixed(elements, size)))
    }
    pub fn record(
        &mut self,
        type_name: impl Into<String>,
        fields: Vec<ValueHandle>,
        field_names: Vec<Option<String>>,
    ) -> ValueHandle {
        self.alloc_ref(HeapObj::Record(RecordValue::new(
            type_name.into(),
            fields,
            field_names,
        )))
    }
    pub fn adt(
        &mut self,
        type_name: impl Into<String>,
        constructor: impl Into<String>,
        fields: Vec<AdtField>,
    ) -> ValueHandle {
        self.alloc_ref(HeapObj::Adt(AdtValue::new(
            type_name.into(),
            constructor.into(),
            fields,
        )))
    }
    pub fn newtype(&mut self, type_name: impl Into<String>, inner: ValueHandle) -> ValueHandle {
        self.alloc_ref(HeapObj::Newtype(NewtypeValue {
            type_name: type_name.into(),
            inner,
        }))
    }
    pub fn cell(&mut self, val: ValueHandle) -> ValueHandle {
        self.alloc_ref(HeapObj::Cell(Cell::new(val)))
    }
    pub fn range(&mut self, start: i64, end: i64, inclusive: bool) -> ValueHandle {
        self.alloc_ref(HeapObj::Range(Range::new(start, end, inclusive)))
    }
    pub fn closure(&mut self, c: Closure) -> ValueHandle {
        self.alloc_ref(HeapObj::Closure(c))
    }
    pub fn partial(&mut self, p: PartialApplication) -> ValueHandle {
        self.alloc_ref(HeapObj::Partial(p))
    }
    pub fn builtin(&mut self, fn_ptr: BuiltinFn, name: impl Into<String>) -> ValueHandle {
        self.alloc_ref(HeapObj::Builtin(Builtin {
            fn_ptr,
            name: name.into(),
        }))
    }
    pub fn trait_val(&mut self, t: TraitValue) -> ValueHandle {
        self.alloc_ref(HeapObj::TraitVal(t))
    }
    pub fn lazy(&mut self, l: LazyValue) -> ValueHandle {
        self.alloc_ref(HeapObj::LazyVal(l))
    }
    pub fn error_val(
        &mut self,
        type_name: impl Into<String>,
        message: impl Into<String>,
        is_error_subtype: bool,
    ) -> ValueHandle {
        self.alloc_ref(HeapObj::ErrorVal(ErrorValue {
            type_name: type_name.into(),
            message: message.into(),
            is_error_subtype,
        }))
    }
    pub fn throw_ok(&mut self, val: ValueHandle) -> ValueHandle {
        self.alloc_ref(HeapObj::ThrowVal(ThrowValue {
            payload: ThrowPayload::Ok(val),
        }))
    }
    pub fn throw_err(&mut self, record: Rc<RecordValue>) -> ValueHandle {
        self.alloc_ref(HeapObj::ThrowVal(ThrowValue {
            payload: ThrowPayload::Err(record),
        }))
    }
    pub fn array_iter(&mut self, array: Rc<Vec<ValueHandle>>) -> ValueHandle {
        self.alloc_ref(HeapObj::ArrayIter(ArrayIterator::new(array)))
    }
    pub fn string_iter(&mut self, s: Rc<str>) -> ValueHandle {
        self.alloc_ref(HeapObj::StringIter(StringIterator::new(s)))
    }
    pub fn range_iter(&mut self, start: i64, end: i64, inclusive: bool) -> ValueHandle {
        self.alloc_ref(HeapObj::RangeIter(RangeIterator::new(start, end, inclusive)))
    }
    pub fn atomic(&mut self, val: ValueHandle) -> ValueHandle {
        self.alloc_ref(HeapObj::AtomicVal(AtomicValue::new(val)))
    }
    pub fn async_handle(&mut self) -> ValueHandle {
        self.alloc_ref(HeapObj::AsyncVal(AsyncHandle::new()))
    }
    pub fn channel(&mut self, capacity: usize) -> ValueHandle {
        self.alloc_ref(HeapObj::ChannelVal(ChannelValue::new(capacity)))
    }
    pub fn sender(&mut self, channel: Rc<ChannelValue>) -> ValueHandle {
        self.alloc_ref(HeapObj::SenderVal(SenderValue { channel }))
    }
    pub fn receiver(&mut self, channel: Rc<ChannelValue>) -> ValueHandle {
        self.alloc_ref(HeapObj::ReceiverVal(ReceiverValue { channel }))
    }

    // ---- 格式化包装器 ----
    pub fn display(&self, h: ValueHandle) -> ValueDisplay<'_> {
        ValueDisplay { arena: self, handle: h }
    }
    pub fn debug(&self, h: ValueHandle) -> ValueDebug<'_> {
        ValueDebug { arena: self, handle: h }
    }

    // ---- 按值哈希 ----
    pub fn hash_value<H: Hasher>(&self, h: ValueHandle, state: &mut H) {
        match h.tag() {
            ValueTag::Null => 0u8.hash(state),
            ValueTag::Void => 1u8.hash(state),
            ValueTag::Bool => {
                2u8.hash(state);
                self.get_bool(h).hash(state)
            }
            ValueTag::Char => {
                3u8.hash(state);
                self.get_char(h).hash(state)
            }
            ValueTag::I8 => {
                4u8.hash(state);
                self.get_i8(h).hash(state)
            }
            ValueTag::I16 => {
                5u8.hash(state);
                self.get_i16(h).hash(state)
            }
            ValueTag::I32 => {
                6u8.hash(state);
                self.get_i32(h).hash(state)
            }
            ValueTag::I64 => {
                7u8.hash(state);
                self.get_i64(h).hash(state)
            }
            ValueTag::I128 => {
                8u8.hash(state);
                self.get_i128(h).hash(state)
            }
            ValueTag::U8 => {
                9u8.hash(state);
                self.get_u8(h).hash(state)
            }
            ValueTag::U16 => {
                10u8.hash(state);
                self.get_u16(h).hash(state)
            }
            ValueTag::U32 => {
                11u8.hash(state);
                self.get_u32(h).hash(state)
            }
            ValueTag::U64 => {
                12u8.hash(state);
                self.get_u64(h).hash(state)
            }
            ValueTag::U128 => {
                13u8.hash(state);
                self.get_u128(h).hash(state)
            }
            ValueTag::Isize => {
                14u8.hash(state);
                self.get_isize(h).hash(state)
            }
            ValueTag::Usize => {
                15u8.hash(state);
                self.get_usize(h).hash(state)
            }
            ValueTag::F16 => {
                16u8.hash(state);
                self.get_f16(h).hash(state)
            }
            ValueTag::F32 => {
                17u8.hash(state);
                self.get_f32(h).to_bits().hash(state)
            }
            ValueTag::F64 => {
                18u8.hash(state);
                self.get_f64(h).to_bits().hash(state)
            }
            ValueTag::F128 => {
                19u8.hash(state);
                self.get_f128(h).hash(state)
            }
            ValueTag::Ref => {
                20u8.hash(state);
                self.get_ref(h).hash(state);
            }
        }
    }
}
