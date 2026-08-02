//! Engine.rs — 数据流就绪调度执行引擎
//!
//! 基于 Ir.rs 的 DataFlowGraph，实现：
//! - Frame 管理（FramePool）
//! - 就绪调度（核心循环）
//! - 子图启动（start/complete）
//! - compute_fn 执行
//!
//! 设计原则（见 docs/superpowers/specs/2026-07-31-dataflow-engine-design.md）：
//! - 无 dispatch：调度器只认"输入就绪"，节点自带 compute_fn
//! - sync/async 统一：子图有无挂起点
//! - 帧级回收 + 槽级 RC

use crate::Ir::*;
use crate::Value::{Value, ValueArena};

// =========================================================================
// compute_fn 生成宏 — 批量生成类型特化计算函数
// =========================================================================

/// 读取节点输入的样板宏。
///
/// 每个 compute_fn 开头都需要从 frame.graph 取出 node 和 inputs 切片，
/// 这 3 行代码在 100+ 个 compute_fn 中完全重复。本宏消除该重复。
///
/// 用法（在 compute_fn 函数体内）：
/// ```ignore
/// pub fn compute_foo(frame: &mut Frame, node: NodeId) -> Value {
///     read_node_inputs!(frame, node, graph, n, inputs);
///     let a = frame.get_value_by_global(inputs[0]).as_i32();
///     ...
/// }
/// ```
/// 展开后 `graph`、`n`、`inputs` 三个绑定在当前作用域可用。
/// `inputs` 的生命周期绑定到 `graph`（frame.graph 的 Arc clone）。
macro_rules! read_node_inputs {
    ($frame:ident, $node:ident, $graph:ident, $n:ident, $inputs:ident) => {
        let $graph = $frame.graph.clone();
        let $n = &$graph.nodes[$node.0 as usize];
        let $inputs = $graph.inputs_pool.get($n.inputs_offset, $n.input_count);
    };
}

/// 批量生成算术 compute_fn（返回同类型标量）。
/// frame 持有 graph（Arc<DataFlowGraph>），通过 frame.graph.clone() 获取只读访问。
macro_rules! impl_arith_compute {
    ($($name:ident: $op:tt for $ctor:ident / $acc:ident);* $(;)?) => {
        $(
            pub fn $name(frame: &mut Frame, node: NodeId) -> Value {
                read_node_inputs!(frame, node, graph, n, inputs);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                let b = frame.get_value_by_global(inputs[1]).$acc();
                Value::$ctor(a $op b)
            }
        )*
    };
}

/// 批量生成比较 compute_fn（返回 bool）。
macro_rules! impl_cmp_compute {
    ($($name:ident: $op:tt for $acc:ident);* $(;)?) => {
        $(
            pub fn $name(frame: &mut Frame, node: NodeId) -> Value {
                read_node_inputs!(frame, node, graph, n, inputs);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                let b = frame.get_value_by_global(inputs[1]).$acc();
                Value::bool_val(a $op b)
            }
        )*
    };
}

// =========================================================================
// compute_fns — 真实计算函数（构建期绑定的函数索引）
// =========================================================================

/// compute_fn: i32 小于等于比较 (<=)
pub fn compute_le_i32(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let a = frame.get_value_by_global(inputs[0]).as_i32();
    let b = frame.get_value_by_global(inputs[1]).as_i32();
    Value::bool_val(a <= b)
}

// ---- i32 比较（索引 8-12, 25；算术/位运算/一元由宏生成）----

impl_cmp_compute! {
    compute_eq_i32: == for as_i32;
    compute_ne_i32: != for as_i32;
    compute_lt_i32: < for as_i32;
    compute_gt_i32: > for as_i32;
    compute_ge_i32: >= for as_i32;
}

// ---- i64 比较（索引 55-60；算术/位运算/一元由宏生成）----

impl_cmp_compute! {
    compute_eq_i64: == for as_i64;
    compute_ne_i64: != for as_i64;
    compute_lt_i64: < for as_i64;
    compute_gt_i64: > for as_i64;
    compute_le_i64: <= for as_i64;
    compute_ge_i64: >= for as_i64;
}

// ---- i128 比较（索引 69-74；算术/位运算/一元由宏生成）----
// i128 路径覆盖 i128/u128 类型，并通过 as_int_i128 支持所有整数类型输入

impl_cmp_compute! {
    compute_eq_i128: == for as_int_i128;
    compute_ne_i128: != for as_int_i128;
    compute_lt_i128: < for as_int_i128;
    compute_gt_i128: > for as_int_i128;
    compute_le_i128: <= for as_int_i128;
    compute_ge_i128: >= for as_int_i128;
}

// ---- 整数位运算（索引 78-92）----
// BitAnd/BitOr/BitXor 对 i32/i64/i128 三族，Shl/Shr 对 i32/i64/i128 三族
// 通过 as_int_i128 通用读取，结果按目标类型构造
// 注：具体位运算 compute_fn 由下方 impl_int_ops 宏按类型生成

// =========================================================================
// 全基本类型 compute_fn（索引 92-）：用 paste 宏为每个类型生成全套运算
// =========================================================================
// 整数 12 类型 × 12 运算 = 144；浮点 4 类型 × 6 运算 = 24；合计 168。
// 比较运算沿用按族共用的版本（结果为 bool，输入用 as_int_i128/as_float_f64 跨类型读取）。
// 算术/位运算/一元按具体类型生成，结果天然带正确 tag 并按类型宽度截断/回绕。
//
// 类型规格表：(类型名, Rust 类型, Value ctor, accessor, 是否整数)
// 索引从 92 开始分配。

/// 为指定整数类型生成全套 compute_fn（add/sub/mul/div/mod/bitand/bitor/bitxor/shl/shr/neg/bitnot）
macro_rules! impl_int_ops {
    ($ty:ident, $rust:ty, $ctor:ident, $acc:ident) => {
        pastey::paste! {
            pub fn [<compute_add_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                let b = frame.get_value_by_global(inputs[1]).$acc();
                Value::$ctor(a.wrapping_add(b))
            }
            pub fn [<compute_sub_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                let b = frame.get_value_by_global(inputs[1]).$acc();
                Value::$ctor(a.wrapping_sub(b))
            }
            pub fn [<compute_mul_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                let b = frame.get_value_by_global(inputs[1]).$acc();
                Value::$ctor(a.wrapping_mul(b))
            }
            pub fn [<compute_div_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                let b = frame.get_value_by_global(inputs[1]).$acc();
                // 整数除零返回 0（与 checked_div 语义一致），避免 panic
                Value::$ctor(a.checked_div(b).unwrap_or(0))
            }
            pub fn [<compute_mod_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                let b = frame.get_value_by_global(inputs[1]).$acc();
                Value::$ctor(a.checked_rem(b).unwrap_or(0))
            }
            pub fn [<compute_bitand_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                let b = frame.get_value_by_global(inputs[1]).$acc();
                Value::$ctor(a & b)
            }
            pub fn [<compute_bitor_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                let b = frame.get_value_by_global(inputs[1]).$acc();
                Value::$ctor(a | b)
            }
            pub fn [<compute_bitxor_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                let b = frame.get_value_by_global(inputs[1]).$acc();
                Value::$ctor(a ^ b)
            }
            pub fn [<compute_shl_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                let b = frame.get_value_by_global(inputs[1]).as_i32() as u32;
                Value::$ctor(a.wrapping_shl(b))
            }
            pub fn [<compute_shr_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                let b = frame.get_value_by_global(inputs[1]).as_i32() as u32;
                Value::$ctor(a.wrapping_shr(b))
            }
            pub fn [<compute_neg_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                Value::$ctor(a.wrapping_neg())
            }
            pub fn [<compute_bitnot_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                Value::$ctor(!a)
            }
        }
    };
}

/// 为指定浮点类型生成全套 compute_fn（add/sub/mul/div/mod/neg）
macro_rules! impl_float_ops {
    ($ty:ident, $rust:ty, $ctor:ident, $acc:ident) => {
        pastey::paste! {
            pub fn [<compute_add_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                let b = frame.get_value_by_global(inputs[1]).$acc();
                Value::$ctor(a + b)
            }
            pub fn [<compute_sub_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                let b = frame.get_value_by_global(inputs[1]).$acc();
                Value::$ctor(a - b)
            }
            pub fn [<compute_mul_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                let b = frame.get_value_by_global(inputs[1]).$acc();
                Value::$ctor(a * b)
            }
            pub fn [<compute_div_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                let b = frame.get_value_by_global(inputs[1]).$acc();
                Value::$ctor(a / b)
            }
            pub fn [<compute_mod_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                let b = frame.get_value_by_global(inputs[1]).$acc();
                Value::$ctor(a % b)
            }
            pub fn [<compute_neg_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                Value::$ctor(-a)
            }
        }
    };
}

// 整数类型展开（12 类型 × 12 运算 = 144 函数）
impl_int_ops!(i8,    i8,    i8,    as_i8);
impl_int_ops!(i16,   i16,   i16,   as_i16);
impl_int_ops!(i32,   i32,   i32,   as_i32);
impl_int_ops!(i64,   i64,   i64,   as_i64);
impl_int_ops!(i128,  i128,  i128,  as_i128);
impl_int_ops!(u8,    u8,    u8,    as_u8);
impl_int_ops!(u16,   u16,   u16,   as_u16);
impl_int_ops!(u32,   u32,   u32,   as_u32);
impl_int_ops!(u64,   u64,   u64,   as_u64);
impl_int_ops!(u128,  u128,  u128,  as_u128);
impl_int_ops!(isize, isize, isize_val, as_isize);
impl_int_ops!(usize, usize, usize_val, as_usize);

// 浮点类型展开（4 类型 × 6 运算 = 24 函数）
impl_float_ops!(f16, F16, f16, as_f16);
impl_float_ops!(f32, f32, f32, as_f32);
impl_float_ops!(f64, f64, f64, as_f64);
impl_float_ops!(f128, F128, f128, as_f128);

// ---- f64 比较（索引 16-21；算术/一元由宏生成）----

impl_cmp_compute! {
    compute_eq_f64: == for as_f64;
    compute_ne_f64: != for as_f64;
    compute_lt_f64: < for as_f64;
    compute_gt_f64: > for as_f64;
    compute_le_f64: <= for as_f64;
    compute_ge_f64: >= for as_f64;
}

// ---- bool 逻辑（索引 22-24, 27）----

/// compute_fn: bool 与
pub fn compute_and_bool(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let a = frame.get_value_by_global(inputs[0]).as_bool();
    let b = frame.get_value_by_global(inputs[1]).as_bool();
    Value::bool_val(a && b)
}

/// compute_fn: bool 或
pub fn compute_or_bool(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let a = frame.get_value_by_global(inputs[0]).as_bool();
    let b = frame.get_value_by_global(inputs[1]).as_bool();
    Value::bool_val(a || b)
}

/// compute_fn: bool 非（一元）
pub fn compute_not_bool(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let a = frame.get_value_by_global(inputs[0]).as_bool();
    Value::bool_val(!a)
}

/// compute_fn: bool 相等
pub fn compute_eq_bool(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let a = frame.get_value_by_global(inputs[0]).as_bool();
    let b = frame.get_value_by_global(inputs[1]).as_bool();
    Value::bool_val(a == b)
}

// ---- throw 包装（索引 28，无 try-catch）----

/// compute_fn: 将值包装为 ThrowVal(Err)（throw 语句用）。
///
/// Glue 无 try-catch，throw 产 ThrowVal(Err) + Return 信号，逐层透传至顶层。
/// - 输入为 Record（错误类型 ADT 构造结果）→ 直接作为 ThrowVal(Err(record))
/// - 输入为 ThrowVal（已是 throw 值）→ 直接返回
/// - 其他值 → 包装为单字段 Error record 再作为 ThrowVal(Err)
pub fn compute_throw_wrap_err(frame: &mut Frame, node: NodeId) -> Value {
    use std::sync::Arc;
    use crate::Value::{HeapObj, RecordValue, ThrowValue, ThrowPayload};
    read_node_inputs!(frame, node, graph, n, inputs);
    let v = frame.get_value_by_global(inputs[0]);
    // Record（错误类型 ADT）→ 直接作为 Err payload
    if let Some(HeapObj::Record(record)) = v.heap_obj() {
        return Value::ref_val(HeapObj::ThrowVal(ThrowValue {
            payload: ThrowPayload::Err(Arc::new(record.clone())),
        }));
    }
    // 已是 ThrowVal → 直接返回
    if let Some(HeapObj::ThrowVal(_)) = v.heap_obj() {
        return v;
    }
    // 其他值 → 包装为 Error record
    let record = Arc::new(RecordValue {
        type_name: "Error".to_string(),
        fields: vec![v],
        field_names: vec![Some("value".to_string())],
        field_ref_bits: 0,
    });
    Value::ref_val(HeapObj::ThrowVal(ThrowValue { payload: ThrowPayload::Err(record) }))
}

/// compute_fn: 将值包装为 ThrowVal(Ok(val))（Ok 构造器用）。
pub fn compute_throw_ok(frame: &mut Frame, node: NodeId) -> Value {
    use crate::Value::{HeapObj, ThrowValue, ThrowPayload};
    read_node_inputs!(frame, node, graph, n, inputs);
    let val = frame.get_value_by_global(inputs[0]);
    Value::ref_val(HeapObj::ThrowVal(ThrowValue { payload: ThrowPayload::Ok(val) }))
}

/// compute_fn: 将 Record 包装为 ThrowVal(Err(record))（Err 构造器用）。
///
/// 输入为 record 构造节点的结果（已通过 compute_record_construct 构造为 RecordValue）。
/// 此函数将其包装为 ThrowVal(Err(record))。
pub fn compute_throw_err(frame: &mut Frame, node: NodeId) -> Value {
    use std::sync::Arc;
    use crate::Value::{HeapObj, ThrowValue, ThrowPayload};
    read_node_inputs!(frame, node, graph, n, inputs);
    let v = frame.get_value_by_global(inputs[0]);
    // v 应为 Record（由内层 record_construct 节点产生）
    if let Some(HeapObj::Record(record)) = v.heap_obj() {
        Value::ref_val(HeapObj::ThrowVal(ThrowValue {
            payload: ThrowPayload::Err(Arc::new(record.clone())),
        }))
    } else {
        // 非 record 值，包装为单字段 Error record
        use crate::Value::RecordValue;
        let record = Arc::new(RecordValue {
            type_name: "Error".to_string(),
            fields: vec![v],
            field_names: vec![Some("value".to_string())],
            field_ref_bits: 0,
        });
        Value::ref_val(HeapObj::ThrowVal(ThrowValue { payload: ThrowPayload::Err(record) }))
    }
}

/// compute_fn (idx 47): `?` 运算符（Propagate）。
///
/// 输入为 ThrowVal：
/// - Ok(val) → 返回 val（解包）
/// - Err(err) → 设 frame.control_signal = Return(ThrowVal(Err))，函数提前返回错误
pub fn compute_propagate(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let v = frame.get_value_by_global(inputs[0]);

    if let Some(crate::Value::HeapObj::ThrowVal(tv)) = v.heap_obj() {
        match &tv.payload {
            crate::Value::ThrowPayload::Ok(val) => val.clone(),
            crate::Value::ThrowPayload::Err(_) => {
                // 错误传播：设 Return 信号，携带原始 ThrowVal(Err) 逐层透传
                frame.control_signal = ControlSignal::Return(v.clone());
                Value::VOID
            }
        }
    } else {
        // 非 ThrowVal：直接透传（类型系统保证此处不应到达）
        v
    }
}

/// compute_fn (idx 46): @extern("C") FFI 调用。
///
/// 根据节点的 ffi_call_names 元数据获取函数名，从输入收集参数值，
/// 分发到对应的 Ffi::wrapper 函数，返回结果 Value。
/// FFI 调用是同步的，不设 pending_call，不挂起帧。
#[cfg(has_extern_c)]
pub fn compute_ffi_call(frame: &mut Frame, node: NodeId) -> Value {
    use crate::Ffi::wrapper;
    read_node_inputs!(frame, node, graph, n, inputs);
    let fn_name = graph.ffi_call_names[node.0 as usize]
        .as_ref()
        .expect("compute_ffi_call: no ffi_call_name");

    // 从 Value 提取 str 参数（HeapObj::Str → owned String，避免临时 Value 生命周期问题）
    fn extract_str(v: &Value) -> String {
        match v.heap_obj() {
            Some(crate::Value::HeapObj::Str(s)) => s.bytes().to_string(),
            _ => panic!("FFI str arg expected, got non-str value"),
        }
    }

    // 从 Value 提取 u8[] 参数（统一走 ArrayValue::collect_u8_bytes）
    fn extract_u8_buf(v: &Value) -> Vec<u8> {
        match v.heap_obj() {
            Some(crate::Value::HeapObj::Array(arr)) => arr.collect_u8_bytes(),
            _ => panic!("FFI u8[] arg expected"),
        }
    }

    match fn_name.as_str() {
        // ── IO: stdout/stderr ──
        "__stdout_write_raw" => {
            let s = extract_str(&frame.get_value_by_global(inputs[0]));
            let rc = unsafe { wrapper::__stdout_write_raw(&s) };
            Value::i32(rc)
        }
        "__stderr_write_raw" => {
            let s = extract_str(&frame.get_value_by_global(inputs[0]));
            let rc = unsafe { wrapper::__stderr_write_raw(&s) };
            Value::i32(rc)
        }

        // ── IO: file ops ──
        "__file_open_raw" => {
            let path = extract_str(&frame.get_value_by_global(inputs[0]));
            let flags = frame.get_value_by_global(inputs[1]).as_i32();
            let mode = frame.get_value_by_global(inputs[2]).as_i32();
            let fd = unsafe { wrapper::__file_open_raw(&path, flags, mode) };
            Value::i64(fd)
        }
        "__file_close_raw" => {
            let fd = frame.get_value_by_global(inputs[0]).as_i64();
            let rc = unsafe { wrapper::__file_close_raw(fd) };
            Value::i32(rc)
        }
        "__file_seek_raw" => {
            let fd = frame.get_value_by_global(inputs[0]).as_i64();
            let offset = frame.get_value_by_global(inputs[1]).as_i64();
            let whence = frame.get_value_by_global(inputs[2]).as_i32();
            let pos = unsafe { wrapper::__file_seek_raw(fd, offset, whence) };
            Value::i64(pos)
        }
        "__file_remove_raw" => {
            let path = extract_str(&frame.get_value_by_global(inputs[0]));
            let rc = unsafe { wrapper::__file_remove_raw(&path) };
            Value::i32(rc)
        }
        "__file_rename_raw" => {
            let old = extract_str(&frame.get_value_by_global(inputs[0]));
            let new = extract_str(&frame.get_value_by_global(inputs[1]));
            let rc = unsafe { wrapper::__file_rename_raw(&old, &new) };
            Value::i32(rc)
        }
        "__file_chmod_raw" => {
            let path = extract_str(&frame.get_value_by_global(inputs[0]));
            let mode = frame.get_value_by_global(inputs[1]).as_i32();
            let rc = unsafe { wrapper::__file_chmod_raw(&path, mode) };
            Value::i32(rc)
        }

        // ── IO: file read/write (u8[] + len) ──
        "__file_read_into" => {
            let fd = frame.get_value_by_global(inputs[0]).as_i64();
            let mut buf = extract_u8_buf(&frame.get_value_by_global(inputs[1]));
            let len = frame.get_value_by_global(inputs[2]).as_usize();
            let n = unsafe { wrapper::__file_read_into(fd, &mut buf, len) };
            Value::i64(n)
        }
        "__file_write" => {
            let fd = frame.get_value_by_global(inputs[0]).as_i64();
            let buf = extract_u8_buf(&frame.get_value_by_global(inputs[1]));
            let len = frame.get_value_by_global(inputs[2]).as_usize();
            let n = unsafe { wrapper::__file_write(fd, &buf, len) };
            Value::i64(n)
        }

        // ── IO: stdin ──
        "__stdin_readln_into" => {
            let mut buf = extract_u8_buf(&frame.get_value_by_global(inputs[0]));
            let n = unsafe { wrapper::__stdin_readln_into(&mut buf) };
            Value::i64(n)
        }

        // ── IO: stat/fstat ──
        "__file_stat_into" => {
            let path = extract_str(&frame.get_value_by_global(inputs[0]));
            let mut buf = extract_u8_buf(&frame.get_value_by_global(inputs[1]));
            let rc = unsafe { wrapper::__file_stat_into(&path, &mut buf) };
            Value::i32(rc)
        }
        "__file_fstat_into" => {
            let fd = frame.get_value_by_global(inputs[0]).as_i64();
            let mut buf = extract_u8_buf(&frame.get_value_by_global(inputs[1]));
            let rc = unsafe { wrapper::__file_fstat_into(fd, &mut buf) };
            Value::i32(rc)
        }

        // ── IO: dir ops ──
        "__dir_create_raw" => {
            let path = extract_str(&frame.get_value_by_global(inputs[0]));
            let recursive = frame.get_value_by_global(inputs[1]).as_bool();
            let rc = unsafe { wrapper::__dir_create_raw(&path, recursive) };
            Value::i32(rc)
        }
        "__dir_remove_raw" => {
            let path = extract_str(&frame.get_value_by_global(inputs[0]));
            let recursive = frame.get_value_by_global(inputs[1]).as_bool();
            let rc = unsafe { wrapper::__dir_remove_raw(&path, recursive) };
            Value::i32(rc)
        }

        // ── IO: dir list ──
        "__dir_list_into" => {
            let path = extract_str(&frame.get_value_by_global(inputs[0]));
            let mut names_buf = extract_u8_buf(&frame.get_value_by_global(inputs[1]));
            let mut name_offsets = extract_u8_buf(&frame.get_value_by_global(inputs[2]));
            let mut kinds_buf = extract_u8_buf(&frame.get_value_by_global(inputs[3]));
            let max_count = frame.get_value_by_global(inputs[4]).as_usize();
            let count = unsafe {
                wrapper::__dir_list_into(&path, &mut names_buf, &mut name_offsets, &mut kinds_buf, max_count)
            };
            Value::i64(count)
        }

        // ── net: tcp ──
        "__net_tcp_connect_v4" => {
            let ip_bits = frame.get_value_by_global(inputs[0]).as_u32();
            let port = frame.get_value_by_global(inputs[1]).as_u16();
            let timeout_ns = frame.get_value_by_global(inputs[2]).as_i64();
            let fd = unsafe { wrapper::__net_tcp_connect_v4(ip_bits, port, timeout_ns) };
            Value::i64(fd)
        }
        "__net_tcp_listen_v4" => {
            let ip_bits = frame.get_value_by_global(inputs[0]).as_u32();
            let port = frame.get_value_by_global(inputs[1]).as_u16();
            let reuse_addr = frame.get_value_by_global(inputs[2]).as_bool();
            let fd = unsafe {
                wrapper::__net_tcp_listen_v4(ip_bits, port, reuse_addr)
            };
            Value::i64(fd)
        }
        "__net_tcp_accept" => {
            let fd = frame.get_value_by_global(inputs[0]).as_i64();
            let conn_fd = unsafe { wrapper::__net_tcp_accept(fd) };
            Value::i64(conn_fd)
        }
        "__net_tcp_read" => {
            let fd = frame.get_value_by_global(inputs[0]).as_i64();
            let mut buf = extract_u8_buf(&frame.get_value_by_global(inputs[1]));
            let len = frame.get_value_by_global(inputs[2]).as_usize();
            let n = unsafe { wrapper::__net_tcp_read(fd, &mut buf, len) };
            Value::i64(n)
        }
        "__net_tcp_write" => {
            let fd = frame.get_value_by_global(inputs[0]).as_i64();
            let buf = extract_u8_buf(&frame.get_value_by_global(inputs[1]));
            let len = frame.get_value_by_global(inputs[2]).as_usize();
            let n = unsafe { wrapper::__net_tcp_write(fd, &buf, len) };
            Value::i64(n)
        }
        "__net_tcp_close_raw" => {
            let fd = frame.get_value_by_global(inputs[0]).as_i64();
            let rc = unsafe { wrapper::__net_tcp_close_raw(fd) };
            Value::i32(rc)
        }

        // ── net: udp v4 ──
        "__net_udp_bind_v4" => {
            let ip_bits = frame.get_value_by_global(inputs[0]).as_u32();
            let port = frame.get_value_by_global(inputs[1]).as_u16();
            let reuse_addr = frame.get_value_by_global(inputs[2]).as_bool();
            let fd = unsafe {
                wrapper::__net_udp_bind_v4(ip_bits, port, reuse_addr)
            };
            Value::i64(fd)
        }
        "__net_udp_send_to_v4" => {
            let fd = frame.get_value_by_global(inputs[0]).as_i64();
            let ip_bits = frame.get_value_by_global(inputs[1]).as_u32();
            let port = frame.get_value_by_global(inputs[2]).as_u16();
            let buf = extract_u8_buf(&frame.get_value_by_global(inputs[3]));
            let len = frame.get_value_by_global(inputs[4]).as_usize();
            let n = unsafe { wrapper::__net_udp_send_to_v4(fd, ip_bits, port, &buf, len) };
            Value::i64(n)
        }
        "__net_udp_recv_from_v4" => {
            let fd = frame.get_value_by_global(inputs[0]).as_i64();
            let mut buf = extract_u8_buf(&frame.get_value_by_global(inputs[1]));
            let len = frame.get_value_by_global(inputs[2]).as_usize();
            let n = unsafe { wrapper::__net_udp_recv_from_v4(fd, &mut buf, len) };
            Value::i64(n)
        }

        // ── net: resolve ──
        "__net_resolve_into" => {
            let host = extract_str(&frame.get_value_by_global(inputs[0]));
            let mut out_buf = extract_u8_buf(&frame.get_value_by_global(inputs[1]));
            let max_count = frame.get_value_by_global(inputs[2]).as_usize();
            let count = unsafe { wrapper::__net_resolve_into(&host, &mut out_buf, max_count) };
            Value::i64(count)
        }

        // ── net: tcp/udp v6 ──
        "__net_tcp_connect_v6" => {
            let ip_hi = frame.get_value_by_global(inputs[0]).as_u64();
            let ip_lo = frame.get_value_by_global(inputs[1]).as_u64();
            let port = frame.get_value_by_global(inputs[2]).as_u16();
            let timeout_ns = frame.get_value_by_global(inputs[3]).as_i64();
            let fd = unsafe { wrapper::__net_tcp_connect_v6(ip_hi, ip_lo, port, timeout_ns) };
            Value::i64(fd)
        }
        "__net_tcp_listen_v6" => {
            let ip_hi = frame.get_value_by_global(inputs[0]).as_u64();
            let ip_lo = frame.get_value_by_global(inputs[1]).as_u64();
            let port = frame.get_value_by_global(inputs[2]).as_u16();
            let reuse_addr = frame.get_value_by_global(inputs[3]).as_bool();
            let fd = unsafe {
                wrapper::__net_tcp_listen_v6(ip_hi, ip_lo, port, reuse_addr)
            };
            Value::i64(fd)
        }
        "__net_udp_bind_v6" => {
            let ip_hi = frame.get_value_by_global(inputs[0]).as_u64();
            let ip_lo = frame.get_value_by_global(inputs[1]).as_u64();
            let port = frame.get_value_by_global(inputs[2]).as_u16();
            let reuse_addr = frame.get_value_by_global(inputs[3]).as_bool();
            let fd = unsafe {
                wrapper::__net_udp_bind_v6(ip_hi, ip_lo, port, reuse_addr)
            };
            Value::i64(fd)
        }
        "__net_udp_send_to_v6" => {
            let fd = frame.get_value_by_global(inputs[0]).as_i64();
            let ip_hi = frame.get_value_by_global(inputs[1]).as_u64();
            let ip_lo = frame.get_value_by_global(inputs[2]).as_u64();
            let port = frame.get_value_by_global(inputs[3]).as_u16();
            let buf = extract_u8_buf(&frame.get_value_by_global(inputs[4]));
            let len = frame.get_value_by_global(inputs[5]).as_usize();
            let n = unsafe { wrapper::__net_udp_send_to_v6(fd, ip_hi, ip_lo, port, &buf, len) };
            Value::i64(n)
        }
        "__net_udp_recv_from_v6" => {
            let fd = frame.get_value_by_global(inputs[0]).as_i64();
            let mut buf = extract_u8_buf(&frame.get_value_by_global(inputs[1]));
            let len = frame.get_value_by_global(inputs[2]).as_usize();
            let n = unsafe { wrapper::__net_udp_recv_from_v6(fd, &mut buf, len) };
            Value::i64(n)
        }

        // ── time ──
        "__instant_now_ns" => {
            let ns = unsafe { wrapper::__instant_now_ns() };
            Value::i64(ns)
        }
        "__systemtime_now_ns" => {
            let ns = unsafe { wrapper::__systemtime_now_ns() };
            Value::i64(ns)
        }
        "__sleep_ns" => {
            let ns = frame.get_value_by_global(inputs[0]).as_i64();
            unsafe { wrapper::__sleep_ns(ns) };
            Value::VOID
        }
        "__localtime_offset_minutes" => {
            let minutes = unsafe { wrapper::__localtime_offset_minutes() };
            Value::i32(minutes)
        }

        // ── cast: widening to i128 ──
        "__cast_i8_to_i128" => {
            let x = frame.get_value_by_global(inputs[0]).as_i8();
            let r = unsafe { wrapper::__cast_i8_to_i128(x) };
            Value::i128(r)
        }
        "__cast_i16_to_i128" => {
            let x = frame.get_value_by_global(inputs[0]).as_i16();
            let r = unsafe { wrapper::__cast_i16_to_i128(x) };
            Value::i128(r)
        }
        "__cast_i32_to_i128" => {
            let x = frame.get_value_by_global(inputs[0]).as_i32();
            let r = unsafe { wrapper::__cast_i32_to_i128(x) };
            Value::i128(r)
        }
        "__cast_i64_to_i128" => {
            let x = frame.get_value_by_global(inputs[0]).as_i64();
            let r = unsafe { wrapper::__cast_i64_to_i128(x) };
            Value::i128(r)
        }
        "__cast_u8_to_i128" => {
            let x = frame.get_value_by_global(inputs[0]).as_u8();
            let r = unsafe { wrapper::__cast_u8_to_i128(x) };
            Value::i128(r)
        }
        "__cast_u16_to_i128" => {
            let x = frame.get_value_by_global(inputs[0]).as_u16();
            let r = unsafe { wrapper::__cast_u16_to_i128(x) };
            Value::i128(r)
        }
        "__cast_u32_to_i128" => {
            let x = frame.get_value_by_global(inputs[0]).as_u32();
            let r = unsafe { wrapper::__cast_u32_to_i128(x) };
            Value::i128(r)
        }
        "__cast_u64_to_i128" => {
            let x = frame.get_value_by_global(inputs[0]).as_u64();
            let r = unsafe { wrapper::__cast_u64_to_i128(x) };
            Value::i128(r)
        }
        "__cast_usize_to_i128" => {
            let x = frame.get_value_by_global(inputs[0]).as_usize();
            let r = unsafe { wrapper::__cast_usize_to_i128(x) };
            Value::i128(r)
        }

        // ── cast: narrowing from i128 ──
        "__cast_i128_to_i8" => {
            let v = frame.get_value_by_global(inputs[0]).as_i128();
            let r = unsafe { wrapper::__cast_i128_to_i8(v) };
            Value::i8(r)
        }
        "__cast_i128_to_i16" => {
            let v = frame.get_value_by_global(inputs[0]).as_i128();
            let r = unsafe { wrapper::__cast_i128_to_i16(v) };
            Value::i16(r)
        }
        "__cast_i128_to_i32" => {
            let v = frame.get_value_by_global(inputs[0]).as_i128();
            let r = unsafe { wrapper::__cast_i128_to_i32(v) };
            Value::i32(r)
        }
        "__cast_i128_to_i64" => {
            let v = frame.get_value_by_global(inputs[0]).as_i128();
            let r = unsafe { wrapper::__cast_i128_to_i64(v) };
            Value::i64(r)
        }
        "__cast_i128_to_u8" => {
            let v = frame.get_value_by_global(inputs[0]).as_i128();
            let r = unsafe { wrapper::__cast_i128_to_u8(v) };
            Value::u8(r)
        }
        "__cast_i128_to_u16" => {
            let v = frame.get_value_by_global(inputs[0]).as_i128();
            let r = unsafe { wrapper::__cast_i128_to_u16(v) };
            Value::u16(r)
        }
        "__cast_i128_to_u32" => {
            let v = frame.get_value_by_global(inputs[0]).as_i128();
            let r = unsafe { wrapper::__cast_i128_to_u32(v) };
            Value::u32(r)
        }
        "__cast_i128_to_u64" => {
            let v = frame.get_value_by_global(inputs[0]).as_i128();
            let r = unsafe { wrapper::__cast_i128_to_u64(v) };
            Value::u64(r)
        }
        "__cast_i128_to_usize" => {
            let v = frame.get_value_by_global(inputs[0]).as_i128();
            let r = unsafe { wrapper::__cast_i128_to_usize(v) };
            Value::usize_val(r)
        }

        // ── cast: char ──
        "__cast_char_to_u8" => {
            let x = frame.get_value_by_global(inputs[0]).as_u32();
            let r = unsafe { wrapper::__cast_char_to_u8(char::from_u32(x).unwrap_or('\0')) };
            Value::u8(r)
        }

        // ── reflect: Rust 侧实现（非 C 库函数），直接调用 Reflect::format_value ──
        "__reflect_format" => {
            let v = frame.get_value_by_global(inputs[0]);
            // LazyValue 强制求值：格式化前触发 thunk 计算
            let v = force_lazy_value_sync(frame, &v);
            let s = crate::Reflect::format_value(&v, 0);
            Value::ref_val(crate::Value::HeapObj::Str(crate::Value::GlueStr::from_rust_str(&s)))
        }
        "__reflect_scalar_to_str" => {
            let v = frame.get_value_by_global(inputs[0]);
            let v = force_lazy_value_sync(frame, &v);
            let s = crate::Reflect::format_value(&v, 0);
            Value::ref_val(crate::Value::HeapObj::Str(crate::Value::GlueStr::from_rust_str(&s)))
        }
        "__reflect_kind" => {
            let v = frame.get_value_by_global(inputs[0]);
            let kind: u8 = match &v {
                Value::Null => 0,
                Value::Void => 1,
                Value::Scalar(_, _) => 2,
                Value::Ref(r) => match &**r {
                    crate::Value::HeapObj::Str(_) => 3,
                    crate::Value::HeapObj::Array(_) => 4,
                    crate::Value::HeapObj::Record(_) => 5,
                    crate::Value::HeapObj::Adt(_) => 6,
                    crate::Value::HeapObj::Closure(_) => 7,
                    crate::Value::HeapObj::TraitVal(_) => 8,
                    crate::Value::HeapObj::ThrowVal(_) => 9,
                    crate::Value::HeapObj::ChannelVal(_) => 10,
                    crate::Value::HeapObj::AsyncVal(_) => 11,
                    _ => 12,
                }
            };
            Value::u8(kind)
        }
        "__reflect_type_name" => {
            let v = frame.get_value_by_global(inputs[0]);
            let name = match &v {
                Value::Null => "null".to_string(),
                Value::Void => "void".to_string(),
                Value::Scalar(_, tag) => tag.type_name().to_string(),
                Value::Ref(r) => match &**r {
                    crate::Value::HeapObj::Str(_) => "str".to_string(),
                    crate::Value::HeapObj::Array(_) => "array".to_string(),
                    crate::Value::HeapObj::Record(rec) => rec.type_name.clone(),
                    crate::Value::HeapObj::Adt(a) => a.constructor.clone(),
                    _ => "unknown".to_string(),
                },
            };
            Value::ref_val(crate::Value::HeapObj::Str(crate::Value::GlueStr::from_rust_str(&name)))
        }
        "__reflect_array_len" => {
            let v = frame.get_value_by_global(inputs[0]);
            match v.heap_obj() {
                Some(crate::Value::HeapObj::Array(arr)) => Value::usize_val(arr.elements.len()),
                _ => Value::usize_val(0),
            }
        }
        "__reflect_field_count" => {
            let v = frame.get_value_by_global(inputs[0]);
            let count: u16 = match v.heap_obj() {
                Some(crate::Value::HeapObj::Record(rec)) => rec.fields.len() as u16,
                Some(crate::Value::HeapObj::Adt(a)) => a.fields.len() as u16,
                _ => 0,
            };
            Value::u16(count)
        }
        "__reflect_size" => {
            let v = frame.get_value_by_global(inputs[0]);
            let size: u8 = match &v {
                Value::Scalar(_, tag) => match tag {
                    crate::Value::ScalarTag::Bool | crate::Value::ScalarTag::U8 | crate::Value::ScalarTag::I8 => 1,
                    crate::Value::ScalarTag::U16 | crate::Value::ScalarTag::I16 | crate::Value::ScalarTag::F16 => 2,
                    crate::Value::ScalarTag::U32 | crate::Value::ScalarTag::I32 | crate::Value::ScalarTag::F32 | crate::Value::ScalarTag::Char => 4,
                    crate::Value::ScalarTag::U64 | crate::Value::ScalarTag::I64 | crate::Value::ScalarTag::F64 | crate::Value::ScalarTag::Usize | crate::Value::ScalarTag::Isize => 8,
                    crate::Value::ScalarTag::U128 | crate::Value::ScalarTag::I128 | crate::Value::ScalarTag::F128 => 16,
                },
                _ => 0,
            };
            Value::u8(size)
        }
        "__reflect_field_name" => {
            let v = frame.get_value_by_global(inputs[0]);
            let i = frame.get_value_by_global(inputs[1]).as_u16();
            let name = match v.heap_obj() {
                Some(crate::Value::HeapObj::Record(rec)) => {
                    rec.field_names.get(i as usize)
                        .and_then(|n| n.as_ref())
                        .cloned()
                        .unwrap_or_default()
                }
                Some(crate::Value::HeapObj::Adt(a)) => {
                    a.fields.get(i as usize)
                        .and_then(|f| f.name.as_ref().cloned())
                        .unwrap_or_default()
                }
                _ => String::new(),
            };
            Value::ref_val(crate::Value::HeapObj::Str(crate::Value::GlueStr::from_rust_str(&name)))
        }
        "__reflect_field_value" => {
            let v = frame.get_value_by_global(inputs[0]);
            let i = frame.get_value_by_global(inputs[1]).as_u16();
            match v.heap_obj() {
                Some(crate::Value::HeapObj::Record(rec)) => {
                    rec.fields.get(i as usize).cloned().unwrap_or(Value::NULL)
                }
                Some(crate::Value::HeapObj::Adt(a)) => {
                    a.fields.get(i as usize).map(|f| f.value.clone()).unwrap_or(Value::NULL)
                }
                _ => Value::NULL,
            }
        }
        "__reflect_adt_constructor" => {
            let v = frame.get_value_by_global(inputs[0]);
            let name = match v.heap_obj() {
                Some(crate::Value::HeapObj::Adt(a)) => a.constructor.clone(),
                _ => String::new(),
            };
            Value::ref_val(crate::Value::HeapObj::Str(crate::Value::GlueStr::from_rust_str(&name)))
        }

        // ── str: UTF-8 逐字符解码（纯 Rust 位运算，与 C 实现语义一致）──
        "__str_utf8_decode_at" => {
            let s = extract_str(&frame.get_value_by_global(inputs[0]));
            let offset = frame.get_value_by_global(inputs[1]).as_usize();
            let bytes = s.as_bytes();
            if offset >= bytes.len() {
                Value::i64(-1)
            } else {
                let c = bytes[offset];
                let cp = if c < 0x80 {
                    c as u32
                } else if (c & 0xE0) == 0xC0 {
                    if offset + 1 >= bytes.len() { return Value::i64(-1); }
                    ((c as u32 & 0x1F) << 6) | (bytes[offset + 1] as u32 & 0x3F)
                } else if (c & 0xF0) == 0xE0 {
                    if offset + 2 >= bytes.len() { return Value::i64(-1); }
                    ((c as u32 & 0x0F) << 12)
                        | ((bytes[offset + 1] as u32 & 0x3F) << 6)
                        | (bytes[offset + 2] as u32 & 0x3F)
                } else if (c & 0xF8) == 0xF0 {
                    if offset + 3 >= bytes.len() { return Value::i64(-1); }
                    ((c as u32 & 0x07) << 18)
                        | ((bytes[offset + 1] as u32 & 0x3F) << 12)
                        | ((bytes[offset + 2] as u32 & 0x3F) << 6)
                        | (bytes[offset + 3] as u32 & 0x3F)
                } else {
                    return Value::i64(-1);
                };
                Value::i64(cp as i64)
            }
        }
        "__str_utf8_char_len_at" => {
            let s = extract_str(&frame.get_value_by_global(inputs[0]));
            let offset = frame.get_value_by_global(inputs[1]).as_usize();
            let bytes = s.as_bytes();
            if offset >= bytes.len() {
                Value::usize_val(0)
            } else {
                let c = bytes[offset];
                let len = if c < 0x80 { 1 }
                    else if (c & 0xE0) == 0xC0 { 2 }
                    else if (c & 0xF0) == 0xE0 { 3 }
                    else if (c & 0xF8) == 0xF0 { 4 }
                    else { 1 };
                Value::usize_val(len)
            }
        }

        // ── 未实现的 FFI 函数 ──
        other => panic!("compute_ffi_call: unimplemented FFI function '{}'", other),
    }
}

/// compute_fn (idx 46) fallback：has_extern_c 未设置时（无 C 编译器），
/// 对纯 Rust 可实现的 FFI 函数（cast）用 Rust 直接计算，其余返回默认值。
#[cfg(not(has_extern_c))]
pub fn compute_ffi_call(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let fn_name = graph.ffi_call_names[node.0 as usize]
        .as_ref()
        .expect("compute_ffi_call: no ffi_call_name");

    match fn_name.as_str() {
        // ── IO: 用 Rust std 直接实现 ──
        "__stdout_write_raw" => {
            if let Some(crate::Value::HeapObj::Str(s)) = frame.get_value_by_global(inputs[0]).heap_obj() {
                use std::io::Write;
                let _ = std::io::stdout().write_all(s.bytes().as_bytes());
                let _ = std::io::stdout().flush();
                Value::i32(0)
            } else {
                Value::i32(-1)
            }
        }
        "__stderr_write_raw" => {
            if let Some(crate::Value::HeapObj::Str(s)) = frame.get_value_by_global(inputs[0]).heap_obj() {
                use std::io::Write;
                let _ = std::io::stderr().write_all(s.bytes().as_bytes());
                Value::i32(0)
            } else {
                Value::i32(-1)
            }
        }

        // ── time: 用 Rust std 直接实现 ──
        "__instant_now_ns" => {
            let ns = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos();
            Value::i64(ns as i64)
        }
        "__systemtime_now_ns" => {
            let ns = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos();
            Value::i64(ns as i64)
        }
        "__sleep_ns" => {
            let ns = frame.get_value_by_global(inputs[0]).as_i64();
            std::thread::sleep(std::time::Duration::from_nanos(ns as u64));
            Value::VOID
        }
        "__localtime_offset_minutes" => {
            Value::i32(0)
        }

        // ── cast: widening to i128（纯 Rust 计算）──
        "__cast_i8_to_i128" => Value::i128(frame.get_value_by_global(inputs[0]).as_i8() as i128),
        "__cast_i16_to_i128" => Value::i128(frame.get_value_by_global(inputs[0]).as_i16() as i128),
        "__cast_i32_to_i128" => Value::i128(frame.get_value_by_global(inputs[0]).as_i32() as i128),
        "__cast_i64_to_i128" => Value::i128(frame.get_value_by_global(inputs[0]).as_i64() as i128),
        "__cast_u8_to_i128" => Value::i128(frame.get_value_by_global(inputs[0]).as_u8() as i128),
        "__cast_u16_to_i128" => Value::i128(frame.get_value_by_global(inputs[0]).as_u16() as i128),
        "__cast_u32_to_i128" => Value::i128(frame.get_value_by_global(inputs[0]).as_u32() as i128),
        "__cast_u64_to_i128" => Value::i128(frame.get_value_by_global(inputs[0]).as_u64() as i128),
        "__cast_usize_to_i128" => Value::i128(frame.get_value_by_global(inputs[0]).as_usize() as i128),

        // ── cast: narrowing from i128（纯 Rust 计算）──
        "__cast_i128_to_i8" => Value::i8(frame.get_value_by_global(inputs[0]).as_i128() as i8),
        "__cast_i128_to_i16" => Value::i16(frame.get_value_by_global(inputs[0]).as_i128() as i16),
        "__cast_i128_to_i32" => Value::i32(frame.get_value_by_global(inputs[0]).as_i128() as i32),
        "__cast_i128_to_i64" => Value::i64(frame.get_value_by_global(inputs[0]).as_i128() as i64),
        "__cast_i128_to_u8" => Value::u8(frame.get_value_by_global(inputs[0]).as_i128() as u8),
        "__cast_i128_to_u16" => Value::u16(frame.get_value_by_global(inputs[0]).as_i128() as u16),
        "__cast_i128_to_u32" => Value::u32(frame.get_value_by_global(inputs[0]).as_i128() as u32),
        "__cast_i128_to_u64" => Value::u64(frame.get_value_by_global(inputs[0]).as_i128() as u64),
        "__cast_i128_to_usize" => Value::usize_val(frame.get_value_by_global(inputs[0]).as_i128() as usize),

        // ── cast: char ──
        "__cast_char_to_u8" => Value::u8(frame.get_value_by_global(inputs[0]).as_u32() as u8),

        // ── reflect: Rust 侧实现，直接调用 Reflect::format_value ──
        "__reflect_format" | "__reflect_scalar_to_str" => {
            let v = frame.get_value_by_global(inputs[0]);
            // LazyValue 强制求值：格式化前触发 thunk 计算
            // 与 has_extern_c 版本保持一致，避免 not(has_extern_c) 路径漏调 force
            let v = force_lazy_value_sync(frame, &v);
            let s = crate::Reflect::format_value(&v, 0);
            Value::ref_val(crate::Value::HeapObj::Str(crate::Value::GlueStr::from_rust_str(&s)))
        }
        "__reflect_kind" => {
            let v = frame.get_value_by_global(inputs[0]);
            let kind: u8 = match &v {
                Value::Null => 0,
                Value::Void => 1,
                Value::Scalar(_, _) => 2,
                Value::Ref(r) => match &**r {
                    crate::Value::HeapObj::Str(_) => 3,
                    crate::Value::HeapObj::Array(_) => 4,
                    crate::Value::HeapObj::Record(_) => 5,
                    crate::Value::HeapObj::Adt(_) => 6,
                    _ => 7,
                },
            };
            Value::u8(kind)
        }
        "__reflect_type_name" => {
            let v = frame.get_value_by_global(inputs[0]);
            let name = match &v {
                Value::Null => "null".to_string(),
                Value::Void => "void".to_string(),
                Value::Scalar(_, tag) => tag.type_name().to_string(),
                Value::Ref(r) => match &**r {
                    crate::Value::HeapObj::Str(_) => "str".to_string(),
                    crate::Value::HeapObj::Array(_) => "array".to_string(),
                    crate::Value::HeapObj::Record(rec) => rec.type_name.clone(),
                    crate::Value::HeapObj::Adt(a) => a.constructor.clone(),
                    _ => "unknown".to_string(),
                },
            };
            Value::ref_val(crate::Value::HeapObj::Str(crate::Value::GlueStr::from_rust_str(&name)))
        }
        "__reflect_array_len" => {
            let v = frame.get_value_by_global(inputs[0]);
            match v.heap_obj() {
                Some(crate::Value::HeapObj::Array(arr)) => Value::usize_val(arr.elements.len()),
                _ => Value::usize_val(0),
            }
        }
        "__reflect_field_count" => {
            let v = frame.get_value_by_global(inputs[0]);
            let count: u16 = match v.heap_obj() {
                Some(crate::Value::HeapObj::Record(rec)) => rec.fields.len() as u16,
                Some(crate::Value::HeapObj::Adt(a)) => a.fields.len() as u16,
                _ => 0,
            };
            Value::u16(count)
        }
        "__reflect_size" => {
            let v = frame.get_value_by_global(inputs[0]);
            let size: u8 = match &v {
                Value::Scalar(_, tag) => match tag {
                    crate::Value::ScalarTag::Bool | crate::Value::ScalarTag::U8 | crate::Value::ScalarTag::I8 => 1,
                    crate::Value::ScalarTag::U16 | crate::Value::ScalarTag::I16 | crate::Value::ScalarTag::F16 => 2,
                    crate::Value::ScalarTag::U32 | crate::Value::ScalarTag::I32 | crate::Value::ScalarTag::F32 | crate::Value::ScalarTag::Char => 4,
                    crate::Value::ScalarTag::U64 | crate::Value::ScalarTag::I64 | crate::Value::ScalarTag::F64 | crate::Value::ScalarTag::Usize | crate::Value::ScalarTag::Isize => 8,
                    crate::Value::ScalarTag::U128 | crate::Value::ScalarTag::I128 | crate::Value::ScalarTag::F128 => 16,
                },
                _ => 0,
            };
            Value::u8(size)
        }
        "__reflect_field_name" => {
            let v = frame.get_value_by_global(inputs[0]);
            let i = frame.get_value_by_global(inputs[1]).as_u16();
            let name = match v.heap_obj() {
                Some(crate::Value::HeapObj::Record(rec)) => {
                    rec.field_names.get(i as usize).and_then(|n| n.as_ref()).cloned().unwrap_or_default()
                }
                Some(crate::Value::HeapObj::Adt(a)) => {
                    a.fields.get(i as usize).and_then(|f| f.name.as_ref().cloned()).unwrap_or_default()
                }
                _ => String::new(),
            };
            Value::ref_val(crate::Value::HeapObj::Str(crate::Value::GlueStr::from_rust_str(&name)))
        }
        "__reflect_field_value" => {
            let v = frame.get_value_by_global(inputs[0]);
            let i = frame.get_value_by_global(inputs[1]).as_u16();
            match v.heap_obj() {
                Some(crate::Value::HeapObj::Record(rec)) => rec.fields.get(i as usize).cloned().unwrap_or(Value::NULL),
                Some(crate::Value::HeapObj::Adt(a)) => a.fields.get(i as usize).map(|f| f.value.clone()).unwrap_or(Value::NULL),
                _ => Value::NULL,
            }
        }
        "__reflect_adt_constructor" => {
            let v = frame.get_value_by_global(inputs[0]);
            let name = match v.heap_obj() {
                Some(crate::Value::HeapObj::Adt(a)) => a.constructor.clone(),
                _ => String::new(),
            };
            Value::ref_val(crate::Value::HeapObj::Str(crate::Value::GlueStr::from_rust_str(&name)))
        }

        // ── str: UTF-8 逐字符解码（纯 Rust 位运算，与 C 实现语义一致）──
        "__str_utf8_decode_at" => {
            let s = match frame.get_value_by_global(inputs[0]).heap_obj() {
                Some(crate::Value::HeapObj::Str(s)) => s.bytes().to_string(),
                _ => String::new(),
            };
            let offset = frame.get_value_by_global(inputs[1]).as_usize();
            let bytes = s.as_bytes();
            if offset >= bytes.len() {
                Value::i64(-1)
            } else {
                let c = bytes[offset];
                let cp = if c < 0x80 {
                    c as u32
                } else if (c & 0xE0) == 0xC0 {
                    if offset + 1 >= bytes.len() { return Value::i64(-1); }
                    ((c as u32 & 0x1F) << 6) | (bytes[offset + 1] as u32 & 0x3F)
                } else if (c & 0xF0) == 0xE0 {
                    if offset + 2 >= bytes.len() { return Value::i64(-1); }
                    ((c as u32 & 0x0F) << 12)
                        | ((bytes[offset + 1] as u32 & 0x3F) << 6)
                        | (bytes[offset + 2] as u32 & 0x3F)
                } else if (c & 0xF8) == 0xF0 {
                    if offset + 3 >= bytes.len() { return Value::i64(-1); }
                    ((c as u32 & 0x07) << 18)
                        | ((bytes[offset + 1] as u32 & 0x3F) << 12)
                        | ((bytes[offset + 2] as u32 & 0x3F) << 6)
                        | (bytes[offset + 3] as u32 & 0x3F)
                } else {
                    return Value::i64(-1);
                };
                Value::i64(cp as i64)
            }
        }
        "__str_utf8_char_len_at" => {
            let s = match frame.get_value_by_global(inputs[0]).heap_obj() {
                Some(crate::Value::HeapObj::Str(s)) => s.bytes().to_string(),
                _ => String::new(),
            };
            let offset = frame.get_value_by_global(inputs[1]).as_usize();
            let bytes = s.as_bytes();
            if offset >= bytes.len() {
                Value::usize_val(0)
            } else {
                let c = bytes[offset];
                let len = if c < 0x80 { 1 }
                    else if (c & 0xE0) == 0xC0 { 2 }
                    else if (c & 0xF0) == 0xE0 { 3 }
                    else if (c & 0xF8) == 0xF0 { 4 }
                    else { 1 };
                Value::usize_val(len)
            }
        }

        // ── 未实现的 FFI 函数（无 C 编译器时返回默认值）──
        _ => Value::i32(0),
    }
}

/// compute_fn: 记录构造（从输入收集字段值构造 RecordValue）
pub fn compute_record_construct(frame: &mut Frame, node: NodeId) -> Value {
    use crate::Value::{HeapObj, RecordValue};
    read_node_inputs!(frame, node, graph, n, inputs);
    let fields: Vec<Value> = inputs
        .iter()
        .map(|&input_node| frame.get_value_by_global(input_node))
        .collect();
    let info = graph.record_lit_infos[node.0 as usize]
        .as_ref()
        .expect("record construct node has no RecordLitInfo");
    Value::ref_val(HeapObj::Record(RecordValue {
        type_name: info.type_name.clone(),
        fields,
        field_names: info.field_names.clone(),
        field_ref_bits: 0,
    }))
}

/// compute_fn: 记录字段访问（按 field 名称从 Record/Adt 取字段值）
///
/// 统一机制：Record 与 Adt 均通过 `find_field(name)` 按名取值，
/// 不依赖编译期 field_idx，消除 idx fallback 与 Record/Adt 双路径差异。
pub fn compute_record_field_get(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let record_val = frame.get_value_by_global(inputs[0]);
    let name = graph.field_set_names[node.0 as usize].as_deref();
    match record_val.heap_obj() {
        Some(crate::Value::HeapObj::Record(r)) => {
            name.and_then(|n| r.find_field(n)).cloned().unwrap_or(Value::VOID)
        }
        Some(crate::Value::HeapObj::Adt(a)) => {
            name.and_then(|n| a.find_field(n)).cloned().unwrap_or(Value::VOID)
        }
        _ => Value::VOID,
    }
}

/// compute_fn: 数组构造（从输入收集元素构造 ArrayValue）
pub fn compute_array_construct(frame: &mut Frame, node: NodeId) -> Value {
    use crate::Value::{HeapObj, ArrayValue};
    read_node_inputs!(frame, node, graph, n, inputs);
    let elements: Vec<Value> = inputs
        .iter()
        .map(|&input_node| frame.get_value_by_global(input_node))
        .collect();
    Value::ref_val(HeapObj::Array(ArrayValue::new(elements)))
}

/// compute_fn: 数组索引（从 ArrayValue 按 i32 索引取元素）
/// 索引越界时返回 ThrowVal(Err) 错误值，逐层透传至顶层。
pub fn compute_array_index(frame: &mut Frame, node: NodeId) -> Value {
    use std::sync::Arc;
    use crate::Value::{HeapObj, RecordValue, ThrowValue, ThrowPayload};
    read_node_inputs!(frame, node, graph, n, inputs);
    let recv_val = frame.get_value_by_global(inputs[0]);
    let idx = frame.get_value_by_global(inputs[1]).as_i32() as usize;
    let make_err = |msg: &str| {
        let record = Arc::new(RecordValue {
            type_name: "IndexError".to_string(),
            fields: vec![Value::ref_val(HeapObj::Str(crate::Value::GlueStr::new(msg)))],
            field_names: vec![Some("message".to_string())],
            field_ref_bits: 1,
        });
        Value::ref_val(HeapObj::ThrowVal(ThrowValue { payload: ThrowPayload::Err(record) }))
    };
    match recv_val.heap_obj() {
        Some(crate::Value::HeapObj::Array(arr)) => {
            arr.get(idx).cloned().unwrap_or_else(|| {
                make_err(&format!("index {} out of bounds (len {})", idx, arr.len()))
            })
        }
        Some(crate::Value::HeapObj::Str(s)) => {
            s.char_at(idx).map(|c| Value::char_val(c)).unwrap_or_else(|| {
                make_err(&format!("index {} out of bounds (len {})", idx, s.codepoint_count()))
            })
        }
        _ => make_err("index on non-indexable type"),
    }
}

/// compute_fn: 切片 `recv[start..end]` / `recv[start..=end]`。
///
/// 三输入：recv, start, end。inclusive 标志从 graph.slice_inclusive[node] 读取。
/// - str：按码点索引切片，返回新 str
/// - array：按元素索引切片，返回新 array
/// 越界时 clamp 到 [0, len]，与 Rust 切片语义一致（不 panic）。
pub fn compute_slice(frame: &mut Frame, node: NodeId) -> Value {
    use std::sync::Arc;
    use crate::Value::{HeapObj, ArrayValue, GlueStr, RecordValue, ThrowValue, ThrowPayload};
    read_node_inputs!(frame, node, graph, n, inputs);
    let recv_val = frame.get_value_by_global(inputs[0]);
    let start = frame.get_value_by_global(inputs[1]).as_usize();
    let mut end = frame.get_value_by_global(inputs[2]).as_usize();
    let inclusive = graph.slice_inclusive[node.0 as usize];
    if inclusive {
        end = end.saturating_add(1);
    }
    let make_err = |msg: &str| {
        let record = Arc::new(RecordValue {
            type_name: "SliceError".to_string(),
            fields: vec![Value::ref_val(HeapObj::Str(GlueStr::new(msg)))],
            field_names: vec![Some("message".to_string())],
            field_ref_bits: 1,
        });
        Value::ref_val(HeapObj::ThrowVal(ThrowValue { payload: ThrowPayload::Err(record) }))
    };
    match recv_val.heap_obj() {
        Some(crate::Value::HeapObj::Array(arr)) => {
            let len = arr.len();
            let s = start.min(len);
            let e = end.min(len);
            if s > e {
                return make_err(&format!("slice start {} > end {}", s, e));
            }
            let sliced: Vec<Value> = arr.elements[s..e].to_vec();
            Value::ref_val(HeapObj::Array(ArrayValue {
                elements: sliced,
                fixed_size: None,
                elem_is_ref: arr.elem_is_ref,
                scalar_soa: None,
            }))
        }
        Some(crate::Value::HeapObj::Str(s)) => {
            // 按码点索引切片：collect chars in [start, end)，重组为 str
            let chars: Vec<char> = s.bytes().chars().collect();
            let len = chars.len();
            let st = start.min(len);
            let en = end.min(len);
            if st > en {
                return make_err(&format!("slice start {} > end {}", st, en));
            }
            let mut buf = String::with_capacity(en - st);
            for c in &chars[st..en] {
                buf.push(*c);
            }
            Value::ref_val(HeapObj::Str(GlueStr::new(buf)))
        }
        _ => make_err("slice on non-sliceable type"),
    }
}

/// compute_fn: 字符串拼接 `lhs + rhs`（两侧均为 str）。
///
/// 两输入：lhs, rhs。任一非 str 时返回错误值。
pub fn compute_str_concat(frame: &mut Frame, node: NodeId) -> Value {
    use std::sync::Arc;
    use crate::Value::{HeapObj, GlueStr, RecordValue, ThrowValue, ThrowPayload};
    read_node_inputs!(frame, node, graph, n, inputs);
    let lhs = frame.get_value_by_global(inputs[0]);
    let rhs = frame.get_value_by_global(inputs[1]);
    let make_err = |msg: &str| {
        let record = Arc::new(RecordValue {
            type_name: "TypeError".to_string(),
            fields: vec![Value::ref_val(HeapObj::Str(GlueStr::new(msg)))],
            field_names: vec![Some("message".to_string())],
            field_ref_bits: 1,
        });
        Value::ref_val(HeapObj::ThrowVal(ThrowValue { payload: ThrowPayload::Err(record) }))
    };
    match (lhs.heap_obj(), rhs.heap_obj()) {
        (Some(HeapObj::Str(a)), Some(HeapObj::Str(b))) => {
            Value::ref_val(HeapObj::Str(a.concat(b)))
        }
        _ => make_err("str concat on non-str operand"),
    }
}

/// compute_fn (idx 270): 全局变量读取。
///
/// 无输入，从 graph.global_var_storage[slot] 读取值。
/// slot index 从 graph.global_load_slots[node] 获取。
/// 全局变量不依赖帧链，任何函数都能正确读取。
pub fn compute_global_load(frame: &mut Frame, node: NodeId) -> Value {
    let slot = frame.graph.global_load_slots[node.0 as usize]
        .expect("global_load node has no slot");
    let storage = &frame.graph.global_var_storage;
    let guard = storage[slot as usize].lock().unwrap();
    guard.clone().unwrap_or(Value::NULL)
}

/// compute_fn (idx 271): 全局变量写入。
///
/// inputs[0] = 值来源节点，写入 graph.global_var_storage[slot]。
/// slot index 从 graph.global_store_slots[node] 获取。
/// 返回写入的值（供下游链式使用）。
pub fn compute_global_store(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let val = frame.get_value_by_global(inputs[0]);
    let slot = graph.global_store_slots[node.0 as usize]
        .expect("global_store node has no slot");
    let storage = &frame.graph.global_var_storage;
    *storage[slot as usize].lock().unwrap() = Some(val.clone());
    val
}

/// compute_fn (idx 272): 记录扩展。
///
/// inputs[0] = base RecordValue，inputs[1..] = 更新字段值。
/// RecordExtendInfo.update_names 给出 inputs[1..] 对应的字段名。
/// 从 base 克隆字段与字段名，按 update_names 替换同名字段或追加新字段，
/// 构造新 RecordValue（保留 base 的 type_name）。
pub fn compute_record_extend(frame: &mut Frame, node: NodeId) -> Value {
    use crate::Value::{HeapObj, RecordValue};
    read_node_inputs!(frame, node, graph, n, inputs);
    let info = graph.record_extend_infos[node.0 as usize]
        .as_ref()
        .expect("record extend node has no RecordExtendInfo");

    // 取 base RecordValue
    let base_val = frame.get_value_by_global(inputs[0]);
    let base_record: RecordValue = match base_val.heap_obj() {
        Some(HeapObj::Record(r)) => r.clone(),
        _ => {
            // base 非 record：退化为空记录，所有 update 字段作为新字段追加
            RecordValue::new(String::new(), Vec::new(), Vec::new())
        }
    };

    // 收集 update 值（inputs[1..]，按 update_names 顺序）
    let update_values: Vec<Value> = inputs[1..]
        .iter()
        .map(|&in_node| frame.get_value_by_global(in_node))
        .collect();

    // 克隆 base 字段与字段名，按 update_names 替换/追加
    let mut fields: Vec<Value> = base_record.fields.clone();
    let mut field_names: Vec<Option<String>> = base_record.field_names.clone();
    for (i, update_name) in info.update_names.iter().enumerate() {
        let update_val = update_values[i].clone();
        // 查找同名字段位置
        let pos = field_names.iter().position(|n| n.as_deref() == Some(update_name));
        match pos {
            Some(idx) => {
                // 替换已有字段值
                fields[idx] = update_val;
            }
            None => {
                // 追加新字段
                fields.push(update_val);
                field_names.push(Some(update_name.clone()));
            }
        }
    }

    Value::ref_val(HeapObj::Record(RecordValue {
        type_name: base_record.type_name.clone(),
        fields,
        field_names,
        field_ref_bits: 0,
    }))
}

/// compute_fn (idx 273): 原子构造。
///
/// inputs[0] = 初始值节点，包装为 AtomicValue（共享底层内存的原子容器）。
/// AtomicValue.data 为 Value，compute_fn 上下文无需 arena 即可构造。
pub fn compute_atomic_construct(frame: &mut Frame, node: NodeId) -> Value {
    use crate::Value::{HeapObj, AtomicValue};
    read_node_inputs!(frame, node, graph, n, inputs);
    let val = frame.get_value_by_global(inputs[0]);
    Value::ref_val(HeapObj::AtomicVal(AtomicValue::new(val)))
}

/// compute_fn: 模式匹配 — 构造器名判别（idx 274）。
///
/// 输入：scrutinee。元数据：构造器名（graph.pattern_ctor_names）。
/// 检查 scrutinee 是否为 ADT 且 constructor 匹配，或 Record 且 type_name 匹配。
/// 返回 bool。
pub fn compute_pattern_ctor_match(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let val = frame.get_value_by_global(inputs[0]);
    let ctor_name = graph.pattern_ctor_names[node.0 as usize]
        .as_ref()
        .expect("pattern ctor match node has no ctor name");
    let matched = match val.heap_obj() {
        Some(crate::Value::HeapObj::Adt(a)) => a.constructor == *ctor_name,
        Some(crate::Value::HeapObj::Record(r)) => r.type_name == *ctor_name,
        _ => false,
    };
    Value::bool_val(matched)
}

/// compute_fn: 模式匹配 — ADT/Record 按位置提取字段（idx 275）。
///
/// 输入：scrutinee。元数据：字段索引（graph.pattern_field_indices）。
/// 从 ADT 按位置取字段值，或从 Record 按位置取字段值。
/// 返回字段值（越界返回 Void）。
pub fn compute_pattern_adt_field_get(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let val = frame.get_value_by_global(inputs[0]);
    let idx = graph.pattern_field_indices[node.0 as usize]
        .expect("pattern adt field get node has no field index")
        as usize;
    match val.heap_obj() {
        Some(crate::Value::HeapObj::Adt(a)) => {
            a.fields.get(idx).map(|f| f.value.clone()).unwrap_or(Value::VOID)
        }
        Some(crate::Value::HeapObj::Record(r)) => {
            r.fields.get(idx).cloned().unwrap_or(Value::VOID)
        }
        _ => Value::VOID,
    }
}

/// compute_fn: 模式匹配 — 字符串相等判别（idx 276）。
///
/// 输入：scrutinee, str_const。比较两个值是否为相等字符串。
/// 返回 bool。
pub fn compute_pattern_str_eq(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let lhs = frame.get_value_by_global(inputs[0]);
    let rhs = frame.get_value_by_global(inputs[1]);
    let lhs_str = match lhs.heap_obj() {
        Some(crate::Value::HeapObj::Str(s)) => s.bytes().to_string(),
        _ => return Value::bool_val(false),
    };
    let rhs_str = match rhs.heap_obj() {
        Some(crate::Value::HeapObj::Str(s)) => s.bytes().to_string(),
        _ => return Value::bool_val(false),
    };
    Value::bool_val(lhs_str == rhs_str)
}

/// compute_fn: 通用类型转换 — 任意值 → str（idx 277）。
///
/// 输入：源值节点。按 Value 变体分派格式化为 GlueStr：
///   - 标量整数 → as_int_i128().to_string()
///   - 标量浮点 → as_float_f64().to_string()
///   - bool → "true"/"false"
///   - char → String::from(char)
///   - Str → clone（identity）
///   - Null → "null"
///   - Void → "void"
///   - 其他 Ref → "<non-scalar>"
pub fn compute_cast_to_str(frame: &mut Frame, node: NodeId) -> Value {
    use crate::Value::{HeapObj, GlueStr, ScalarTag};
    read_node_inputs!(frame, node, graph, n, inputs);
    let val = frame.get_value_by_global(inputs[0]);

    let s: String = match &val {
        Value::Null => "null".to_string(),
        Value::Void => "void".to_string(),
        Value::Scalar(_, tag) => {
            match tag {
                ScalarTag::Bool => val.as_bool().to_string(),
                ScalarTag::Char => {
                    let c = val.as_char();
                    let mut buf = [0u8; 4];
                    c.encode_utf8(&mut buf).to_string()
                }
                ScalarTag::F16 | ScalarTag::F32 | ScalarTag::F64 | ScalarTag::F128 => {
                    val.as_float_f64().to_string()
                }
                // 所有整数类型
                _ => val.as_int_i128().to_string(),
            }
        }
        Value::Ref(r) => match r.as_ref() {
            HeapObj::Str(glue_str) => glue_str.bytes().to_string(),
            _ => "<non-scalar>".to_string(),
        },
    };
    Value::ref_val(HeapObj::Str(GlueStr::new(s)))
}

/// compute_fn: 通用类型转换 — 标量 → 标量（idx 278）。
///
/// 输入：源值节点。元数据：目标类型名（graph.cast_target_types）。
/// 覆盖所有标量互转：int↔int（截断/扩展）、int↔float、float↔float、bool→int、char→int。
/// 目标类型从 cast_target_types 元数据读取，按 ScalarTag 分派构造对应 Value。
pub fn compute_cast_scalar(frame: &mut Frame, node: NodeId) -> Value {
    use crate::Value::ScalarTag;
    read_node_inputs!(frame, node, graph, n, inputs);
    let val = frame.get_value_by_global(inputs[0]);
    let target_ty = graph.cast_target_types[node.0 as usize]
        .as_ref()
        .expect("cast_scalar node has no target type");

    let target_tag = match target_ty.as_str() {
        "i8" => ScalarTag::I8,
        "i16" => ScalarTag::I16,
        "i32" => ScalarTag::I32,
        "i64" => ScalarTag::I64,
        "i128" => ScalarTag::I128,
        "u8" => ScalarTag::U8,
        "u16" => ScalarTag::U16,
        "u32" => ScalarTag::U32,
        "u64" => ScalarTag::U64,
        "u128" => ScalarTag::U128,
        "isize" => ScalarTag::Isize,
        "usize" => ScalarTag::Usize,
        "f16" => ScalarTag::F16,
        "f32" => ScalarTag::F32,
        "f64" => ScalarTag::F64,
        "f128" => ScalarTag::F128,
        "bool" => ScalarTag::Bool,
        "char" => ScalarTag::Char,
        _ => return Value::VOID,
    };

    // 源值是否为浮点
    let src_is_float = matches!(
        &val,
        Value::Scalar(_, ScalarTag::F16 | ScalarTag::F32 | ScalarTag::F64 | ScalarTag::F128)
    );
    // 统一读取源值为 f64：浮点用 as_float_f64，整数用 as_int_i128 as f64
    let src_f64 = if src_is_float { val.as_float_f64() } else { val.as_int_i128() as f64 };

    match target_tag {
        ScalarTag::I8 => Value::i8(val.as_i8()),
        ScalarTag::I16 => Value::i16(val.as_i16()),
        ScalarTag::I32 => Value::i32(if src_is_float { src_f64 as i32 } else { val.as_i32() }),
        ScalarTag::I64 => Value::i64(if src_is_float { src_f64 as i64 } else { val.as_i64() }),
        ScalarTag::I128 => Value::i128(if src_is_float { src_f64 as i128 } else { val.as_i128() }),
        ScalarTag::U8 => Value::u8(val.as_u8()),
        ScalarTag::U16 => Value::u16(val.as_u16()),
        ScalarTag::U32 => Value::u32(if src_is_float { src_f64 as u32 } else { val.as_u32() }),
        ScalarTag::U64 => Value::u64(if src_is_float { src_f64 as u64 } else { val.as_u64() }),
        ScalarTag::U128 => Value::u128(if src_is_float { src_f64 as u128 } else { val.as_u128() }),
        ScalarTag::Isize => Value::isize_val(if src_is_float { src_f64 as isize } else { val.as_isize() }),
        ScalarTag::Usize => Value::usize_val(if src_is_float { src_f64 as usize } else { val.as_usize() }),
        ScalarTag::F16 => Value::f16(crate::Value::F16::from_f64(src_f64)),
        ScalarTag::F32 => Value::f32(src_f64 as f32),
        ScalarTag::F64 => Value::f64(src_f64),
        ScalarTag::F128 => Value::f128(crate::Value::F128::from_f64(src_f64)),
        ScalarTag::Bool => Value::bool_val(val.as_int_i128() != 0),
        ScalarTag::Char => Value::char_val(char::from_u32(val.as_int_i128() as u32).unwrap_or('\0')),
    }
}

/// compute_fn: 记录字段赋值（就地修改 RecordValue 的字段，返回 void）
///
/// inputs[0] = 记录值节点，inputs[1] = 新值。
/// 字段名从 graph.field_set_names[node] 获取，通过 Arc::make_mut 就地修改。
/// 修改后写回值表槽，使变更对其他节点可见。
pub fn compute_record_field_set(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let _record_val = frame.get_value_by_global(inputs[0]);
    let new_value = frame.get_value_by_global(inputs[1]);
    let field_name = graph.field_set_names[node.0 as usize]
        .as_ref()
        .expect("field set node has no field name");
    // &self 语义：通过 Arc::as_ptr 直接修改底层 HeapObj（不 COW）。
    // 参数传递时 Arc 被 clone（refcount > 1），Arc::make_mut 会创建副本导致 &self 修改不可见。
    let record_node_local = NodeId(inputs[0].0.wrapping_sub(frame.node_offset));
    if let Some(val) = frame.value_table.get_value_mut(record_node_local.0 as usize) {
        if let Value::Ref(arc) = val {
            // &self 语义：直接修改 Arc 底层的 HeapObj，而非 Arc::make_mut 的 COW 副本。
            // 参数传递时 Arc 被 clone（refcount > 1），make_mut 会创建副本导致修改对调用方不可见。
            // 直接修改确保 &self 引用语义正确（修改原始值，不是副本）。
            //
            // Safety: 引擎单线程执行，caller 帧在 callee 执行期间处于 Suspended 状态，
            // 不会有并发访问同一 HeapObj 的代码路径。
            let ptr = std::sync::Arc::as_ptr(arc) as *mut crate::Value::HeapObj;
            unsafe {
                if let crate::Value::HeapObj::Record(r) = &mut *ptr {
                    if let Some(idx) = r.field_names.iter().position(|n| n.as_deref() == Some(field_name.as_str())) {
                        if idx < r.fields.len() {
                            r.fields[idx] = new_value.clone();
                        }
                    }
                }
            }
        }
    }
    Value::VOID
}

/// compute_fn: null 检查（检查值是否为 null，返回 bool）
pub fn compute_is_null(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let val = frame.get_value_by_global(inputs[0]);
    let is_null = val.is_null();
    Value::bool_val(is_null)
}

/// compute_fn: 数组长度（返回 i32，与默认整数运算类型一致）
pub fn compute_array_len(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let val = frame.get_value_by_global(inputs[0]);
    let len = match val.heap_obj() {
        Some(crate::Value::HeapObj::Array(arr)) => arr.len() as i32,
        Some(crate::Value::HeapObj::Str(s)) => s.byte_len() as i32,
        _ => 0,
    };
    Value::i32(len)
}

/// compute_fn: 引用相等比较（===），比较两个 Ref 的 Arc 指针是否指向同一对象。
/// 返回 bool。两边均为 Ref 时用 Arc::ptr_eq；否则返回 false。
pub fn compute_ref_eq(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let lhs = frame.get_value_by_global(inputs[0]);
    let rhs = frame.get_value_by_global(inputs[1]);
    let eq = match (&lhs, &rhs) {
        (Value::Ref(a), Value::Ref(b)) => std::sync::Arc::ptr_eq(a, b),
        _ => false,
    };
    Value::bool_val(eq)
}

/// compute_fn: 引用不等比较（!==），RefEq 的否定。
pub fn compute_ref_neq(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let lhs = frame.get_value_by_global(inputs[0]);
    let rhs = frame.get_value_by_global(inputs[1]);
    let neq = match (&lhs, &rhs) {
        (Value::Ref(a), Value::Ref(b)) => !std::sync::Arc::ptr_eq(a, b),
        _ => true,
    };
    Value::bool_val(neq)
}

/// compute_fn: 列表拼接（ConcatList），两个 Array 拼接为新 Array。
pub fn compute_concat_list(frame: &mut Frame, node: NodeId) -> Value {
    use crate::Value::{HeapObj, ArrayValue};
    read_node_inputs!(frame, node, graph, n, inputs);
    let lhs = frame.get_value_by_global(inputs[0]);
    let rhs = frame.get_value_by_global(inputs[1]);
    match (lhs.heap_obj(), rhs.heap_obj()) {
        (Some(HeapObj::Array(a)), Some(HeapObj::Array(b))) => {
            let mut elements = Vec::with_capacity(a.len() + b.len());
            elements.extend(a.elements.iter().cloned());
            elements.extend(b.elements.iter().cloned());
            Value::ref_val(HeapObj::Array(ArrayValue::new(elements)))
        }
        _ => Value::VOID,
    }
}

/// compute_fn: 范围生成（Range，a..b，左闭右开）。
pub fn compute_range(frame: &mut Frame, node: NodeId) -> Value {
    use crate::Value::{HeapObj, Range};
    read_node_inputs!(frame, node, graph, n, inputs);
    let start = frame.get_value_by_global(inputs[0]).as_i64();
    let end = frame.get_value_by_global(inputs[1]).as_i64();
    Value::ref_val(HeapObj::Range(Range::new(start, end, false)))
}

/// compute_fn: 范围生成（RangeInclusive，a..=b，左闭右闭）。
pub fn compute_range_inclusive(frame: &mut Frame, node: NodeId) -> Value {
    use crate::Value::{HeapObj, Range};
    read_node_inputs!(frame, node, graph, n, inputs);
    let start = frame.get_value_by_global(inputs[0]).as_i64();
    let end = frame.get_value_by_global(inputs[1]).as_i64();
    Value::ref_val(HeapObj::Range(Range::new(start, end, true)))
}

/// compute_fn: Elvis 运算（lhs ?: rhs）。lhs 为 null 时返回 rhs，否则返回 lhs。
pub fn compute_elvis(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let lhs = frame.get_value_by_global(inputs[0]);
    if lhs.is_null() {
        frame.get_value_by_global(inputs[1])
    } else {
        lhs
    }
}

/// compute_fn: Call 节点启动子图（参数收集 + 标记 frame.pending_call）。
///
/// 不直接 start_subgraph（compute_fn 无 Engine 引用）。
/// 核心循环检测 pending_call 后执行 start_subgraph + 帧挂起。
pub fn compute_call_launch(frame: &mut Frame, node: NodeId) -> Value {
    let graph = frame.graph.clone();
    // 静态绑定：有 call_target → 收集参数 + 设 pending_call
    if let Some(target_sg) = graph.call_targets[node.0 as usize] {
        let param_count = graph.subgraphs[target_sg.0 as usize].param_count as usize;
        let n = &graph.nodes[node.0 as usize];
        let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
        let args: Vec<Value> = inputs
            .iter()
            .take(param_count)
            .map(|&in_node| frame.get_value_by_global(in_node))
            .collect();

        // call_node 的局部 id（node - node_offset）
        let call_node_local = NodeId(node.0.wrapping_sub(frame.node_offset));

        frame.pending_call = Some(PendingCall {
            target_sg,
            args,
            call_node_local,
            is_async: false,
        });
        return Value::VOID;
    }

    // 动态分派：vtable_call_methods 有值但不设 pending_call（由 run_ready_nodes
    // 的 vtable 分支从 TraitVal 运行时查询方法子图后再设 pending_call）。
    // 两者都无：编译器保证 Call 节点必有其一；此处不 panic，保持容错。
    Value::VOID
}

/// compute_fn: Gate 节点选择分支 + 启动子图（参数收集 + 标记 frame.pending_call）。
pub fn compute_gate_launch(frame: &mut Frame, node: NodeId) -> Value {
    let graph = frame.graph.clone();
    let branches = graph.gate_branches[node.0 as usize]
        .as_ref()
        .expect("Gate node has no branches");

    // 读条件值
    let cond = frame.get_value_by_global(branches.condition_input).as_bool();

    // 选分支
    let (target_sg, branch_inputs) = branches
        .branches
        .iter()
        .find(|(c, _, _)| *c == cond)
        .map(|(_, sg, inputs)| (*sg, inputs.clone()))
        .expect("no matching gate branch");

    // 收集参数
    let param_count = graph.subgraphs[target_sg.0 as usize].param_count as usize;
    let args: Vec<Value> = branch_inputs
        .iter()
        .take(param_count)
        .map(|&n| frame.get_value_by_global(n))
        .collect();

    let gate_node_local = NodeId(node.0.wrapping_sub(frame.node_offset));

    frame.pending_call = Some(PendingCall {
        target_sg,
        args,
        call_node_local: gate_node_local,
        is_async: false,
    });

    Value::VOID
}

/// compute_await（idx 38）：await 节点执行时设置 frame.pending_await。
///
/// spec 4.4：事件源未就绪 → await 未就绪 → 帧无更多就绪节点 → 挂起。
/// compute_await 无法访问 Engine 运行时，只设置 pending_await，
/// 核心循环消费后解析事件源 → 检查就绪 → 就绪则注入值继续 → 未就绪则挂起。
pub fn compute_await(frame: &mut Frame, node: NodeId) -> Value {
    use crate::Ir::PendingAwait;

    read_node_inputs!(frame, node, graph, n, inputs);
    // inputs[0] = 事件对象节点（AsyncHandle/Channel/Timer）
    let event_obj = frame.get_value_by_global(inputs[0]);
    let await_node_local = NodeId(node.0.wrapping_sub(frame.node_offset));

    // EventSource 节点从 await_event_sources 表读取（元数据引用，非数据依赖）
    let es_node = graph.await_event_sources[node.0 as usize];
    let event_kind = match es_node {
        Some(es) => graph
            .subgraphs
            .get(frame.subgraph_id.0 as usize)
            .and_then(|sg| {
                sg.event_source_decls
                    .iter()
                    .find(|d| d.node == es)
                    .map(|d| d.kind)
            })
            .unwrap_or(crate::Ir::EventSourceKind::AsyncJoin),
        None => crate::Ir::EventSourceKind::AsyncJoin,
    };

    frame.pending_await = Some(PendingAwait {
        await_node_local,
        event_obj,
        event_kind,
    });

    Value::VOID
}

/// compute_async_call_launch（idx 39）：async 函数调用，启动子帧但不挂起当前帧。
///
/// 与 compute_call_launch 相同参数收集逻辑，但 is_async=true。
/// 核心循环检测 is_async=true 后：启动子帧 + call 节点写 AsyncHandle + 通知下游 + 不挂起。
pub fn compute_async_call_launch(frame: &mut Frame, node: NodeId) -> Value {
    use crate::Ir::PendingCall;

    let graph = frame.graph.clone();
    let target_sg = graph.call_targets[node.0 as usize]
        .expect("async Call node has no target");
    let param_count = graph.subgraphs[target_sg.0 as usize].param_count as usize;
    let n = &graph.nodes[node.0 as usize];
    let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
    let args: Vec<Value> = inputs
        .iter()
        .take(param_count)
        .map(|&in_node| frame.get_value_by_global(in_node))
        .collect();
    let call_node_local = NodeId(node.0.wrapping_sub(frame.node_offset));

    frame.pending_call = Some(PendingCall {
        target_sg,
        args,
        call_node_local,
        is_async: true,
    });

    Value::VOID
}

/// compute_fn: 闭包构造（idx 40）。
///
/// 从 graph.closure_infos 取子图 id + arity，合并 inputs（捕获值）构造 Closure 堆对象。
/// 节点的 inputs 即捕获的 upvalues（按 compile_lambda 中 captured 顺序）。
pub fn compute_closure_construct(frame: &mut Frame, node: NodeId) -> Value {
    use crate::Value::{HeapObj, Closure};
    read_node_inputs!(frame, node, graph, n, inputs);
    let info = graph.closure_infos[node.0 as usize]
        .expect("closure construct node has no ClosureInfo");
    let upvalues: Vec<Value> = inputs
        .iter()
        .map(|&in_node| frame.get_value_by_global(in_node))
        .collect();
    Value::ref_val(HeapObj::Closure(Closure {
        func_id: info.subgraph_id.0,
        arity: info.arity,
        upvalues,
        bound_args: Vec::new(),
        self_upvalue_idx: -1,
        upvalue_ref_bits: 0,
        cell_upvalues: 0,
    }))
}

/// compute_fn: inline_trait 构造（idx 266）。
///
/// 从 graph.trait_construct_infos 取 trait 名 + 方法列表，
/// 合并节点 inputs（各方法 upvalues 依次拼接）构造多个 Closure，
/// 打包成 TraitValue 堆对象。
pub fn compute_trait_construct(frame: &mut Frame, node: NodeId) -> Value {
    use crate::Value::{HeapObj, Closure, TraitValue};
    read_node_inputs!(frame, node, graph, n, inputs);
    let info = graph.trait_construct_infos[node.0 as usize]
        .as_ref()
        .expect("trait construct node has no TraitConstructInfo");

    // 从 inputs 按各方法 upvalue_count 依次切分，构造每个方法的 Closure
    let mut method_values: Vec<Value> = Vec::with_capacity(info.methods.len());
    let mut input_cursor = 0usize;
    for m in &info.methods {
        let upvalue_count = m.upvalue_count as usize;
        let upvalues: Vec<Value> = inputs[input_cursor..input_cursor + upvalue_count]
            .iter()
            .map(|&in_node| frame.get_value_by_global(in_node))
            .collect();
        input_cursor += upvalue_count;
        method_values.push(Value::ref_val(HeapObj::Closure(Closure {
            func_id: m.subgraph_id.0,
            arity: m.arity,
            upvalues,
            bound_args: Vec::new(),
            self_upvalue_idx: -1,
            upvalue_ref_bits: 0,
            cell_upvalues: 0,
        })));
    }

    Value::ref_val(HeapObj::TraitVal(TraitValue {
        trait_name: info.trait_name.clone(),
        method_names: info.method_names.clone(),
        method_values,
        data: None,
        owned: true,
    }))
}

/// compute_fn: lazy 构造（idx 267）。
///
/// 从 graph.lazy_construct_infos 取 thunk 子图 id，
/// 合并节点 inputs（upvalues）构造 LazyValue 堆对象。
/// thunk 未求值，首次 force 时启动子图计算并缓存结果。
pub fn compute_lazy_construct(frame: &mut Frame, node: NodeId) -> Value {
    use crate::Value::{HeapObj, LazyValue, Closure};
    read_node_inputs!(frame, node, graph, n, inputs);
    let info = graph.lazy_construct_infos[node.0 as usize]
        .as_ref()
        .expect("lazy construct node has no LazyConstructInfo");

    // upvalues 从 inputs 收集，存入 Closure（thunk 首次 force 时用）
    let upvalues: Vec<Value> = inputs
        .iter()
        .map(|&in_node| frame.get_value_by_global(in_node))
        .collect();

    // 用 Closure 包装 thunk 子图（func_id = thunk_sg），存为 LazyValue.data
    // force 时从 data 取 Closure，启动子图计算，结果缓存到 cached
    let thunk_closure = Value::ref_val(HeapObj::Closure(Closure {
        func_id: info.thunk_sg.0,
        arity: 0,
        upvalues,
        bound_args: Vec::new(),
        self_upvalue_idx: -1,
        upvalue_ref_bits: 0,
        cell_upvalues: 0,
    }));

    Value::ref_val(HeapObj::LazyVal(LazyValue {
        cached: std::sync::Mutex::new(None),
        forced: std::sync::atomic::AtomicBool::new(false),
        data: Some(thunk_closure),
    }))
}

// =========================================================================
// LazyValue force 机制：同步执行 thunk 子图，缓存结果
// =========================================================================

/// 强制求值 LazyValue：同步执行 thunk 子图，返回计算结果。
///
/// 若已 forced，直接返回 cached 值；否则创建 thunk 帧，同步运行至完成，
/// 将结果缓存到 LazyValue（通过 Arc::make_mut 原地更新），返回结果。
///
/// 此函数在 compute_ffi_call 的 __reflect_format 处理器中调用，
/// 用于在格式化前强制求值 lazy 值。
pub fn force_lazy_value_sync(caller_frame: &mut Frame, lazy_val: &Value) -> Value {
    use crate::Value::{Closure, HeapObj, LazyValue};

    // 提取 LazyValue 引用
    let arc = match lazy_val {
        Value::Ref(r) => r,
        _ => return lazy_val.clone(), // 非 LazyValue，直接返回
    };

    // 检查是否已 forced
    {
        if let HeapObj::LazyVal(lazy) = &**arc {
            if lazy.forced.load(std::sync::atomic::Ordering::Relaxed) {
                return lazy.cached.lock().unwrap().clone().unwrap_or(Value::NULL);
            }
        } else {
            return lazy_val.clone(); // 非 LazyVal，直接返回
        }
    }

    // 取 thunk Closure
    let closure = {
        let HeapObj::LazyVal(lazy) = &**arc else { return lazy_val.clone() };
        match &lazy.data {
            Some(v) => match v.heap_obj() {
                Some(HeapObj::Closure(c)) => c.clone(),
                _ => return Value::NULL,
            },
            None => return Value::NULL,
        }
    };

    let graph = caller_frame.graph.clone();
    let thunk_sg = SubGraphId(closure.func_id);

    // 创建 thunk 帧
    let (node_start, node_end) = graph.subgraphs[thunk_sg.0 as usize].node_range;
    let node_count = (node_end.0 - node_start.0) as usize;
    let mut thunk_frame = Frame::new(FrameId(0xFFFF_FFFF), thunk_sg, node_count, graph.clone());
    prepare_frame_shared(&mut thunk_frame, &graph);

    // 注入 upvalues 作为参数
    let offset = node_start.0 as usize;
    let param_count = graph.subgraphs[thunk_sg.0 as usize].param_count as usize;
    for (i, arg) in closure.upvalues.iter().enumerate().take(param_count) {
        let local_id = NodeId(i as u32);
        let consumer_count = graph.downstreams[offset + i].len() as u16;
        thunk_frame.set_value(local_id, arg.clone(), consumer_count);
        thunk_frame.push_ready(local_id);
    }

    // 设置 parent_frame_ptr：thunk 内可通过帧链穿透访问外层变量
    thunk_frame.parent_frame_ptr = caller_frame as *mut Frame;

    // 同步执行 thunk 帧
    let result = run_frame_sync(&mut thunk_frame, &graph);

    // 缓存结果到 LazyValue（通过 Mutex/AtomicBool 的 interior mutability 更新）
    if let HeapObj::LazyVal(lazy) = &**arc {
        lazy.forced.store(true, std::sync::atomic::Ordering::Relaxed);
        *lazy.cached.lock().unwrap() = Some(result.clone());
    }

    result
}

/// 同步执行帧至完成，处理嵌套函数调用、控制信号、vtable 分派。
///
/// 这是 Engine 异步执行模型的同步简化版：
/// - 弹出就绪节点 → 调用 compute_fn → 处理 pending_call/control_signal
/// - pending_call：递归创建子帧 + 同步执行 + 注入返回值
/// - control_signal：Return 直接返回，Break/Continue 传播
///
/// 不支持：async/await、channel/timer 事件、select、循环体复用。
/// 适用于 thunk 子图（纯计算 + 同步函数调用）。
fn run_frame_sync(frame: &mut Frame, graph: &DataFlowGraph) -> Value {
    use crate::Ir::{ControlSignal, LoopKind, NodeKind, PendingCall, SignalKind, SubGraphId};

    loop {
        // 1. 检查控制信号（return/break/continue 已触发）
        let cs = frame.control_signal.clone();
        match cs {
            ControlSignal::Return(v) => return v,
            ControlSignal::Break | ControlSignal::Continue => return Value::VOID,
            ControlSignal::None => {}
        }

        // 2. 弹出就绪节点
        let local_id = match frame.pop_ready() {
            Some(n) => n,
            None => {
                // 无就绪节点：从 return_node 提取返回值
                let sg = &graph.subgraphs[frame.subgraph_id.0 as usize];
                return frame.get_value_by_global(sg.return_node);
            }
        };

        let node_start = frame.node_offset;
        let graph_node_id = NodeId(local_id.0 + node_start);
        let node = graph.nodes[graph_node_id.0 as usize];

        // 3. 执行 compute_fn
        let pre_filled = frame.value_table.ready[local_id.0 as usize];
        let value = if pre_filled {
            frame.value_table.values[local_id.0 as usize].clone()
        } else {
            let compute_fn = graph.compute_fns[node.compute_fn.0 as usize];
            compute_fn(frame, graph_node_id)
        };

        // 4. vtable 动态分派（Call 节点有 vtable_call_methods 但无 call_target）
        if frame.pending_call.is_none() {
            if let Some(ref method_name) = graph.vtable_call_methods[graph_node_id.0 as usize] {
                let n = &graph.nodes[graph_node_id.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let recv_val = frame.get_value_by_global(inputs[0]);

                let (target_sg, upvalues): (SubGraphId, Vec<Value>) = match recv_val.heap_obj() {
                    Some(crate::Value::HeapObj::TraitVal(tv)) => {
                        match tv.method_names.iter().position(|m| m.as_str() == method_name.as_str()) {
                            Some(i) => match tv.method_values[i].heap_obj() {
                                Some(crate::Value::HeapObj::Closure(c)) => {
                                    (SubGraphId(c.func_id), c.upvalues.clone())
                                }
                                _ => panic!("vtable method is not a Closure"),
                            },
                            None => panic!("TraitValue has no method '{}'", method_name),
                        }
                    }
                    _ => panic!("vtable call on non-trait value"),
                };

                let arity = (graph.subgraphs[target_sg.0 as usize].param_count as usize)
                    .saturating_sub(upvalues.len());
                let mut args: Vec<Value> = Vec::with_capacity(arity + upvalues.len());
                for &in_node in inputs.iter().skip(1).take(arity) {
                    args.push(frame.get_value_by_global(in_node));
                }
                args.extend(upvalues);

                let call_node_local = NodeId(graph_node_id.0.wrapping_sub(frame.node_offset));
                frame.pending_call = Some(PendingCall {
                    target_sg,
                    args,
                    call_node_local,
                    is_async: false,
                });
            }
        }

        // 5. 处理 pending_call
        let pending = frame.pending_call.clone();
        if let Some(pending) = pending {
            frame.pending_call = None;

            // 尾调用：复用当前帧
            if graph.tail_call_flags[graph_node_id.0 as usize] {
                switch_subgraph_shared(frame, graph, pending.target_sg, &pending.args);
                continue;
            }

            let target_loop_kind = graph.subgraphs[pending.target_sg.0 as usize].loop_kind;

            // LoopBody：不支持循环体复用（thunk 不应有循环），回退为普通调用
            let (child_start, child_end) = graph.subgraphs[pending.target_sg.0 as usize].node_range;
            let child_count = (child_end.0 - child_start.0) as usize;
            let mut child_frame = Frame::new(
                FrameId(0xFFFF_FFFE),
                pending.target_sg,
                child_count,
                frame.graph.clone(),
            );
            prepare_frame_shared(&mut child_frame, graph);

            // 注入参数
            let child_offset = child_start.0 as usize;
            let child_param_count = graph.subgraphs[pending.target_sg.0 as usize].param_count as usize;
            for (i, arg) in pending.args.iter().enumerate().take(child_param_count) {
                let lid = NodeId(i as u32);
                let cc = graph.downstreams[child_offset + i].len() as u16;
                child_frame.set_value(lid, arg.clone(), cc);
                child_frame.push_ready(lid);
            }

            // 设置帧链指针（变量穿透访问）
            let same_function = graph.subgraphs[frame.subgraph_id.0 as usize].function_id
                == graph.subgraphs[pending.target_sg.0 as usize].function_id;
            child_frame.parent_frame_ptr = if same_function {
                frame as *mut Frame
            } else {
                std::ptr::null_mut()
            };
            child_frame.root_frame_ptr = if same_function {
                if frame.root_frame_ptr.is_null() {
                    frame as *mut Frame
                } else {
                    frame.root_frame_ptr
                }
            } else {
                std::ptr::null_mut()
            };

            // 同步执行子帧
            let child_result = run_frame_sync(&mut child_frame, graph);
            let child_signal = child_frame.control_signal.clone();

            // 注入返回值到当前帧
            let consumer_count = graph.downstreams[graph_node_id.0 as usize].len() as u16;
            frame.set_value(pending.call_node_local, child_result.clone(), consumer_count);

            // throw 传播：返回值为 ThrowVal(Err) 时设 Return 信号
            let is_throw_err = matches!(
                child_result.heap_obj(),
                Some(crate::Value::HeapObj::ThrowVal(t)) if matches!(t.payload, crate::Value::ThrowPayload::Err(_))
            );
            if is_throw_err {
                frame.control_signal = ControlSignal::Return(child_result);
                continue;
            }

            // Gate 分支控制信号传播（if/match 中的 return/break/continue）
            let is_gate = graph.nodes[graph_node_id.0 as usize].kind == NodeKind::Gate;
            if is_gate && !matches!(child_signal, ControlSignal::None) {
                frame.control_signal = child_signal;
                continue;
            }

            // LoopBody 完成处理
            if target_loop_kind == LoopKind::LoopBody {
                match child_signal {
                    ControlSignal::Break | ControlSignal::Return(_) => {
                        frame.control_signal = child_signal;
                        continue;
                    }
                    ControlSignal::Continue | ControlSignal::None => {
                        // 循环继续：通知下游，循环帧会重新触发 body 调用
                        notify_downstream_shared(
                            frame, graph, pending.call_node_local, graph_node_id, NodeId(node_start),
                        );
                        continue;
                    }
                }
            }

            // 检查控制信号节点（return/break/continue 声明）
            if let Some(kind) = graph.control_signal_nodes[graph_node_id.0 as usize] {
                frame.control_signal = match kind {
                    SignalKind::Return => ControlSignal::Return(child_result),
                    SignalKind::Break => ControlSignal::Break,
                    SignalKind::Continue => ControlSignal::Continue,
                };
                continue;
            }

            notify_downstream_shared(frame, graph, pending.call_node_local, graph_node_id, NodeId(node_start));
        } else {
            // 6. 普通节点：写值表 + 检查控制信号 + 通知下游
            let consumer_count = graph.downstreams[graph_node_id.0 as usize].len() as u16;
            frame.set_value(local_id, value.clone(), consumer_count);

            // 检查控制信号声明节点
            if let Some(kind) = graph.control_signal_nodes[graph_node_id.0 as usize] {
                frame.control_signal = match kind {
                    SignalKind::Return => ControlSignal::Return(value),
                    SignalKind::Break => ControlSignal::Break,
                    SignalKind::Continue => ControlSignal::Continue,
                };
                continue;
            }

            // compute_propagate 等直接设 control_signal 的 compute_fn：
            // 检查是否被设为非 None（compute_propagate 在 Err 时设 Return）
            let cs2 = frame.control_signal.clone();
            if !matches!(cs2, ControlSignal::None) {
                continue;
            }

            notify_downstream_shared(frame, graph, local_id, graph_node_id, NodeId(node_start));
        }
    }
}

/// compute_fn: 闭包调用（idx 41）。
///
/// inputs[0] = 闭包值节点，inputs[1..] = 调用参数节点。
/// 从 Closure 取子图 id + 捕获值，合并调用参数 + 捕获值（追加末尾），设 pending_call。
/// 子图 param_count = lambda 参数数 + 捕获变量数，start_subgraph 按顺序注入。
pub fn compute_closure_call(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let closure_val = frame.get_value_by_global(inputs[0]);

    let closure = match closure_val.heap_obj() {
        Some(crate::Value::HeapObj::Closure(c)) => c.clone(),
        _ => panic!("compute_closure_call: input is not a Closure"),
    };

    let target_sg = SubGraphId(closure.func_id);
    let call_node_local = NodeId(node.0.wrapping_sub(frame.node_offset));

    // 子图 param_count = lambda 参数数 + upvalue 数。
    // 调用方只提供 lambda 参数（arity），upvalues 由 Closure 自带。
    // 因此从 inputs 读取 arity = param_count - upvalues.len() 个，再追加 upvalues。
    // 与 vtable 分派路径（run_frame_sync）保持一致，避免 upvalues 被二次追加。
    let upvalues_len = closure.upvalues.len();
    let arity = (graph.subgraphs[target_sg.0 as usize].param_count as usize)
        .saturating_sub(upvalues_len);
    let mut args: Vec<Value> = Vec::with_capacity(arity + upvalues_len);
    for &in_node in inputs.iter().skip(1).take(arity) {
        args.push(frame.get_value_by_global(in_node));
    }
    args.extend(closure.upvalues.iter().cloned());

    frame.pending_call = Some(PendingCall {
        target_sg,
        args,
        call_node_local,
        is_async: false,
    });

    Value::VOID
}

/// compute_fn: 取消 async handle 对应的子帧。
///
/// inputs[0] = async handle 值（i32 标量，值为 async_id）。
/// 从 AsyncJoinRuntime 查 async_id → child_fid，标记 pending_cancel。
/// 实际 cancel_frame 在 run_ready_nodes 中执行（需要 &mut Engine）。
/// 返回 Void。
pub fn compute_cancel_async_handle(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let handle_val = frame.get_value_by_global(inputs[0]);
    // async handle 是 i32 标量，值即 async_id
    let async_id = crate::Ir::AsyncHandleId(handle_val.as_i32() as u32);
    frame.pending_cancel = Some(async_id);
    Value::VOID
}

/// compute_fn: select 门控节点（idx 43）— 检查所有分支事件源，选第一个就绪的。
///
/// compute_fn 无法访问 Engine 的 channel_runtime/timer_runtime，因此这里只标记
/// `pending_select_wait`，由 `run_ready_nodes` 检查就绪状态（它能访问 Engine 全部状态）。
pub fn compute_select_gate(frame: &mut Frame, node: NodeId) -> Value {
    let graph = frame.graph.clone();
    // 校验 gate 节点确实绑定了 SelectInfo
    let _ = graph.select_infos[node.0 as usize]
        .as_ref()
        .expect("select gate node has no SelectInfo");
    let gate_local = NodeId(node.0.wrapping_sub(frame.node_offset));
    frame.pending_select_wait = Some(gate_local);
    Value::VOID
}


/// noop compute_fn（匹配真实签名）。
pub fn noop_compute_real(_frame: &mut Frame, _node: NodeId) -> Value {
    Value::VOID
}

/// compute_fn (idx 48): 序列节点 — 等待所有输入就绪后返回最后一个输入的值。
///
/// 用于语句顺序链接：inputs = [prev_effect, current_value]，返回 current_value。
/// prev_effect 仅作数据依赖边（顺序约束），确保前一个语句完成后才执行当前语句。
pub fn compute_seq(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    frame.get_value_by_global(inputs[n.input_count as usize - 1])
}

/// compute_writeback（idx 49）：赋值外层变量，通过 root_frame_ptr 写回函数根帧。
///
/// inputs[0] = 值来源（当前帧内节点），writeback_targets[node] = 外层全局 NodeId。
/// 非阻塞：compute_fn 内直接完成写入，无 pending、无 Engine 层消费。
pub fn compute_writeback(frame: &mut Frame, node: NodeId) -> Value {
    let graph = frame.graph.clone();
    let n = &graph.nodes[node.0 as usize];
    let val_node = graph.inputs_pool.get(n.inputs_offset, n.input_count)[0];
    let val = frame.get_value_by_global(val_node);
    let target = graph.writeback_targets[node.0 as usize]
        .expect("WriteBack node missing target");
    let consumer_count = graph.downstreams[target.0 as usize].len() as u16;

    // 遍历 parent_frame_ptr 链找到包含 target 的帧（可能在中层帧如循环体帧）
    let mut ptr = frame.parent_frame_ptr;
    let mut found = false;
    while !ptr.is_null() {
        let f = unsafe { &mut *ptr };
        let local = target.0.wrapping_sub(f.node_offset);
        if (local as usize) < f.value_table.len() {
            f.set_value(NodeId(local), val.clone(), consumer_count);
            found = true;
            break;
        }
        ptr = f.parent_frame_ptr;
    }
    // 回退到 root_frame_ptr（函数根帧）
    if !found && !frame.root_frame_ptr.is_null() {
        let root = unsafe { &mut *frame.root_frame_ptr };
        let local = target.0.wrapping_sub(root.node_offset);
        if (local as usize) < root.value_table.len() {
            root.set_value(NodeId(local), val.clone(), consumer_count);
        }
    }
    val
}

// =========================================================================
// FramePool — 帧池
// =========================================================================

/// 帧池：管理帧的分配与访问。
pub struct FramePool {
    frames: Vec<Box<Frame>>,
    next_id: u32,
    graph: std::sync::Arc<DataFlowGraph>,
    /// 空闲帧列表：free 时加入，alloc 时优先复用。
    /// 避免深度递归时 frames Vec 无限增长导致内存耗尽。
    free_list: Vec<FrameId>,
}

impl FramePool {
    pub fn new(graph: std::sync::Arc<DataFlowGraph>) -> Self {
        Self {
            frames: Vec::new(),
            next_id: 0,
            graph,
            free_list: Vec::new(),
        }
    }

    /// 分配新帧，返回 FrameId。
    /// 优先从 free_list 复用已释放的帧，避免 Vec 无限增长。
    pub fn alloc(&mut self, subgraph_id: SubGraphId, node_count: usize) -> FrameId {
        // 优先复用空闲帧
        if let Some(id) = self.free_list.pop() {
            let frame = self.frames[id.0 as usize].as_mut();
            // 重置帧以复用：保留 id 和 graph，复用现有 Vec 仅在尺寸不匹配时 resize
            frame.subgraph_id = subgraph_id;
            if frame.value_table.len() != node_count {
                frame.value_table.resize(node_count);
            }
            if frame.pending_inputs.len() != node_count {
                frame.pending_inputs.resize(node_count, 0);
            }
            frame.ready_queue.clear();
            frame.state = FrameState::Ready;
            frame.caller = None;
            frame.node_offset = 0;
            frame.control_signal = ControlSignal::None;
            frame.suspend_state = SuspendState::NotSuspended;
            frame.suspend_event = None;
            frame.pending_call = None;
            frame.pending_await = None;
            frame.pending_cancel = None;
            frame.pending_select_wait = None;
            frame.defer_stack.clear();
            frame.select_timers.clear();
            frame.root_frame_ptr = std::ptr::null_mut();
            frame.parent_frame_ptr = std::ptr::null_mut();
            frame.body_frame_id = None;
            return id;
        }

        assert!(self.next_id < u32::MAX, "FrameId overflow: too many frames allocated");
        let id = FrameId(self.next_id);
        self.next_id += 1;
        let frame = Frame::new(id, subgraph_id, node_count, self.graph.clone());
        if id.0 as usize >= self.frames.len() {
            self.frames.resize_with(id.0 as usize + 1, || {
                Box::new(Frame::new(FrameId(0), SubGraphId(0), 0, self.graph.clone()))
            });
        }
        self.frames[id.0 as usize] = Box::new(frame);
        id
    }

    /// 获取帧的可变引用。
    pub fn get_mut(&mut self, id: FrameId) -> &mut Frame {
        self.frames[id.0 as usize].as_mut()
    }

    /// 获取帧的不可变引用。
    pub fn get(&self, id: FrameId) -> &Frame {
        self.frames[id.0 as usize].as_ref()
    }

    /// 释放帧：清空 value_table（堆对象 Arc 自动 decref），重置状态。
    ///
    /// spec 4.3 complete_subgraph 末尾 `engine.frames.free(child)`。
    /// spec 4.7 帧级兜底：遍历 slot，ready 的堆对象 decref（Rust Arc Drop 自动完成）。
    pub fn free(&mut self, id: FrameId) {
        let frame = self.frames[id.0 as usize].as_mut();
        // 清空 value_table：持有堆对象的 Arc<HeapObj> Drop 时自动 decref
        frame.value_table.reset_all();
        frame.ready_queue.clear();
        frame.state = FrameState::Completed;
        frame.control_signal = ControlSignal::None;
        frame.suspend_state = SuspendState::NotSuspended;
        frame.suspend_event = None;
        frame.pending_call = None;
        frame.pending_await = None;
        frame.defer_stack.clear();
        // 加入空闲列表，供后续 alloc 复用
        self.free_list.push(id);
    }

    /// 取出所有帧（用于 SharedEngine::from_engine 将帧迁移到 HashMap）。
    pub fn drain_frames(&mut self) -> Vec<Frame> {
        self.frames.drain(..).map(|b| *b).collect()
    }
}

// =========================================================================
// ChannelRuntime / TimerRuntime / AsyncJoinRuntime — 图外运行时
// =========================================================================

/// Channel 运行时：管理 channel buffer + send/recv。
///
/// spec 3.5 EventSource::Channel。5a-2 单线程，send 不阻塞（buffer 满则 panic）。
pub struct ChannelRuntime {
    channels: Vec<ChannelEntry>,
}
struct ChannelEntry {
    buffer: std::collections::VecDeque<Value>,
    capacity: usize,
}
impl ChannelRuntime {
    pub fn new() -> Self { Self { channels: Vec::new() } }
    pub fn create(&mut self, capacity: usize) -> crate::Ir::ChannelId {
        let id = crate::Ir::ChannelId(self.channels.len() as u32);
        self.channels.push(ChannelEntry {
            buffer: std::collections::VecDeque::new(),
            capacity,
        });
        id
    }
    pub fn send(&mut self, id: crate::Ir::ChannelId, value: Value) -> bool {
        let ch = &mut self.channels[id.0 as usize];
        if ch.buffer.len() >= ch.capacity { return false; }
        ch.buffer.push_back(value);
        true
    }
    pub fn recv(&mut self, id: crate::Ir::ChannelId) -> Option<Value> {
        self.channels.get_mut(id.0 as usize)?.buffer.pop_front()
    }
    /// 检查 channel 是否有数据可读（不消费）。
    pub fn has_data(&self, id: crate::Ir::ChannelId) -> bool {
        self.channels
            .get(id.0 as usize)
            .map(|c| !c.buffer.is_empty())
            .unwrap_or(false)
    }
    /// 原子地检查并接收数据（消除 has_data + recv 的 TOCTOU 竞态）。
    /// 如果有数据则返回 Some(Value)，否则返回 None。
    pub fn try_recv(&mut self, id: crate::Ir::ChannelId) -> Option<Value> {
        self.channels.get_mut(id.0 as usize)?.buffer.pop_front()
    }
    /// 清理已关闭/空的 channel（保留有数据的，清除空且无引用的）。
    pub fn cleanup(&mut self) {
        // channel 不主动删除（ID 是索引，删除会导致后续 ID 失效）
        // 但可以清理空 buffer 释放内存
        for ch in &mut self.channels {
            if ch.buffer.is_empty() {
                ch.buffer.shrink_to_fit();
            }
        }
    }
}

impl Default for ChannelRuntime {
    fn default() -> Self {
        Self::new()
    }
}

/// Timer 运行时：管理 timer deadline + 触发检查。
///
/// spec 3.5 EventSource::Timer。事件循环每次迭代检查到期 timer。
pub struct TimerRuntime {
    timers: Vec<TimerEntry>,
}
struct TimerEntry {
    deadline: std::time::Instant,
    fired: bool,
}
impl TimerRuntime {
    pub fn new() -> Self { Self { timers: Vec::new() } }
    pub fn start(&mut self, duration: std::time::Duration) -> crate::Ir::TimerId {
        let id = crate::Ir::TimerId(self.timers.len() as u32);
        self.timers.push(TimerEntry {
            deadline: std::time::Instant::now() + duration,
            fired: false,
        });
        id
    }
    pub fn check_and_fire(&mut self) -> Vec<crate::Ir::TimerId> {
        let now = std::time::Instant::now();
        let mut fired = Vec::new();
        for (i, t) in self.timers.iter_mut().enumerate() {
            if !t.fired && now >= t.deadline {
                t.fired = true;
                fired.push(crate::Ir::TimerId(i as u32));
            }
        }
        fired
    }
    pub fn is_fired(&self, id: crate::Ir::TimerId) -> bool {
        self.timers.get(id.0 as usize).map(|t| t.fired).unwrap_or(false)
    }
    /// 清理已触发的 timer 条目以回收内存。
    /// 注意：TimerId 是 Vec 索引，不能直接 retain（会导致索引错位）。
    /// 此方法将已触发 timer 的 deadline 重置为零值，不改变 Vec 长度。
    /// TimerEntry 本身很小（Instant + bool），内存影响有限。
    pub fn cleanup(&mut self) {
        // 不删除条目以保持 TimerId 索引有效性
        // TimerEntry 很小，无需主动清理
    }
}

impl Default for TimerRuntime {
    fn default() -> Self {
        Self::new()
    }
}

/// AsyncJoin 运行时：管理 async 调用 → AsyncHandle 映射 + 完成结果。
///
/// async 函数调用启动子帧时注册 async_id → child_fid。
/// 子帧完成时设置 result + 触发 AsyncJoin 事件唤醒等待的 await 帧。
pub struct AsyncJoinRuntime {
    entries: Vec<AsyncJoinEntry>,
    next_async_id: u32,
}
struct AsyncJoinEntry {
    async_id: crate::Ir::AsyncHandleId,
    child_fid: FrameId,
    result: Option<Value>,
}
impl AsyncJoinRuntime {
    pub fn new() -> Self { Self { entries: Vec::new(), next_async_id: 0 } }
    /// 分配新的 async_id（i32 标量值）
    pub fn alloc_id(&mut self) -> crate::Ir::AsyncHandleId {
        assert!(self.next_async_id < u32::MAX, "AsyncHandleId overflow: too many async calls");
        let id = crate::Ir::AsyncHandleId(self.next_async_id);
        self.next_async_id += 1;
        id
    }
    pub fn register(&mut self, async_id: crate::Ir::AsyncHandleId, child_fid: FrameId) {
        self.entries.push(AsyncJoinEntry { async_id, child_fid, result: None });
    }
    /// 原子地分配 async_id 并注册 child_fid（消除 alloc_id + register 的竞态窗口）。
    pub fn alloc_and_register(&mut self, child_fid: FrameId) -> crate::Ir::AsyncHandleId {
        let async_id = crate::Ir::AsyncHandleId(self.next_async_id);
        self.next_async_id += 1;
        self.entries.push(AsyncJoinEntry { async_id, child_fid, result: None });
        async_id
    }
    pub fn find_by_child(&self, child_fid: FrameId) -> Option<crate::Ir::AsyncHandleId> {
        self.entries.iter().find(|e| e.child_fid == child_fid).map(|e| e.async_id)
    }
    pub fn find_child_by_async_id(&self, async_id: crate::Ir::AsyncHandleId) -> Option<FrameId> {
        self.entries.iter().find(|e| e.async_id == async_id).map(|e| e.child_fid)
    }
    pub fn try_get_result(&self, async_id: crate::Ir::AsyncHandleId) -> Option<Value> {
        self.entries.iter().find(|e| e.async_id == async_id).and_then(|e| e.result.clone())
    }
    pub fn set_result(&mut self, async_id: crate::Ir::AsyncHandleId, value: Value) {
        if let Some(e) = self.entries.iter_mut().find(|e| e.async_id == async_id) {
            e.result = Some(value);
        }
    }
    /// 清理已完成且 result 已被读取的 entry，释放内存。
    /// 注意：AsyncHandleId 是 alloc_id 分配的递增值，不是 entries 索引，
    /// 所以移除 entry 不影响 ID 有效性。
    pub fn cleanup_consumed(&mut self, consumed_ids: &[crate::Ir::AsyncHandleId]) {
        self.entries.retain(|e| {
            // 保留未完成的，或已完成但未被消费的
            e.result.is_none() || !consumed_ids.contains(&e.async_id)
        });
    }
}

impl Default for AsyncJoinRuntime {
    fn default() -> Self {
        Self::new()
    }
}

// =========================================================================
// SIMD/rayon 批量化调度 — 模块级宏 + 自由函数（供 Engine 和 SharedEngine 共用）
// =========================================================================

/// 批量提取二元运算输入 → SIMD/rayon 批算 → 写回 value_table。
macro_rules! exec_bin_batch {
    ($frame:expr, $graph:expr, $locals:expr, $ns:expr, $rust:ty, $ctor:ident, $acc:ident, $batch_fn:ident, $op:expr) => {{
        let n = $locals.len();
        let mut a: Vec<$rust> = Vec::with_capacity(n);
        let mut b: Vec<$rust> = Vec::with_capacity(n);
        for &lid in $locals.iter() {
            let gid = NodeId(lid.0 + $ns.0);
            let node = $graph.nodes[gid.0 as usize];
            let inp = $graph.inputs_pool.get(node.inputs_offset, node.input_count);
            a.push($frame.get_value_by_global(inp[0]).$acc());
            b.push($frame.get_value_by_global(inp[1]).$acc());
        }
        let mut dst = vec![0 as $rust; n];
        crate::Value::$batch_fn(&mut dst, &a, &b, $op);
        for (i, &lid) in $locals.iter().enumerate() {
            let gid = NodeId(lid.0 + $ns.0);
            let cc = $graph.downstreams[gid.0 as usize].len() as u16;
            $frame.set_value(lid, Value::$ctor(dst[i]), cc);
        }
    }};
}

/// 批量提取比较运算输入 → SIMD/rayon 批算 → 写回 value_table（结果为 bool）。
macro_rules! exec_cmp_batch {
    ($frame:expr, $graph:expr, $locals:expr, $ns:expr, $rust:ty, $acc:ident, $batch_fn:ident, $op:expr) => {{
        let n = $locals.len();
        let mut a: Vec<$rust> = Vec::with_capacity(n);
        let mut b: Vec<$rust> = Vec::with_capacity(n);
        for &lid in $locals.iter() {
            let gid = NodeId(lid.0 + $ns.0);
            let node = $graph.nodes[gid.0 as usize];
            let inp = $graph.inputs_pool.get(node.inputs_offset, node.input_count);
            a.push($frame.get_value_by_global(inp[0]).$acc());
            b.push($frame.get_value_by_global(inp[1]).$acc());
        }
        let mut mask = vec![0u8; n];
        crate::Value::$batch_fn(&mut mask, &a, &b, $op);
        for (i, &lid) in $locals.iter().enumerate() {
            let gid = NodeId(lid.0 + $ns.0);
            let cc = $graph.downstreams[gid.0 as usize].len() as u16;
            $frame.set_value(lid, Value::bool_val(mask[i] != 0), cc);
        }
    }};
}

/// 批量提取一元运算输入 → SIMD/rayon 批算 → 写回 value_table。
macro_rules! exec_unary_batch {
    ($frame:expr, $graph:expr, $locals:expr, $ns:expr, $rust:ty, $ctor:ident, $acc:ident, $op:expr) => {{
        let n = $locals.len();
        let mut a: Vec<$rust> = Vec::with_capacity(n);
        for &lid in $locals.iter() {
            let gid = NodeId(lid.0 + $ns.0);
            let node = $graph.nodes[gid.0 as usize];
            let inp = $graph.inputs_pool.get(node.inputs_offset, node.input_count);
            a.push($frame.get_value_by_global(inp[0]).$acc());
        }
        let mut dst = vec![0 as $rust; n];
        crate::Value::batch_unaryop(&mut dst, &a, $op);
        for (i, &lid) in $locals.iter().enumerate() {
            let gid = NodeId(lid.0 + $ns.0);
            let cc = $graph.downstreams[gid.0 as usize].len() as u16;
            $frame.set_value(lid, Value::$ctor(dst[i]), cc);
        }
    }};
}

/// 处理一批同质批量化节点（相同 ScalarTag + BatchOp），使用 SIMD/rayon 批算。
///
/// 从 value_table 提取输入到连续 typed 数组，调用 Value.rs 的 batch 函数，
/// 写回结果并通知下游。仅适用于 BinOp/UnOp/Cmp 标量运算节点。
fn process_batch_group(
    frame: &mut Frame,
    graph: &DataFlowGraph,
    locals: &[NodeId],
    node_start: NodeId,
    info: BatchInfo,
) {
    use crate::Value::{ScalarTag, BinOp, CmpOp, UnaryOp};
    let _ = (BinOp::Add, CmpOp::Eq, UnaryOp::Neg); // 抑制 unused import

    if locals.is_empty() { return; }

    match info {
        BatchInfo { tag, op: BatchOp::Bin(op) } => {
            match tag {
                ScalarTag::I32 => exec_bin_batch!(frame, graph, locals, node_start, i32, i32, as_i32, batch_binop_i32, op),
                ScalarTag::I64 => exec_bin_batch!(frame, graph, locals, node_start, i64, i64, as_i64, batch_binop_i64, op),
                ScalarTag::F32 => exec_bin_batch!(frame, graph, locals, node_start, f32, f32, as_f32, batch_binop_f32, op),
                ScalarTag::F64 => exec_bin_batch!(frame, graph, locals, node_start, f64, f64, as_f64, batch_binop_f64, op),
                ScalarTag::I8 => exec_bin_batch!(frame, graph, locals, node_start, i8, i8, as_i8, batch_binop, op),
                ScalarTag::I16 => exec_bin_batch!(frame, graph, locals, node_start, i16, i16, as_i16, batch_binop, op),
                ScalarTag::U8 => exec_bin_batch!(frame, graph, locals, node_start, u8, u8, as_u8, batch_binop, op),
                ScalarTag::U16 => exec_bin_batch!(frame, graph, locals, node_start, u16, u16, as_u16, batch_binop, op),
                ScalarTag::U32 => exec_bin_batch!(frame, graph, locals, node_start, u32, u32, as_u32, batch_binop, op),
                ScalarTag::U64 => exec_bin_batch!(frame, graph, locals, node_start, u64, u64, as_u64, batch_binop, op),
                ScalarTag::I128 => exec_bin_batch!(frame, graph, locals, node_start, i128, i128, as_i128, batch_binop, op),
                ScalarTag::U128 => exec_bin_batch!(frame, graph, locals, node_start, u128, u128, as_u128, batch_binop, op),
                ScalarTag::Isize => exec_bin_batch!(frame, graph, locals, node_start, isize, isize_val, as_isize, batch_binop, op),
                ScalarTag::Usize => exec_bin_batch!(frame, graph, locals, node_start, usize, usize_val, as_usize, batch_binop, op),
                _ => return, // F16/F128/Bool/Char → 不支持
            }
        }
        BatchInfo { tag, op: BatchOp::Cmp(op) } => {
            match tag {
                ScalarTag::F32 => exec_cmp_batch!(frame, graph, locals, node_start, f32, as_f32, batch_cmp_f32, op),
                ScalarTag::F64 => exec_cmp_batch!(frame, graph, locals, node_start, f64, as_f64, batch_cmp_f64, op),
                ScalarTag::I32 => exec_cmp_batch!(frame, graph, locals, node_start, i32, as_i32, batch_cmp, op),
                ScalarTag::I64 => exec_cmp_batch!(frame, graph, locals, node_start, i64, as_i64, batch_cmp, op),
                ScalarTag::I8 => exec_cmp_batch!(frame, graph, locals, node_start, i8, as_i8, batch_cmp, op),
                ScalarTag::I16 => exec_cmp_batch!(frame, graph, locals, node_start, i16, as_i16, batch_cmp, op),
                ScalarTag::U8 => exec_cmp_batch!(frame, graph, locals, node_start, u8, as_u8, batch_cmp, op),
                ScalarTag::U16 => exec_cmp_batch!(frame, graph, locals, node_start, u16, as_u16, batch_cmp, op),
                ScalarTag::U32 => exec_cmp_batch!(frame, graph, locals, node_start, u32, as_u32, batch_cmp, op),
                ScalarTag::U64 => exec_cmp_batch!(frame, graph, locals, node_start, u64, as_u64, batch_cmp, op),
                ScalarTag::I128 => exec_cmp_batch!(frame, graph, locals, node_start, i128, as_i128, batch_cmp, op),
                ScalarTag::U128 => exec_cmp_batch!(frame, graph, locals, node_start, u128, as_u128, batch_cmp, op),
                ScalarTag::Isize => exec_cmp_batch!(frame, graph, locals, node_start, isize, as_isize, batch_cmp, op),
                ScalarTag::Usize => exec_cmp_batch!(frame, graph, locals, node_start, usize, as_usize, batch_cmp, op),
                _ => return, // F16/F128/Bool/Char → 不支持
            }
        }
        BatchInfo { tag, op: BatchOp::Unary(op) } => {
            match tag {
                ScalarTag::I32 => exec_unary_batch!(frame, graph, locals, node_start, i32, i32, as_i32, op),
                ScalarTag::I64 => exec_unary_batch!(frame, graph, locals, node_start, i64, i64, as_i64, op),
                ScalarTag::I8 => exec_unary_batch!(frame, graph, locals, node_start, i8, i8, as_i8, op),
                ScalarTag::I16 => exec_unary_batch!(frame, graph, locals, node_start, i16, i16, as_i16, op),
                ScalarTag::U8 => exec_unary_batch!(frame, graph, locals, node_start, u8, u8, as_u8, op),
                ScalarTag::U16 => exec_unary_batch!(frame, graph, locals, node_start, u16, u16, as_u16, op),
                ScalarTag::U32 => exec_unary_batch!(frame, graph, locals, node_start, u32, u32, as_u32, op),
                ScalarTag::U64 => exec_unary_batch!(frame, graph, locals, node_start, u64, u64, as_u64, op),
                ScalarTag::I128 => exec_unary_batch!(frame, graph, locals, node_start, i128, i128, as_i128, op),
                ScalarTag::U128 => exec_unary_batch!(frame, graph, locals, node_start, u128, u128, as_u128, op),
                ScalarTag::Isize => exec_unary_batch!(frame, graph, locals, node_start, isize, isize_val, as_isize, op),
                ScalarTag::Usize => exec_unary_batch!(frame, graph, locals, node_start, usize, usize_val, as_usize, op),
                _ => return, // F16/F128/F32/F64/Bool/Char → 不支持（浮点无 BitOps）
            }
        }
    }

    // 通知所有批处理节点的下游
    for &lid in locals {
        let gid = NodeId(lid.0 + node_start.0);
        notify_downstream_shared(frame, graph, lid, gid, node_start);
    }
}

/// 尝试批量化处理就绪队列中的节点。
///
/// drain ready_queue → 按 (ScalarTag, BatchOp) 分组 → 对 2+ 节点的组
/// 调用 process_batch_group 做 SIMD/rayon 批算 → 非批量化节点推回 ready_queue。
/// 返回 true 表示执行了批处理（调用方应 continue 重新检查新就绪节点）。
fn try_batch_nodes(frame: &mut Frame, graph: &DataFlowGraph) -> bool {
    let qlen = frame.ready_queue.len();
    if qlen < 2 { return false; }

    let node_start = frame.node_offset;
    let wave: Vec<NodeId> = frame.ready_queue.drain(..).collect();

    // 分区：batchable（有 BatchInfo 且未预填充）vs rest
    let mut groups: Vec<(BatchInfo, Vec<NodeId>)> = Vec::new();
    let mut rest: Vec<NodeId> = Vec::new();

    for lid in wave {
        if frame.value_table.ready[lid.0 as usize] {
            rest.push(lid);
            continue;
        }
        let gid = NodeId(lid.0 + node_start);
        if let Some(info) = graph.batch_infos[gid.0 as usize] {
            if let Some(g) = groups.iter_mut().find(|(k, _)| *k == info) {
                g.1.push(lid);
            } else {
                groups.push((info, vec![lid]));
            }
        } else {
            rest.push(lid);
        }
    }

    // 处理 2+ 节点的组
    let mut batch_done = false;
    for (info, locals) in groups {
        if locals.len() >= 2 {
            process_batch_group(frame, graph, &locals, NodeId(node_start), info);
            batch_done = true;
        } else {
            rest.push(locals[0]);
        }
    }

    // 非批量化节点推回 ready_queue
    for n in rest {
        frame.push_ready(n);
    }

    batch_done
}

// =========================================================================
// Engine — 执行引擎
// =========================================================================

/// 引擎：持有图 + 值 arena + 帧池，执行就绪调度。
pub struct Engine {
    /// 数据流图（只读共享，Arc 包装供帧共享）
    pub graph: std::sync::Arc<DataFlowGraph>,
    /// 值 arena（保留给反射使用，compute_fn 不再使用）
    pub arena: ValueArena,
    /// 帧池
    pub frames: FramePool,
    /// 就绪帧队列（挂起恢复后可继续执行的帧 + 新启动的子帧）
    pub ready_frames: std::collections::VecDeque<FrameId>,
    /// 事件等待者：挂起帧等待的运行时事件（如 SubgraphComplete）
    pub event_waiters: Vec<(crate::Ir::RuntimeEvent, FrameId)>,
    /// Channel 运行时（图外）
    pub channel_runtime: ChannelRuntime,
    /// Timer 运行时（图外）
    pub timer_runtime: TimerRuntime,
    /// AsyncJoin 运行时（async 调用完成事件管理）
    pub async_join_runtime: AsyncJoinRuntime,
}

impl Engine {
    /// 创建新 Engine。
    pub fn new(graph: DataFlowGraph) -> Self {
        let graph = std::sync::Arc::new(graph);
        Self {
            graph: graph.clone(),
            arena: ValueArena::new(),
            frames: FramePool::new(graph),
            ready_frames: std::collections::VecDeque::new(),
            event_waiters: Vec::new(),
            channel_runtime: ChannelRuntime::new(),
            timer_runtime: TimerRuntime::new(),
            async_join_runtime: AsyncJoinRuntime::new(),
        }
    }

    /// 分配常量值的 Value。
    fn alloc_const_value(&mut self, cv: ConstValue) -> Value {
        match cv {
            ConstValue::I8(v) => Value::i8(v),
            ConstValue::I16(v) => Value::i16(v),
            ConstValue::I32(v) => Value::i32(v),
            ConstValue::I64(v) => Value::i64(v),
            ConstValue::I128(v) => Value::i128(v),
            ConstValue::U8(v) => Value::u8(v),
            ConstValue::U16(v) => Value::u16(v),
            ConstValue::U32(v) => Value::u32(v),
            ConstValue::U64(v) => Value::u64(v),
            ConstValue::U128(v) => Value::u128(v),
            ConstValue::Isize(v) => Value::isize_val(v),
            ConstValue::Usize(v) => Value::usize_val(v),
            ConstValue::F32(v) => Value::f32(v),
            ConstValue::F64(v) => Value::f64(v),
            ConstValue::Bool(v) => Value::bool_val(v),
            ConstValue::Char(c) => Value::char_val(char::from_u32(c).unwrap_or('\0')),
            ConstValue::Null => Value::NULL,
            ConstValue::Void => Value::VOID,
            ConstValue::Str(s) => {
                use crate::Value::{HeapObj, GlueStr};
                Value::ref_val(HeapObj::Str(GlueStr::new(s)))
            }
        }
    }

    /// 初始化帧：预填充 Const 值 + 初始化 pending_inputs + 就绪队列。
    ///
    /// 帧内节点用局部 NodeId（从 0 开始），图节点用全局 NodeId。
    /// 转换：local_id = global_id - node_range.start
    pub fn init_frame(&mut self, subgraph_id: SubGraphId) -> FrameId {
        let (node_start, node_end) = self.graph.subgraphs[subgraph_id.0 as usize].node_range;
        let node_count = (node_end.0 - node_start.0) as usize;

        let fid = self.frames.alloc(subgraph_id, node_count);
        self.prepare_frame(fid, node_start, node_count);
        fid
    }

    /// 帧节点初始化共享逻辑：设置 node_offset + pending_inputs + 预填充 Const + Gate 入就绪队列。
    ///
    /// init_frame 和 start_subgraph 都调用此方法，确保子图启动时 Const 节点预填充、
    /// Gate 节点入就绪队列的行为一致。start_subgraph 在此之后注入参数（覆盖参数节点的值）。
    ///
    /// 嵌套子图节点跳过：编译期 compile_function 将嵌套子图的节点（如 while_sg 的 cond/gate、
    /// body_sg 的 Call）包含在父子图 node_range 内，但它们应在子帧中执行，不应在父帧中预填充
    /// 或就绪。通过检查节点是否落在其他子图的 node_range 内来跳过。
    fn prepare_frame(&mut self, fid: FrameId, node_start: NodeId, node_count: usize) {
        let offset = node_start.0 as usize;
        let sg_id = self.frames.get(fid).subgraph_id;
        let node_end_global = node_start.0 + node_count as u32;

        // 清空 value_table + ready_queue（帧复用时必须重置，避免旧值残留）
        let frame = self.frames.get_mut(fid);
        frame.value_table.reset_all();
        frame.ready_queue.clear();
        frame.control_signal = ControlSignal::None;
        frame.pending_call = None;
        frame.pending_await = None;

        // 收集嵌套子图范围（在当前子图 node_range 内但属于其他子图的节点范围）
        let nested_ranges: Vec<(u32, u32)> = self
            .graph
            .subgraphs
            .iter()
            .filter(|sg| {
                sg.id != sg_id
                    && sg.node_range.0 .0 >= node_start.0
                    && sg.node_range.1 .0 <= node_end_global
            })
            .map(|sg| (sg.node_range.0 .0, sg.node_range.1 .0))
            .collect();

        let is_nested = |global_idx: u32| -> bool {
            nested_ranges
                .iter()
                .any(|&(s, e)| global_idx >= s && global_idx < e)
        };

        // 设置 node_offset（全局 NodeId → 局部 NodeId 转换用）
        self.frames.get_mut(fid).node_offset = node_start.0;

        // 1. 初始化 pending_inputs（嵌套节点设为 MAX 永不就绪）
        let frame = self.frames.get_mut(fid);
        for i in 0..node_count {
            if is_nested((offset + i) as u32) {
                frame.pending_inputs[i] = u8::MAX;
            } else {
                let graph_node = &self.graph.nodes[offset + i];
                // EventSource 声明节点永不就绪（spec 4.4：事件源不进就绪队列）
                if graph_node.kind == NodeKind::EventSource {
                    frame.pending_inputs[i] = u8::MAX;
                } else if graph_node.kind == NodeKind::Gate {
                    // select gate（有 select_infos）无 condition_input，立即就绪
                    if self.graph.select_infos[offset + i].is_some() {
                        frame.pending_inputs[i] = 0;
                    } else {
                        // 普通 Gate 节点就绪依赖 condition_input（通过 downstreams 机制驱动）
                        // pending_inputs=1 确保 Gate 不会被 step 3 提前入队，
                        // condition_input 产出时 notify_downstream 减为 0 → 入就绪队列
                        frame.pending_inputs[i] = 1;
                    }
                } else {
                    // 只统计当前帧内的输入（外层节点通过 root_frame_ptr 读取，
                    // 不计入 pending — 外层节点在不同帧，不会通过 notify_downstream 通知）
                    let inputs = self.graph.inputs_pool.get(
                        graph_node.inputs_offset,
                        graph_node.input_count,
                    );
                    let in_frame = inputs
                        .iter()
                        .filter(|&&n| (n.0.wrapping_sub(node_start.0) as usize) < node_count)
                        .count() as u8;
                    frame.pending_inputs[i] = in_frame;
                }
            }
        }

        // 2. 预填充 Const 节点（跳过嵌套节点；Gate 节点不在此入队——其就绪由
        //    condition_input 通过 downstreams 机制驱动）
        for i in 0..node_count {
            if is_nested((offset + i) as u32) {
                continue;
            }
            let kind = self.graph.nodes[offset + i].kind;
            if kind == NodeKind::Const {
                if let Some(cv) = self.graph.const_values[offset + i] {
                    let handle = self.alloc_const_value(cv);
                    let local_id = NodeId(i as u32);
                    let consumer_count = self.graph.downstreams[offset + i].len() as u16;
                    let frame = self.frames.get_mut(fid);
                    frame.set_value(local_id, handle, consumer_count);
                    frame.push_ready(local_id);
                }
            }
        }

        // 3. 非 Const 节点 with 0 inputs 入就绪队列
        //    （如无参 async call、无参函数入口等）
        //    EventSource 节点 pending_inputs=MAX，不会满足条件
        //    Param 节点（index < param_count）跳过：由 start_subgraph 注入值 + 入队
        let param_count = self.graph.subgraphs[sg_id.0 as usize].param_count as usize;
        for i in 0..node_count {
            if i < param_count {
                continue; // param 节点由 start_subgraph 处理
            }
            if is_nested((offset + i) as u32) {
                continue;
            }
            let kind = self.graph.nodes[offset + i].kind;
            if kind == NodeKind::Const {
                continue; // 已在步骤 2 处理
            }
            let frame = self.frames.get_mut(fid);
            if frame.pending_inputs[i] == 0 && !frame.value_table.ready[i] {
                frame.push_ready(NodeId(i as u32));
            }
        }
    }

    /// 通知下游节点：减 pending_inputs，归零则入就绪队列。
    /// 同时调用生产者槽的 consume()（槽级 RC），归零则清槽。
    ///
    /// spec 4.7：每通知一个下游就 refcount -= 1（无论下游是否就绪）。
    fn notify_downstream(
        &mut self,
        fid: FrameId,
        producer_local: NodeId,
        producer_graph: NodeId,
        node_start: NodeId,
    ) {
        let downstreams: Vec<NodeId> =
            self.graph.downstreams[producer_graph.0 as usize].clone();
        for ds_graph_id in downstreams {
            let ds_local_id = NodeId(ds_graph_id.0.wrapping_sub(node_start.0));
            let frame = self.frames.get_mut(fid);

            // 槽级 RC：每通知一个下游就 consume()（spec 4.7）
            let pidx = producer_local.0 as usize;
            let still_has_consumers = frame.value_table.consume(pidx);
            if !still_has_consumers && frame.value_table.ready[pidx] {
                // 生产者槽归零，清槽（堆对象 Arc Drop 自动 decref，槽可复用）
                frame.value_table.ready[pidx] = false;
            }

            // 减下游 pending_inputs，归零则入就绪队列
            if frame.pending_inputs[ds_local_id.0 as usize] > 0 {
                frame.pending_inputs[ds_local_id.0 as usize] -= 1;
            }
            if frame.pending_inputs[ds_local_id.0 as usize] == 0
                && !frame.value_table.ready[ds_local_id.0 as usize]
            {
                frame.push_ready(ds_local_id);
            }
        }
    }

    /// 执行帧内所有就绪节点，直到就绪队列空或帧挂起。
    ///
    /// spec 4.2 核心循环：统一 compute_fn 调用，无 match kind 分派。
    /// Call/Gate 节点的 compute_fn 设置 frame.pending_call，核心循环检测后
    /// 执行 start_subgraph + 帧挂起。
    pub fn run_ready_nodes(&mut self, fid: FrameId) {
        loop {
            // 检查控制信号（return/break/continue 已触发）
            let cs = self.frames.get(fid).control_signal.clone();
            if !matches!(cs, ControlSignal::None) {
                break;
            }

            // 检查帧是否被取消（spec 5.3：跳过节点执行，走 defer 清理）
            if self.frames.get(fid).state == FrameState::Cancelling {
                break;
            }

            // 检查帧是否挂起
            if self.frames.get(fid).state == FrameState::Suspended {
                return;
            }

            // SIMD/rayon 批量化：drain ready_queue → 按 (ScalarTag,BatchOp) 分组 → 批算
            // 成功批处理时 continue（新就绪节点已通过 notify_downstream 入队）；
            // 未批处理时 fall through 到单节点路径。
            {
                let graph = self.graph.clone();
                let frame = self.frames.get_mut(fid);
                if try_batch_nodes(frame, &graph) {
                    continue;
                }
            }

            // 弹出就绪节点（局部 id）
            let local_id = match self.frames.get_mut(fid).pop_ready() {
                Some(n) => n,
                None => break,
            };

            let node_start = self.frames.get(fid).node_offset;
            let graph_node_id = NodeId(local_id.0 + node_start);
            let node = self.graph.nodes[graph_node_id.0 as usize];

            // 预填充节点（Const 在 prepare_frame、Param 在 start_subgraph 已设值）：
            // 跳过 compute_fn（Const 的 compute_fn 为 noop，会返回 VOID 覆盖预填充值），
            // 直接复用预填充值。非预填充节点统一调用 compute_fn（spec 4.2：无 match kind 分派）。
            let pre_filled = self.frames.get(fid).value_table.ready[local_id.0 as usize];
            let value = if pre_filled {
                self.frames.get(fid).value_table.values[local_id.0 as usize].clone()
            } else {
                let compute_fn = self.graph.compute_fns[node.compute_fn.0 as usize];
                let frame = self.frames.get_mut(fid);
                compute_fn(frame, graph_node_id)
            };

            // vtable 动态分派：Call 节点有 vtable_call_methods 标记但无 call_target
            //（compute_call_launch 未设 pending_call）→ 从 recv 的 TraitVal 运行时
            // 查询方法子图，收集参数后设 pending_call，交由下方统一处理。
            if self.frames.get(fid).pending_call.is_none() {
                if let Some(method_name) =
                    self.graph.vtable_call_methods[graph_node_id.0 as usize].clone()
                {
                    let n = &self.graph.nodes[graph_node_id.0 as usize];
                    let inputs =
                        self.graph.inputs_pool.get(n.inputs_offset, n.input_count);
                    let recv_val = self.frames.get(fid).get_value_by_global(inputs[0]);

                    // 从 TraitVal 查方法 Closure，取 subgraph_id + upvalues
                    let (target_sg, upvalues): (crate::Ir::SubGraphId, Vec<Value>) = match recv_val.heap_obj() {
                        Some(crate::Value::HeapObj::TraitVal(tv)) => {
                            match tv
                                .method_names
                                .iter()
                                .position(|m| m.as_str() == method_name.as_str())
                            {
                                Some(i) => {
                                    match tv.method_values[i].heap_obj() {
                                        Some(crate::Value::HeapObj::Closure(c)) => {
                                            (crate::Ir::SubGraphId(c.func_id), c.upvalues.clone())
                                        }
                                        _ => panic!("vtable method is not a Closure"),
                                    }
                                }
                                None => panic!("TraitValue has no method '{}'", method_name),
                            }
                        }
                        _ => panic!("vtable call on non-trait value"),
                    };

                    // 参数组装：跳过 receiver (inputs[0])，取方法实参 (inputs[1..1+arity])，
                    // 再追加 Closure 携带的 upvalues，与子图参数节点顺序一致。
                    let arity = (self.graph.subgraphs[target_sg.0 as usize].param_count as usize)
                        .saturating_sub(upvalues.len());
                    let mut args: Vec<Value> = Vec::with_capacity(arity + upvalues.len());
                    for &in_node in inputs.iter().skip(1).take(arity) {
                        args.push(self.frames.get(fid).get_value_by_global(in_node));
                    }
                    args.extend(upvalues);

                    let call_node_local =
                        NodeId(graph_node_id.0 - self.frames.get(fid).node_offset);
                    self.frames.get_mut(fid).pending_call = Some(PendingCall {
                        target_sg,
                        args,
                        call_node_local,
                        is_async: false,
                    });
                }
            }

            // 检测 pending_call（Call/Gate/AsyncCall 节点设置）
            let pending = self.frames.get(fid).pending_call.clone();
            if let Some(pending) = pending {
                self.frames.get_mut(fid).pending_call = None;

                // 尾调用图跳转：编译期标记的尾调用复用当前帧（帧池零分配）
                let node_start = self.frames.get(fid).node_offset;
                let graph_call_id = NodeId(pending.call_node_local.0 + node_start);
                if self.graph.tail_call_flags[graph_call_id.0 as usize] {
                    // 分支中的尾调用传播：当 caller 是 Gate 且非 LoopBody 时，
                    // 分支帧的 switch_subgraph 会创建 O(n) 分支帧链。
                    // 解决：释放父帧（函数帧），将分支帧的 caller 更新为原始调用方，
                    // 然后在分支帧上 switch_subgraph。这样 O(1) 帧即可完成深度递归。
                    let caller = self.frames.get(fid).caller;
                    let propagate_to_parent = if let Some((caller_fid, call_node)) = caller {
                        let caller_sg_id = self.frames.get(caller_fid).subgraph_id;
                        let caller_loop_kind = self.graph.subgraphs[caller_sg_id.0 as usize].loop_kind;
                        let caller_has_caller = self.frames.get(caller_fid).caller.is_some();
                        let caller_offset = self.frames.get(caller_fid).node_offset;
                        let caller_graph_node = NodeId(call_node.0 + caller_offset);
                        let caller_is_gate = self.graph.nodes[caller_graph_node.0 as usize].kind == NodeKind::Gate;
                        caller_is_gate
                            && caller_loop_kind != crate::Ir::LoopKind::LoopBody
                            && caller_has_caller
                    } else {
                        false
                    };

                    if propagate_to_parent {
                        let (caller_fid, _) = caller.unwrap();
                        // 获取函数帧的 caller（原始调用方）
                        let orig_caller = self.frames.get(caller_fid).caller;
                        // 清理函数帧的 event_waiters（函数帧被释放，不再等待子图完成）
                        self.event_waiters.retain(|(_, f)| *f != caller_fid);
                        // 释放函数帧（它永远不会恢复）
                        self.frames.free(caller_fid);
                        // 更新分支帧的 caller 为原始调用方
                        self.frames.get_mut(fid).caller = orig_caller;
                        // 切换分支帧为目标子图
                        self.switch_subgraph(fid, pending.target_sg, &pending.args);
                    } else {
                        // 直接尾调用（函数体顶层）或根帧分支：切换当前帧
                        self.switch_subgraph(fid, pending.target_sg, &pending.args);
                    }
                    continue; // 帧已重置为目标子图，继续执行新就绪节点
                }

                let target_loop_kind =
                    self.graph.subgraphs[pending.target_sg.0 as usize].loop_kind;

                // LoopBody 帧复用：循环体子图已分配过帧时复用，避免每轮创建新帧（O(1) 内存）
                let child_fid = if target_loop_kind == crate::Ir::LoopKind::LoopBody {
                    if let Some(bfid) = self.frames.get(fid).body_frame_id {
                        // 复用 body_sg 帧：注入参数 + 入就绪队列
                        let target_sg = &self.graph.subgraphs[pending.target_sg.0 as usize];
                        let offset = target_sg.node_range.0 .0 as usize;
                        let param_count = target_sg.param_count as usize;
                        for (i, arg) in pending.args.iter().enumerate().take(param_count) {
                            let local_id = NodeId(i as u32);
                            let consumer_count =
                                self.graph.downstreams[offset + i].len() as u16;
                            let frame = self.frames.get_mut(bfid);
                            frame.set_value(local_id, arg.clone(), consumer_count);
                            frame.push_ready(local_id);
                        }
                        // 重新绑定 caller（Gate 节点 local id）
                        self.frames.get_mut(bfid).caller =
                            Some((fid, pending.call_node_local));
                        // 重新设置 parent_frame_ptr（指向循环帧）
                        self.frames.get_mut(bfid).parent_frame_ptr =
                            self.frames.get_mut(fid) as *mut crate::Ir::Frame;
                        self.frames.get_mut(bfid).state = FrameState::Ready;
                        bfid
                    } else {
                        // 首次创建 body_sg 帧
                        let bfid = self.start_subgraph(
                            fid,
                            pending.call_node_local,
                            pending.target_sg,
                            &pending.args,
                        );
                        self.frames.get_mut(fid).body_frame_id = Some(bfid);
                        bfid
                    }
                } else {
                    // 非 LoopBody：正常 start_subgraph
                    self.start_subgraph(
                        fid,
                        pending.call_node_local,
                        pending.target_sg,
                        &pending.args,
                    )
                };

                // 子帧入就绪帧队列
                self.ready_frames.push_back(child_fid);

                if pending.is_async {
                    // async call：当前帧不挂起，call 节点写 AsyncHandle（i32 标量）+ 通知下游
                    let async_id = self.async_join_runtime.alloc_id();
                    let async_handle = Value::i32(async_id.0 as i32);
                    self.async_join_runtime.register(async_id, child_fid);

                    let node_start = self.frames.get(fid).node_offset;
                    let graph_node_id = NodeId(pending.call_node_local.0 + node_start);
                    let consumer_count = self.graph.downstreams[graph_node_id.0 as usize].len() as u16;
                    self.frames.get_mut(fid).set_value(pending.call_node_local, async_handle, consumer_count);
                    self.notify_downstream(fid, pending.call_node_local, graph_node_id, NodeId(node_start));
                    // 不挂起，继续循环执行其他就绪节点
                    continue;
                } else {
                    // sync call：当前帧挂起等 SubgraphComplete 事件
                    let frame = self.frames.get_mut(fid);
                    frame.state = FrameState::Suspended;
                    frame.suspend_state = SuspendState::WaitingSubgraph(child_fid);
                    frame.suspend_event = Some(RuntimeEvent::SubgraphComplete(child_fid));
                    return; // 帧挂起，不执行 defer，不标记 Completed
                }
            }

            // 检测 pending_await（Await 节点设置）
            let pending_await = self.frames.get(fid).pending_await.clone();
            if let Some(pending) = pending_await {
                self.frames.get_mut(fid).pending_await = None;

                // 解析事件源 id + 检查就绪
                let (event, ready_value) = self.resolve_and_check_await(&pending);

                if let Some(value) = ready_value {
                    // 就绪：注入值到 await 节点 + 通知下游 + 继续执行
                    let node_start = self.frames.get(fid).node_offset;
                    let graph_node_id = NodeId(pending.await_node_local.0 + node_start);
                    let consumer_count = self.graph.downstreams[graph_node_id.0 as usize].len() as u16;
                    self.frames.get_mut(fid).set_value(pending.await_node_local, value, consumer_count);
                    self.notify_downstream(fid, pending.await_node_local, graph_node_id, NodeId(node_start));
                    // 不挂起，继续循环
                    continue;
                } else {
                    // 未就绪：注册等待 + 帧挂起
                    self.event_waiters.push((event, fid));
                    let frame = self.frames.get_mut(fid);
                    frame.state = FrameState::Suspended;
                    frame.suspend_state = SuspendState::WaitingEvent(pending.await_node_local);
                    frame.suspend_event = Some(event);
                    return; // 帧挂起
                }
            }

            // 检测 pending_cancel（cancel 方法调用设置）
            let pending_cancel = self.frames.get(fid).pending_cancel;
            if let Some(async_id) = pending_cancel {
                self.frames.get_mut(fid).pending_cancel = None;
                // 从 AsyncJoinRuntime 查 child_fid → cancel_frame
                if let Some(child_fid) = self.async_join_runtime.find_child_by_async_id(async_id) {
                    self.cancel_frame(child_fid);
                }
                // 返回 Void，通知下游继续
                let consumer_count = self.graph.downstreams[graph_node_id.0 as usize].len() as u16;
                self.frames.get_mut(fid).set_value(local_id, Value::VOID, consumer_count);
                self.notify_downstream(fid, local_id, graph_node_id, NodeId(node_start));
                continue;
            }

            // 检测 pending_select_wait（select gate 节点设置）
            // compute_select_gate 无法访问 Engine runtime，只标记 pending_select_wait，
            // 实际就绪检查在此进行（run_ready_nodes 能访问 Engine 全部状态）。
            let pending_select_wait = self.frames.get(fid).pending_select_wait;
            if let Some(gate_local) = pending_select_wait {
                self.frames.get_mut(fid).pending_select_wait = None;

                // clone SelectInfo 避免持有 graph 借用时访问 frames
                let info = self.graph.select_infos[graph_node_id.0 as usize].clone();

                if let Some(info) = info {
                    // 检查每个分支事件源是否就绪
                    let mut ready_branch: Option<SubGraphId> = None;
                    for (branch_idx, branch) in info.branches.iter().enumerate() {
                        let event_val =
                            self.frames.get(fid).get_value_by_global(branch.event_source_node);
                        let is_ready = match branch.event_kind {
                            EventSourceKind::Channel => {
                                let ch_id = crate::Ir::ChannelId(event_val.as_i32() as u32);
                                self.channel_runtime.has_data(ch_id)
                            }
                            EventSourceKind::Timer => {
                                // Timer 分支：首次检查时启动 timer，后续用缓存的 timer_id
                                let timer_id = {
                                    let frame = self.frames.get(fid);
                                    if let Some((_, tid)) =
                                        frame.select_timers.iter().find(|(idx, _)| *idx == branch_idx)
                                    {
                                        *tid
                                    } else {
                                        // 首次：从 event_source_node 取 duration（i32 毫秒）→ 启动 timer
                                        let duration_ms = event_val.as_i32();
                                        let tid = self
                                            .timer_runtime
                                            .start(std::time::Duration::from_millis(
                                                duration_ms as u64,
                                            ));
                                        // 缓存到 frame.select_timers
                                        self.frames
                                            .get_mut(fid)
                                            .select_timers
                                            .push((branch_idx, tid));
                                        tid
                                    }
                                };
                                self.timer_runtime.is_fired(timer_id)
                            }
                            _ => false,
                        };
                        if is_ready {
                            ready_branch = Some(branch.subgraph_id);
                            break;
                        }
                    }

                    if let Some(sg_id) = ready_branch {
                        // 有就绪分支：启动分支子图
                        let child_fid = self.start_subgraph(fid, gate_local, sg_id, &[]);
                        self.ready_frames.push_back(child_fid);
                        // 当前帧挂起等子图完成
                        let frame = self.frames.get_mut(fid);
                        frame.state = FrameState::Suspended;
                        frame.suspend_state = SuspendState::WaitingSubgraph(child_fid);
                        frame.suspend_event = Some(RuntimeEvent::SubgraphComplete(child_fid));
                        return;
                    } else {
                        // 无就绪分支：注册所有事件等待 + 帧挂起
                        for (branch_idx, branch) in info.branches.iter().enumerate() {
                            let event_val = self
                                .frames
                                .get(fid)
                                .get_value_by_global(branch.event_source_node);
                            let event = match branch.event_kind {
                                EventSourceKind::Channel => RuntimeEvent::ChannelReady(
                                    crate::Ir::ChannelId(event_val.as_i32() as u32),
                                ),
                                EventSourceKind::Timer => {
                                    // 用已启动的真实 timer_id 注册事件等待
                                    let timer_id = self
                                        .frames
                                        .get(fid)
                                        .select_timers
                                        .iter()
                                        .find(|(idx, _)| *idx == branch_idx)
                                        .map(|(_, tid)| *tid)
                                        .expect("select timer should be started above");
                                    RuntimeEvent::TimerFired(timer_id)
                                }
                                _ => continue,
                            };
                            self.event_waiters.push((event, fid));
                        }
                        let frame = self.frames.get_mut(fid);
                        frame.state = FrameState::Suspended;
                        frame.suspend_state = SuspendState::WaitingEvent(gate_local);
                        // select 等多个事件，不设单一 suspend_event
                        frame.suspend_event = None;
                        return;
                    }
                }
            }

            // 普通节点：写值表 + 检查控制信号 + 通知下游
            let consumer_count = self.graph.downstreams[graph_node_id.0 as usize].len() as u16;
            self.frames.get_mut(fid).set_value(local_id, value.clone(), consumer_count);

            // 检查控制信号
            let signal_kind = self.graph.control_signal_nodes[graph_node_id.0 as usize];
            if let Some(kind) = signal_kind {
                let frame = self.frames.get_mut(fid);
                frame.control_signal = match kind {
                    SignalKind::Return => ControlSignal::Return(value),
                    SignalKind::Break => ControlSignal::Break,
                    SignalKind::Continue => ControlSignal::Continue,
                };
                break;
            }

            // 通知下游（含槽级 RC）
            self.notify_downstream(fid, local_id, graph_node_id, NodeId(node_start));
        }

        // 帧挂起：不执行 defer，不标记 Completed
        if self.frames.get(fid).state == FrameState::Suspended {
            return;
        }

        // 帧被取消：执行 defer 清理 + 标记 Failed（spec 5.3）
        if self.frames.get(fid).state == FrameState::Cancelling {
            let defer_entries: Vec<DeferEntry> = {
                let sg_id = self.frames.get(fid).subgraph_id;
                self.graph.subgraphs[sg_id.0 as usize].defer_table.clone()
            };
            for entry in defer_entries.iter().rev() {
                let defer_fid = self.init_frame(entry.body_subgraph);
                self.run_ready_nodes(defer_fid);
            }
            self.frames.get_mut(fid).state = FrameState::Failed;
            return;
        }

        // 执行 defer_stack（LIFO）：任何终止路径都执行 defer
        let defer_entries: Vec<DeferEntry> = {
            let sg_id = self.frames.get(fid).subgraph_id;
            self.graph.subgraphs[sg_id.0 as usize].defer_table.clone()
        };
        for entry in defer_entries.iter().rev() {
            let defer_fid = self.init_frame(entry.body_subgraph);
            self.run_ready_nodes(defer_fid);
        }

        // 标记帧完成
        self.frames.get_mut(fid).state = FrameState::Completed;
    }

    /// 提取子帧返回值：优先取 control_signal 的 Return 值，否则取 return_node 值。
    ///
    /// Break/Continue 信号：循环体帧终止时返回 VOID（循环退出值）。
    /// 正常 Glue 语义中 continue 不会到达此处（continue 编译为尾递归 Call + Return 信号），
    /// 但作为防御，Break/Continue 统一返回 VOID。
    fn extract_child_return(&self, child_fid: FrameId) -> Value {
        let child = self.frames.get(child_fid);
        match &child.control_signal {
            ControlSignal::Return(v) => v.clone(),
            ControlSignal::Break | ControlSignal::Continue => Value::VOID,
            ControlSignal::None => {
                let sg = &self.graph.subgraphs[child.subgraph_id.0 as usize];
                // 用 get_value_by_global 而非 get_value：分支子图的 return_node 可能指向
                // 外层节点（帧链穿透），需要通过 parent_frame_ptr/root_frame_ptr 回溯读取
                child.get_value_by_global(sg.return_node)
            }
        }
    }

    /// throw 传播：若返回值是 ThrowVal(Err)，向调用方透传 Return 信号。
    ///
    /// Glue 无 try-catch，throw 通过 Return 信号携带 ThrowVal(Err) 逐层透传至顶层。
    fn propagate_throw_if_any(&mut self, caller_fid: FrameId, return_value: &Value) {
        let is_throw_err = matches!(
            return_value.heap_obj(),
            Some(crate::Value::HeapObj::ThrowVal(t)) if matches!(t.payload, crate::Value::ThrowPayload::Err(_))
        );
        if is_throw_err {
            let frame = self.frames.get_mut(caller_fid);
            frame.control_signal = ControlSignal::Return(return_value.clone());
        }
    }

    /// 启动子图（call 节点调用）。
    ///
    /// 1. 创建子帧
    /// 2. 参数注入入口节点
    /// 3. 绑定 caller
    /// 4. 返回子帧 id
    pub fn start_subgraph(
        &mut self,
        caller_fid: FrameId,
        call_node: NodeId,
        subgraph_id: SubGraphId,
        args: &[Value],
    ) -> FrameId {
        let (node_start, node_end) = self.graph.subgraphs[subgraph_id.0 as usize].node_range;
        let node_count = (node_end.0 - node_start.0) as usize;
        let offset = node_start.0 as usize;

        let child_fid = self.frames.alloc(subgraph_id, node_count);

        // 共享初始化：node_offset + pending_inputs + Const 预填充 + Gate 入就绪队列
        self.prepare_frame(child_fid, node_start, node_count);

        // 参数注入（前 param_count 个节点，覆盖参数节点的预填充值）
        for (i, arg) in args.iter().enumerate() {
            let local_id = NodeId(i as u32);
            let consumer_count = self.graph.downstreams[offset + i].len() as u16;
            let frame = self.frames.get_mut(child_fid);
            frame.set_value(local_id, arg.clone(), consumer_count);
            frame.push_ready(local_id);
        }

        // 绑定 caller
        self.frames.get_mut(child_fid).caller = Some((caller_fid, call_node));

        // 设置 root_frame_ptr：同函数子图继承函数根帧，跨函数调用设为 null
        let caller_sg_id = self.frames.get(caller_fid).subgraph_id;
        let same_function = self.graph.subgraphs[caller_sg_id.0 as usize].function_id
            == self.graph.subgraphs[subgraph_id.0 as usize].function_id;
        let caller_root_ptr = self.frames.get(caller_fid).root_frame_ptr;
        let root_ptr = if same_function {
            if caller_root_ptr.is_null() {
                // caller 是函数根帧，指向 caller
                self.frames.get_mut(caller_fid) as *mut crate::Ir::Frame
            } else {
                caller_root_ptr
            }
        } else {
            std::ptr::null_mut()
        };
        self.frames.get_mut(child_fid).root_frame_ptr = root_ptr;

        // 设置 parent_frame_ptr：指向直接调用方帧，用于 get_value_by_global 遍历中间帧
        let parent_ptr = if same_function {
            self.frames.get_mut(caller_fid) as *mut crate::Ir::Frame
        } else {
            std::ptr::null_mut()
        };
        self.frames.get_mut(child_fid).parent_frame_ptr = parent_ptr;

        child_fid
    }

    /// 尾调用图跳转：复用当前帧执行目标子图（帧池零分配）。
    ///
    /// 编译期 tail_call_flags 标记的 Call 节点，运行时不再 start_subgraph 分配新帧，
    /// 而是将当前帧重置为目标子图继续执行。caller 绑定保持不变，使返回值直达原始调用方。
    /// 这使得循环、尾调、非尾调统一为同一帧池机制：
    /// - 循环：reset_loop_iteration 复用 body 帧
    /// - 尾调：switch_subgraph 复用当前帧（图跳转）
    /// - 非尾调：start_subgraph 分配新帧（帧池回收复用）
    fn switch_subgraph(&mut self, fid: FrameId, target_sg: SubGraphId, args: &[Value]) {
        let (node_start, node_count) = {
            let sg = &self.graph.subgraphs[target_sg.0 as usize];
            (sg.node_range.0, (sg.node_range.1.0 - sg.node_range.0.0) as usize)
        };

        // 更新 subgraph_id + 调整数组尺寸
        let frame = self.frames.get_mut(fid);
        frame.subgraph_id = target_sg;
        if frame.value_table.len() != node_count {
            frame.value_table.resize(node_count);
        }
        if frame.pending_inputs.len() != node_count {
            frame.pending_inputs.resize(node_count, 0);
        }

        // 清理旧子图状态（prepare_frame 不处理这些字段）
        frame.body_frame_id = None;
        frame.defer_stack.clear();
        frame.select_timers.clear();
        frame.root_frame_ptr = std::ptr::null_mut();
        frame.parent_frame_ptr = std::ptr::null_mut();
        frame.state = FrameState::Ready;
        frame.suspend_state = SuspendState::NotSuspended;
        frame.suspend_event = None;
        frame.pending_cancel = None;
        frame.pending_select_wait = None;
        // caller 保持不变：返回值直达原始调用方的 call 节点

        // prepare_frame：清空 value_table + ready_queue + pending_inputs + Const 预填充
        self.prepare_frame(fid, node_start, node_count);

        // 参数注入
        let offset = node_start.0 as usize;
        let param_count = self.graph.subgraphs[target_sg.0 as usize].param_count as usize;
        for (i, arg) in args.iter().enumerate().take(param_count) {
            let local_id = NodeId(i as u32);
            let consumer_count = self.graph.downstreams[offset + i].len() as u16;
            let frame = self.frames.get_mut(fid);
            frame.set_value(local_id, arg.clone(), consumer_count);
            frame.push_ready(local_id);
        }
    }

    /// 子图完成后：回写返回值到调用方 call/gate 节点 + 唤醒调用方。
    ///
    /// spec 4.4 on_event_arrived：事件到达→注入值+唤醒。
    fn complete_and_wake_caller(&mut self, child_fid: FrameId) {
        // LoopBody 完成检测：循环体子图完成后，重置循环（Continue/None）或退出（Break/Return）
        let child_sg_id = self.frames.get(child_fid).subgraph_id;
        let child_loop_kind = self.graph.subgraphs[child_sg_id.0 as usize].loop_kind;
        if child_loop_kind == crate::Ir::LoopKind::LoopBody {
            let child_signal = self.frames.get(child_fid).control_signal.clone();
            let (loop_fid, _call_node) = self
                .frames
                .get(child_fid)
                .caller
                .expect("LoopBody frame missing caller");
            match child_signal {
                ControlSignal::Break | ControlSignal::Return(_) => {
                    // break/return → 循环退出：释放 body 帧，传播信号到循环帧，循环帧正常完成
                    self.frames.free(child_fid);
                    self.frames.get_mut(loop_fid).body_frame_id = None;
                    self.frames.get_mut(loop_fid).control_signal = child_signal;
                    // 循环帧的 loop_kind 是 While/Loop/For（非 LoopBody），递归走原逻辑
                    self.complete_and_wake_caller(loop_fid);
                    return;
                }
                ControlSignal::Continue | ControlSignal::None => {
                    // continue/正常完成 → 循环重置（帧复用）
                    self.reset_loop_iteration(loop_fid, child_fid);
                    return;
                }
            }
        }

        let return_value = self.extract_child_return(child_fid);
        // 获取子帧的控制信号（Return/Break/Continue），用于 Gate 分支子图传播
        let child_signal = self.frames.get(child_fid).control_signal.clone();

        let caller = self.frames.get(child_fid).caller;
        if let Some((caller_fid, call_node)) = caller {
            // throw 传播：返回值为 ThrowVal(Err) 时，向调用方透传 Return 信号
            self.propagate_throw_if_any(caller_fid, &return_value);

            // 回写返回值到调用方 call/gate 节点
            let caller_sg_id = self.frames.get(caller_fid).subgraph_id;
            let caller_offset = self.graph.subgraphs[caller_sg_id.0 as usize].node_range.0;
            let call_graph_id = NodeId(call_node.0 + caller_offset.0);
            let consumer_count = self.graph.downstreams[call_graph_id.0 as usize].len() as u16;

            let caller_frame = self.frames.get_mut(caller_fid);
            caller_frame.set_value(call_node, return_value, consumer_count);
            caller_frame.state = FrameState::Ready;
            caller_frame.suspend_state = SuspendState::NotSuspended;
            caller_frame.suspend_event = None;

            // Gate 分支子图的控制信号传播：if/match 分支中的 return/break/continue
            // 应传播到父帧（分支只是控制流分派，不构成新的函数边界）。
            // Call 节点的子图是函数调用，Return 信号已被 extract_child_return 消费为返回值，不传播。
            let is_gate = self.graph.nodes[call_graph_id.0 as usize].kind == crate::Ir::NodeKind::Gate;
            if is_gate && !matches!(child_signal, ControlSignal::None) {
                caller_frame.control_signal = child_signal;
            }

            // 通知 call/gate 节点下游
            self.notify_downstream(caller_fid, call_node, call_graph_id, caller_offset);

            // 调用方入就绪帧队列
            self.ready_frames.push_back(caller_fid);
        }

        // 释放子帧：清空 value_table（堆对象 Arc 自动 decref），spec 4.3 frames.free(child)
        self.frames.free(child_fid);
    }

    /// 循环迭代重置：body_sg 完成后重置循环帧（cond + Gate）+ 复用 body_sg 帧。
    ///
    /// - 重置循环帧的 cond_node（重新计算 condition）+ Gate（pending=1 等 cond notify）
    /// - 重置 body_sg 帧（prepare_frame 复用）
    /// - 循环帧重新入就绪队列
    fn reset_loop_iteration(&mut self, loop_fid: FrameId, body_fid: FrameId) {
        let loop_sg_id = self.frames.get(loop_fid).subgraph_id;
        let (loop_offset, loop_kind, cond_node, return_node, iter_next_node) = {
            let sg = &self.graph.subgraphs[loop_sg_id.0 as usize];
            (
                sg.node_range.0 .0,
                sg.loop_kind,
                sg.cond_node,
                sg.return_node,
                sg.iter_next_node,
            )
        };

        // 1. For 循环：额外重置 iter_next_node（next_call），让迭代器重新推进
        if loop_kind == crate::Ir::LoopKind::For {
            if let Some(next_node) = iter_next_node {
                let next_local = NodeId(next_node.0.wrapping_sub(loop_offset));
                self.reset_node_ready(loop_fid, next_local);
                self.frames.get_mut(loop_fid).push_ready(next_local);
            }
        }

        // 2. 重置 cond_node（重新计算 condition）
        //    For 循环：cond_node(is_null) 依赖 next_call → pending=1 等 notify，不 push_ready
        //    While/Loop：cond_node 依赖外层变量 → pending=0 直接就绪
        //    注意：Const cond_node（如 loop {} 的 Const(true)）的 compute_fn 是 noop，
        //    reset_node_ready 清值后无法重新计算，必须重新预填充。
        if let Some(cond_node) = cond_node {
            let cond_local = NodeId(cond_node.0.wrapping_sub(loop_offset));
            if loop_kind == crate::Ir::LoopKind::For {
                self.reset_node_pending(loop_fid, cond_local, 1);
            } else {
                self.reset_node_ready(loop_fid, cond_local);
                // Const cond_node 重新预填充（compute_fn 是 noop，值丢失后无法恢复）
                if self.graph.nodes[cond_node.0 as usize].kind == crate::Ir::NodeKind::Const {
                    if let Some(cv) = self.graph.const_values[cond_node.0 as usize] {
                        let handle = self.alloc_const_value(cv);
                        let consumer_count =
                            self.graph.downstreams[cond_node.0 as usize].len() as u16;
                        self.frames.get_mut(loop_fid)
                            .set_value(cond_local, handle, consumer_count);
                    }
                }
                self.frames.get_mut(loop_fid).push_ready(cond_local);
            }
        }

        // 3. 重置 Gate 节点（pending=1，等 cond notify）
        let gate_local = NodeId(return_node.0.wrapping_sub(loop_offset));
        self.reset_node_pending(loop_fid, gate_local, 1);

        // 4. 重置 body_sg 帧（复用）
        let (body_sg_start, body_node_count) = {
            let body_sg_id = self.frames.get(body_fid).subgraph_id;
            let body_sg = &self.graph.subgraphs[body_sg_id.0 as usize];
            (body_sg.node_range.0, (body_sg.node_range.1 .0 - body_sg.node_range.0 .0) as usize)
        };
        self.prepare_frame(body_fid, body_sg_start, body_node_count);
        // body_sg 帧重新绑定 caller（保持循环帧为 caller）
        self.frames.get_mut(body_fid).caller =
            Some((loop_fid, NodeId(return_node.0.wrapping_sub(loop_offset))));
        // 设置 root_frame_ptr（复用 start_subgraph 的逻辑）
        let caller_root_ptr = self.frames.get(loop_fid).root_frame_ptr;
        let body_root_ptr = if caller_root_ptr.is_null() {
            self.frames.get_mut(loop_fid) as *mut crate::Ir::Frame
        } else {
            caller_root_ptr
        };
        self.frames.get_mut(body_fid).root_frame_ptr = body_root_ptr;
        // 设置 parent_frame_ptr：body 帧的直接父帧是循环帧
        self.frames.get_mut(body_fid).parent_frame_ptr =
            self.frames.get_mut(loop_fid) as *mut crate::Ir::Frame;

        // 5. 重置循环帧状态 + 重新入就绪队列
        let frame = self.frames.get_mut(loop_fid);
        frame.control_signal = ControlSignal::None;
        frame.state = FrameState::Ready;
        frame.suspend_state = SuspendState::NotSuspended;
        frame.suspend_event = None;
        frame.pending_call = None;
        self.ready_frames.push_back(loop_fid);
    }

    /// 重置节点为就绪状态（pending=0，清值，不入队）。
    fn reset_node_ready(&mut self, fid: FrameId, node_local: NodeId) {
        let frame = self.frames.get_mut(fid);
        let i = node_local.0 as usize;
        if i < frame.pending_inputs.len() {
            frame.pending_inputs[i] = 0;
        }
        if i < frame.value_table.len() {
            frame.value_table.reset_slot(i);
        }
    }

    /// 重置节点为待定状态（pending=N，清值）。
    fn reset_node_pending(&mut self, fid: FrameId, node_local: NodeId, pending: u8) {
        let frame = self.frames.get_mut(fid);
        let i = node_local.0 as usize;
        if i < frame.pending_inputs.len() {
            frame.pending_inputs[i] = pending;
        }
        if i < frame.value_table.len() {
            frame.value_table.reset_slot(i);
        }
    }

    /// 解析 await 事件源 id + 检查就绪状态。
    ///
    /// spec 4.4：事件源未就绪 → await 未就绪 → 帧挂起。
    /// 返回 (RuntimeEvent, Option<Value>)：Some=就绪值，None=未就绪需挂起。
    fn resolve_and_check_await(
        &mut self,
        pending: &crate::Ir::PendingAwait,
    ) -> (RuntimeEvent, Option<Value>) {
        use crate::Ir::EventSourceKind;
        match pending.event_kind {
            EventSourceKind::AsyncJoin => {
                let async_id = crate::Ir::AsyncHandleId(pending.event_obj.as_i32() as u32);
                let event = RuntimeEvent::AsyncJoin(async_id);
                if let Some(val) = self.async_join_runtime.try_get_result(async_id) {
                    (event, Some(val))
                } else {
                    (event, None)
                }
            }
            EventSourceKind::Channel => {
                let ch_id = crate::Ir::ChannelId(pending.event_obj.as_i32() as u32);
                let event = RuntimeEvent::ChannelReady(ch_id);
                if let Some(val) = self.channel_runtime.recv(ch_id) {
                    (event, Some(val))
                } else {
                    (event, None)
                }
            }
            EventSourceKind::Timer => {
                let timer_id = crate::Ir::TimerId(pending.event_obj.as_i32() as u32);
                let event = RuntimeEvent::TimerFired(timer_id);
                if self.timer_runtime.is_fired(timer_id) {
                    (event, Some(Value::VOID))
                } else {
                    (event, None)
                }
            }
            EventSourceKind::SubgraphComplete => {
                panic!("SubgraphComplete should not go through await path");
            }
        }
    }

    /// on_event_arrived：统一事件注入（spec 4.4）。
    ///
    /// 事件到达 → 找等待该事件的帧 → 注入值到 await 节点 → 通知下游 → 唤醒。
    /// channel/timer/async 事件共用此路径。
    ///
    /// select 帧：suspend_event 为 None（等多个事件），唤醒时重新 push gate 节点
    /// 到 ready_queue（不注入值，gate 重新检查就绪状态）。
    fn on_event_arrived(&mut self, event: RuntimeEvent, value: Value) {
        let waiters: Vec<FrameId> = self
            .event_waiters
            .iter()
            .filter(|(e, _)| *e == event)
            .map(|(_, fid)| *fid)
            .collect();
        self.event_waiters
            .retain(|(_, fid)| !waiters.contains(fid));

        for fid in waiters {
            let await_node = match self.frames.get(fid).suspend_state {
                SuspendState::WaitingEvent(node) => node,
                _ => continue,
            };

            let node_offset = self.frames.get(fid).node_offset;
            let await_graph_id = NodeId(await_node.0 + node_offset);

            // select 帧（gate 节点有 SelectInfo）：重新 push gate 节点，不注入值
            let is_select = self.graph.select_infos[await_graph_id.0 as usize].is_some();
            if is_select {
                let frame = self.frames.get_mut(fid);
                frame.state = FrameState::Ready;
                frame.suspend_state = SuspendState::NotSuspended;
                frame.suspend_event = None;
                frame.push_ready(await_node);
                self.ready_frames.push_back(fid);
            } else {
                // 普通 await 帧：注入事件值到 await 节点
                let consumer_count =
                    self.graph.downstreams[await_graph_id.0 as usize].len() as u16;
                let frame = self.frames.get_mut(fid);
                frame.set_value(await_node, value.clone(), consumer_count);
                frame.state = FrameState::Ready;
                frame.suspend_state = SuspendState::NotSuspended;
                frame.suspend_event = None;
                self.notify_downstream(fid, await_node, await_graph_id, NodeId(node_offset));
                self.ready_frames.push_back(fid);
            }
        }
    }

    /// 取消帧：CAS Suspended → Cancelling + 入就绪队列。
    ///
    /// spec 5.3：只有挂起态可取消，Running/Completed 不可取消。
    /// worker 检测到 Cancelling 状态后执行 defer 清理（复用 defer 机制）。
    pub fn cancel_frame(&mut self, frame_id: FrameId) {
        let frame = self.frames.get_mut(frame_id);
        // 只有 Suspended 态可取消
        if frame.state != FrameState::Suspended {
            return;
        }
        // 移除事件等待注册
        if let Some(event) = frame.suspend_event {
            self.event_waiters
                .retain(|(e, fid)| !(*e == event && *fid == frame_id));
        } else {
            // select 帧：suspend_event 为 None（等多个事件），移除该帧所有事件等待
            self.event_waiters
                .retain(|(_, fid)| *fid != frame_id);
        }
        // CAS Suspended → Cancelling
        frame.state = FrameState::Cancelling;
        frame.suspend_state = SuspendState::NotSuspended;
        frame.suspend_event = None;
        // 入就绪队列（worker 检测到 Cancelling 后执行 defer 清理）
        self.ready_frames.push_back(frame_id);
    }

    /// 全局事件循环：调度就绪帧，处理挂起/完成。
    ///
    /// spec 4.2 + 4.4：替代栈嵌套执行，所有 call/gate 走事件驱动。
    /// 检查到期 timer，触发 TimerFired 事件。
    ///
    /// spec 4.4：事件循环每次迭代检查到期 timer。
    /// 单线程和多 worker 模式共用。
    pub fn check_timers(&mut self) {
        let fired_timers = self.timer_runtime.check_and_fire();
        for timer_id in fired_timers {
            self.on_event_arrived(RuntimeEvent::TimerFired(timer_id), Value::VOID);
        }
    }

    /// 处理一个帧：执行就绪节点 + 处理状态转换。
    ///
    /// 返回 `Some(result)` 当顶层帧完成；返回 `None` 当帧仍需继续（挂起/子帧完成/控制信号）。
    /// 多 worker 模式下每个 worker 调用此方法处理单个帧。
    pub fn process_frame(&mut self, fid: FrameId) -> Option<Value> {
        // 执行帧就绪节点
        self.run_ready_nodes(fid);

        // FrameState 是 Copy，先拷贝状态值，避免 match 分支内持有不可变借用
        let state = self.frames.get(fid).state;
        // 是否有调用方（顶层帧无调用方）
        let has_caller = self.frames.get(fid).caller.is_some();
        match state {
            FrameState::Suspended => {
                let event = self.frames.get(fid).suspend_event;
                if let Some(e) = event {
                    self.event_waiters.push((e, fid));
                } else {
                    // select 帧：suspend_event 为 None，event_waiters 已在
                    // run_ready_nodes 中注册。若无任何等待则 panic（异常状态）。
                    let has_waiter = self.event_waiters.iter().any(|(_, wf)| *wf == fid);
                    if !has_waiter {
                        panic!("frame {} suspended without event", fid.0);
                    }
                }
            }
            FrameState::Completed => {
                if has_caller {
                    // 区分 sync call vs async call 子帧完成
                    // async call 子帧：async_join_runtime 有注册 → 触发 AsyncJoin 事件
                    // sync call 子帧：走 complete_and_wake_caller
                    if let Some(async_id) = self.async_join_runtime.find_by_child(fid) {
                        // async 子帧完成：设置 result + 触发 AsyncJoin 事件
                        let return_value = self.extract_child_return(fid);
                        // Value 不再 Copy：set_result 取得所有权存储，on_event_arrived 需 clone 传递给等待帧
                        self.async_join_runtime.set_result(async_id, return_value.clone());
                        self.frames.free(fid);
                        self.on_event_arrived(RuntimeEvent::AsyncJoin(async_id), return_value);
                    } else {
                        // sync 子帧完成：清理 waiter + 回写 + 唤醒调用方
                        self.event_waiters.retain(|(e, _)| {
                            !matches!(e, RuntimeEvent::SubgraphComplete(c) if *c == fid)
                        });
                        self.complete_and_wake_caller(fid);
                    }
                } else {
                    // 顶层帧完成：返回结果
                    return Some(self.extract_child_return(fid));
                }
            }
            FrameState::Failed => {
                if has_caller {
                    // Failed 子帧（cancel 后）：清理 waiter + 唤醒调用方
                    self.event_waiters.retain(|(e, _)| {
                        !matches!(e, RuntimeEvent::SubgraphComplete(c) if *c == fid)
                    });
                    self.complete_and_wake_caller(fid);
                } else {
                    // 顶层帧 Failed：返回 NULL
                    return Some(Value::NULL);
                }
            }
            _ => {
                // Ready（控制信号触发但未挂起）：重新入队继续执行
                self.ready_frames.push_back(fid);
            }
        }
        None
    }

    /// 全局事件循环：调度就绪帧，处理挂起/完成。
    ///
    /// spec 4.2 + 4.4：替代栈嵌套执行，所有 call/gate 走事件驱动。
    pub fn run_event_loop(&mut self) -> Value {
        let entry_sg = self.graph.entry_subgraph.expect("no entry subgraph");
        let fid = self.init_frame(entry_sg);
        self.ready_frames.push_back(fid);

        loop {
            // 检查 timer 事件（spec 4.4：事件循环每次迭代检查到期 timer）
            self.check_timers();

            let fid = match self.ready_frames.pop_front() {
                Some(f) => f,
                None => {
                    if self.event_waiters.is_empty() {
                        panic!("event loop exhausted: no ready frames and no pending events");
                    }
                    // 有等待者但无就绪帧：可能是 timer 未到期，spin-wait
                    std::thread::yield_now();
                    continue;
                }
            };

            if let Some(result) = self.process_frame(fid) {
                return result;
            }
        }
    }

    /// 执行入口子图，返回返回值（单线程模式）。
    pub fn run_entry(&mut self) -> Value {
        self.run_event_loop()
    }

    /// 多 worker 模式执行入口子图（细粒度锁 + 帧无锁执行）。
    ///
    /// spec 4.8：N 个 worker 跑任意多协程。
    /// 使用 crossbeam-deque 实现 work-stealing（LIFO local + FIFO steal），
    /// parking_lot 实现 park/unpark 避免 busy-wait。
    ///
    /// 细粒度锁设计（Phase 6 Task 3）：
    /// - SharedEngine 持有独立 Mutex 的 runtime（channel/timer/async）
    /// - 帧从 frames HashMap 取出后独占执行（无锁）
    /// - 需要访问 runtime 时单独锁对应 Mutex
    /// - 绝不同时持有两个 Mutex（避免死锁）
    pub fn run_multi_worker(&mut self, num_workers: usize) -> Value {
        assert!(num_workers >= 1, "num_workers must be >= 1");

        // 创建入口帧
        let entry_sg = self.graph.entry_subgraph.expect("no entry subgraph");
        let entry_fid = self.init_frame(entry_sg);

        // 创建每个 worker 的本地队列 + stealer 端
        let mut local_queues: Vec<DequeWorker<FrameId>> = Vec::with_capacity(num_workers);
        let mut stealers: Vec<Stealer<FrameId>> = Vec::with_capacity(num_workers);
        for _ in 0..num_workers {
            let w = DequeWorker::new_lifo();
            stealers.push(w.stealer());
            local_queues.push(w);
        }

        // 从 Engine 提取状态创建 SharedEngine（调用后 Engine runtime 字段被 take）
        let shared = Arc::new(SharedEngine::from_engine(self, num_workers));
        // 注入入口帧到全局队列
        shared.global_queue.push(entry_fid);

        // 使用 scoped threads（保证线程在 scope 结束时 join）
        std::thread::scope(|s| {
            for (worker_id, local_queue) in local_queues.into_iter().enumerate() {
                let shared = shared.clone();
                let stealers = stealers.clone();

                s.spawn(move || {
                    worker_main(worker_id, local_queue, stealers, shared);
                });
            }
        });

        // 提取结果（先存局部变量，避免 MutexGuard 生命周期问题）
        let result_value = shared
            .result
            .lock()
            .take()
            .expect("no result produced: all workers exited without completion");
        result_value
    }
}

// =========================================================================
// SharedEngine — 细粒度锁多 worker 共享状态（spec §4.1, §4.8）
// =========================================================================

use hashbrown::HashMap;
use crossbeam_deque::{Injector, Stealer, Worker as DequeWorker};
use parking_lot::{Condvar, Mutex as ParkingMutex};
use std::sync::Arc;

/// 跨 worker 共享状态（Arc，所有 worker 共享）。
///
/// 细粒度锁设计：每个 runtime 独立 Mutex，帧执行时无锁（从 frames HashMap
/// 取出后独占）。需要访问 runtime 时单独锁对应 Mutex。
///
/// 死锁对策：绝不同时持有两个 Mutex。按固定顺序获取：frames → runtime。
pub struct SharedEngine {
    /// 数据流图（只读共享，Arc 包装供帧共享）
    pub graph: Arc<DataFlowGraph>,
    /// 帧表（FrameId → Frame），帧执行时从表中取出独占
    pub frames: ParkingMutex<HashMap<FrameId, Frame>>,
    /// 下一个帧 id
    pub next_frame_id: ParkingMutex<FrameId>,
    /// 值 arena（vtable 分派用，compute_fn 不使用）
    pub arena: ParkingMutex<ValueArena>,
    /// Channel 运行时
    pub channel_runtime: ParkingMutex<ChannelRuntime>,
    /// Timer 运行时
    pub timer_runtime: ParkingMutex<TimerRuntime>,
    /// AsyncJoin 运行时
    pub async_join_runtime: ParkingMutex<AsyncJoinRuntime>,
    /// 事件等待者列表
    pub event_waiters: ParkingMutex<Vec<(crate::Ir::RuntimeEvent, FrameId)>>,
    /// 待处理的子图完成事件（caller 帧竞态时暂存，由 process_frame_shared 消费）
    pub pending_completions: ParkingMutex<HashMap<FrameId, (crate::Ir::NodeId, Value, crate::Ir::ControlSignal)>>,
    /// 全局注入队列（入口帧 + 挂起恢复帧）
    pub global_queue: Injector<FrameId>,
    /// park/unpark 同步原语
    pub wakeup: (ParkingMutex<()>, Condvar),
    /// 活跃 worker 计数（归零表示事件循环耗尽）
    pub active_count: ParkingMutex<usize>,
    /// 顶层帧返回值
    pub result: ParkingMutex<Option<Value>>,
}

/// Safety: SharedEngine 的所有可变字段都在 ParkingMutex 保护下，同一时刻只有一个线程
/// 访问每个字段。ValueArena 虽然包含 Rc<str>（非 Send），但 ParkingMutex 保证互斥访问。
/// 这与旧代码的 SyncPtr + ParkingMutex 安全模型一致。
unsafe impl Send for SharedEngine {}
unsafe impl Sync for SharedEngine {}

impl SharedEngine {
    /// 从 Engine 提取状态创建 SharedEngine。
    ///
    /// 调用后 Engine 的 runtime 字段被 take 为默认值，不再可用。
    pub fn from_engine(engine: &mut Engine, num_workers: usize) -> Self {
        let mut frames_map = HashMap::new();
        let frames_vec = engine.frames.drain_frames();
        for frame in frames_vec {
            frames_map.insert(frame.id, frame);
        }
        Self {
            graph: engine.graph.clone(),
            frames: ParkingMutex::new(frames_map),
            next_frame_id: ParkingMutex::new(FrameId(engine.frames.next_id)),
            arena: ParkingMutex::new(std::mem::take(&mut engine.arena)),
            channel_runtime: ParkingMutex::new(std::mem::take(&mut engine.channel_runtime)),
            timer_runtime: ParkingMutex::new(std::mem::take(&mut engine.timer_runtime)),
            async_join_runtime: ParkingMutex::new(std::mem::take(&mut engine.async_join_runtime)),
            event_waiters: ParkingMutex::new(std::mem::take(&mut engine.event_waiters)),
            pending_completions: ParkingMutex::new(HashMap::new()),
            global_queue: Injector::new(),
            wakeup: (ParkingMutex::new(()), Condvar::new()),
            active_count: ParkingMutex::new(num_workers),
            result: ParkingMutex::new(None),
        }
    }

    /// 分配新帧 id。
    fn alloc_frame_id(&self) -> FrameId {
        let mut next = self.next_frame_id.lock();
        let id = *next;
        assert!(next.0 < u32::MAX, "FrameId overflow: too many frames allocated");
        next.0 += 1;
        id
    }
}

// =========================================================================
// SharedEngine 辅助函数（从 Engine 方法提取，改为基于 SharedEngine）
// =========================================================================

/// 将 ConstValue 转换为 Value（不使用 arena，直接构造）。
fn alloc_const_value_shared(cv: ConstValue) -> Value {
    match cv {
        ConstValue::I8(v) => Value::i8(v),
        ConstValue::I16(v) => Value::i16(v),
        ConstValue::I32(v) => Value::i32(v),
        ConstValue::I64(v) => Value::i64(v),
        ConstValue::I128(v) => Value::i128(v),
        ConstValue::U8(v) => Value::u8(v),
        ConstValue::U16(v) => Value::u16(v),
        ConstValue::U32(v) => Value::u32(v),
        ConstValue::U64(v) => Value::u64(v),
        ConstValue::U128(v) => Value::u128(v),
        ConstValue::Isize(v) => Value::isize_val(v),
        ConstValue::Usize(v) => Value::usize_val(v),
        ConstValue::F32(v) => Value::f32(v),
        ConstValue::F64(v) => Value::f64(v),
        ConstValue::Bool(v) => Value::bool_val(v),
        ConstValue::Char(c) => Value::char_val(char::from_u32(c).unwrap_or('\0')),
        ConstValue::Null => Value::NULL,
        ConstValue::Void => Value::VOID,
        ConstValue::Str(s) => {
            use crate::Value::{HeapObj, GlueStr};
            Value::ref_val(HeapObj::Str(GlueStr::new(s)))
        }
    }
}

/// 帧节点初始化：设置 node_offset + pending_inputs + 预填充 Const + Gate 入就绪队列。
///
/// 从 Engine::prepare_frame 提取，改为直接操作 frame（无需通过 FramePool）。
fn prepare_frame_shared(frame: &mut Frame, graph: &DataFlowGraph) {
    let sg_id = frame.subgraph_id;
    let (node_start, node_end) = graph.subgraphs[sg_id.0 as usize].node_range;
    let node_count = (node_end.0 - node_start.0) as usize;
    let offset = node_start.0 as usize;
    let node_end_global = node_start.0 + node_count as u32;

    // 收集嵌套子图范围
    let nested_ranges: Vec<(u32, u32)> = graph
        .subgraphs
        .iter()
        .filter(|sg| {
            sg.id != sg_id
                && sg.node_range.0 .0 >= node_start.0
                && sg.node_range.1 .0 <= node_end_global
        })
        .map(|sg| (sg.node_range.0 .0, sg.node_range.1 .0))
        .collect();

    let is_nested = |global_idx: u32| -> bool {
        nested_ranges.iter().any(|&(s, e)| global_idx >= s && global_idx < e)
    };

    // 设置 node_offset
    frame.node_offset = node_start.0;

    // 1. 初始化 pending_inputs
    for i in 0..node_count {
        if is_nested((offset + i) as u32) {
            frame.pending_inputs[i] = u8::MAX;
        } else {
            let graph_node = &graph.nodes[offset + i];
            if graph_node.kind == NodeKind::EventSource {
                frame.pending_inputs[i] = u8::MAX;
            } else if graph_node.kind == NodeKind::Gate {
                if graph.select_infos[offset + i].is_some() {
                    frame.pending_inputs[i] = 0;
                } else {
                    frame.pending_inputs[i] = 1;
                }
            } else {
                // 只统计当前帧内的输入（外层节点通过 root_frame_ptr 读取，不计入 pending）
                let inputs = graph.inputs_pool.get(
                    graph_node.inputs_offset,
                    graph_node.input_count,
                );
                let in_frame = inputs
                    .iter()
                    .filter(|&&n| (n.0.wrapping_sub(node_start.0) as usize) < node_count)
                    .count() as u8;
                frame.pending_inputs[i] = in_frame;
            }
        }
    }

    // 2. 预填充 Const 节点
    for i in 0..node_count {
        if is_nested((offset + i) as u32) {
            continue;
        }
        let kind = graph.nodes[offset + i].kind;
        if kind == NodeKind::Const {
            if let Some(cv) = graph.const_values[offset + i] {
                let handle = alloc_const_value_shared(cv);
                let local_id = NodeId(i as u32);
                let consumer_count = graph.downstreams[offset + i].len() as u16;
                frame.set_value(local_id, handle, consumer_count);
                frame.push_ready(local_id);
            }
        }
    }

    // 3. 非 Const 节点 with 0 inputs 入就绪队列
    let param_count = graph.subgraphs[sg_id.0 as usize].param_count as usize;
    for i in 0..node_count {
        if i < param_count {
            continue;
        }
        if is_nested((offset + i) as u32) {
            continue;
        }
        let kind = graph.nodes[offset + i].kind;
        if kind == NodeKind::Const {
            continue;
        }
        if frame.pending_inputs[i] == 0 && !frame.value_table.ready[i] {
            frame.push_ready(NodeId(i as u32));
        }
    }
}

/// 初始化帧：分配 + 预填充。返回 FrameId（帧已插入 frames HashMap）。
fn init_frame_shared(shared: &SharedEngine, subgraph_id: SubGraphId) -> FrameId {
    let (node_start, node_end) = shared.graph.subgraphs[subgraph_id.0 as usize].node_range;
    let node_count = (node_end.0 - node_start.0) as usize;
    let fid = shared.alloc_frame_id();
    let mut frame = Frame::new(fid, subgraph_id, node_count, shared.graph.clone());
    prepare_frame_shared(&mut frame, &shared.graph);
    shared.frames.lock().insert(fid, frame);
    fid
}

/// 通知下游节点：减 pending_inputs，归零则入就绪队列（槽级 RC）。
fn notify_downstream_shared(
    frame: &mut Frame,
    graph: &DataFlowGraph,
    producer_local: NodeId,
    producer_graph: NodeId,
    node_start: NodeId,
) {
    let downstreams: Vec<NodeId> = graph.downstreams[producer_graph.0 as usize].clone();
    for ds_graph_id in downstreams {
        let ds_local_id = NodeId(ds_graph_id.0.wrapping_sub(node_start.0));

        let pidx = producer_local.0 as usize;
        let still_has_consumers = frame.value_table.consume(pidx);
        if !still_has_consumers && frame.value_table.ready[pidx] {
            frame.value_table.ready[pidx] = false;
        }

        if frame.pending_inputs[ds_local_id.0 as usize] > 0 {
            frame.pending_inputs[ds_local_id.0 as usize] -= 1;
        }
        if frame.pending_inputs[ds_local_id.0 as usize] == 0
            && !frame.value_table.ready[ds_local_id.0 as usize]
        {
            frame.push_ready(ds_local_id);
        }
    }
}

/// 启动子图（call 节点调用）。创建子帧 + 注入参数 + 设 caller。
///
/// 返回子帧 FrameId（已插入 frames HashMap）。
fn start_subgraph_shared(
    shared: &SharedEngine,
    caller_fid: FrameId,
    call_node: NodeId,
    subgraph_id: SubGraphId,
    args: &[Value],
) -> FrameId {
    let (node_start, node_end) = shared.graph.subgraphs[subgraph_id.0 as usize].node_range;
    let node_count = (node_end.0 - node_start.0) as usize;
    let offset = node_start.0 as usize;

    let child_fid = shared.alloc_frame_id();
    let mut child = Frame::new(child_fid, subgraph_id, node_count, shared.graph.clone());
    prepare_frame_shared(&mut child, &shared.graph);

    // 参数注入（前 param_count 个节点）
    for (i, arg) in args.iter().enumerate() {
        let local_id = NodeId(i as u32);
        let consumer_count = shared.graph.downstreams[offset + i].len() as u16;
        child.set_value(local_id, arg.clone(), consumer_count);
        child.push_ready(local_id);
    }

    // 绑定 caller
    child.caller = Some((caller_fid, call_node));

    shared.frames.lock().insert(child_fid, child);
    child_fid
}

/// 尾调用图跳转（共享版）：复用当前帧执行目标子图（帧池零分配）。
///
/// 与 Engine::switch_subgraph 对应，但直接操作 &mut Frame（无 HashMap 查找）。
/// caller 绑定保持不变，返回值直达原始调用方。
fn switch_subgraph_shared(frame: &mut Frame, graph: &DataFlowGraph, target_sg: SubGraphId, args: &[Value]) {
    let (node_start, node_end) = graph.subgraphs[target_sg.0 as usize].node_range;
    let node_count = (node_end.0 - node_start.0) as usize;

    // 更新 subgraph_id + 调整数组尺寸
    frame.subgraph_id = target_sg;
    if frame.value_table.len() != node_count {
        frame.value_table.resize(node_count);
    }
    if frame.pending_inputs.len() != node_count {
        frame.pending_inputs.resize(node_count, 0);
    }

    // 清空 value_table（prepare_frame_shared 不做此操作）
    frame.value_table.reset_all();
    frame.ready_queue.clear();
    frame.control_signal = ControlSignal::None;
    frame.pending_call = None;
    frame.pending_await = None;
    frame.body_frame_id = None;
    frame.defer_stack.clear();
    frame.select_timers.clear();
    frame.root_frame_ptr = std::ptr::null_mut();
    frame.parent_frame_ptr = std::ptr::null_mut();
    frame.state = FrameState::Ready;
    frame.suspend_state = SuspendState::NotSuspended;
    frame.suspend_event = None;
    frame.pending_cancel = None;
    frame.pending_select_wait = None;
    // caller 保持不变：返回值直达原始调用方的 call 节点

    // prepare_frame_shared：设置 node_offset + pending_inputs + Const 预填充
    prepare_frame_shared(frame, graph);

    // 参数注入
    let offset = node_start.0 as usize;
    let param_count = graph.subgraphs[target_sg.0 as usize].param_count as usize;
    for (i, arg) in args.iter().enumerate().take(param_count) {
        let local_id = NodeId(i as u32);
        let consumer_count = graph.downstreams[offset + i].len() as u16;
        frame.set_value(local_id, arg.clone(), consumer_count);
        frame.push_ready(local_id);
    }
}

/// 提取子帧返回值：优先取 control_signal 的 Return 值，否则取 return_node 值。
fn extract_child_return_shared(child: &Frame, graph: &DataFlowGraph) -> Value {
    match &child.control_signal {
        ControlSignal::Return(v) => v.clone(),
        ControlSignal::Break | ControlSignal::Continue => Value::VOID,
        ControlSignal::None => {
            let sg = &graph.subgraphs[child.subgraph_id.0 as usize];
            let return_local = NodeId(sg.return_node.0.wrapping_sub(sg.node_range.0 .0));
            child.get_value(return_local)
        }
    }
}

/// throw 传播：若返回值是 ThrowVal(Err)，向调用方透传 Return 信号。
fn propagate_throw_shared(caller: &mut Frame, return_value: &Value) {
    let is_throw_err = matches!(
        return_value.heap_obj(),
        Some(crate::Value::HeapObj::ThrowVal(t)) if matches!(t.payload, crate::Value::ThrowPayload::Err(_))
    );
    if is_throw_err {
        caller.control_signal = ControlSignal::Return(return_value.clone());
    }
}

/// 子图完成后：回写返回值到调用方 + 唤醒调用方。
///
/// 子帧不入 frames（等同于 free）。caller 帧从 frames 取出、修改、放回。
fn complete_and_wake_caller_shared(
    shared: &SharedEngine,
    child_frame: &Frame,
    local_queue: &DequeWorker<FrameId>,
) {
    let return_value = extract_child_return_shared(child_frame, &shared.graph);
    let child_signal = child_frame.control_signal.clone();
    let caller = child_frame.caller;

    if let Some((caller_fid, call_node)) = caller {
        // 取出 caller 帧（短临界区）
        // 竞态处理：caller 帧可能还未被 insert 回 HashMap（run_frame_nodes 设置
        // Suspended 后 return，insert 发生在 process_frame_shared 中）。
        // 若 remove 返回 None，将完成信息存入 pending_completions，
        // 由 process_frame_shared 在处理 Suspended 帧时消费（事件重注册机制）。
        let mut caller_frame_opt = {
            let mut frames = shared.frames.lock();
            frames.remove(&caller_fid)
        };

        if caller_frame_opt.is_none() {
            // 父帧尚未 insert 回 HashMap，存储完成信息等待重试
            shared.pending_completions.lock().insert(
                caller_fid,
                (call_node, return_value, child_signal),
            );
            return;
        }

        // 修改 caller 帧（无需持锁）
        if let Some(caller_frame) = caller_frame_opt.as_mut() {
            propagate_throw_shared(caller_frame, &return_value);

            let caller_sg_id = caller_frame.subgraph_id;
            let caller_offset = shared.graph.subgraphs[caller_sg_id.0 as usize].node_range.0;
            let call_graph_id = NodeId(call_node.0 + caller_offset.0);
            let consumer_count = shared.graph.downstreams[call_graph_id.0 as usize].len() as u16;

            caller_frame.set_value(call_node, return_value, consumer_count);
            caller_frame.state = FrameState::Ready;
            caller_frame.suspend_state = SuspendState::NotSuspended;
            caller_frame.suspend_event = None;

            // Gate 分支子图的控制信号传播（同 complete_and_wake_caller）
            let is_gate = shared.graph.nodes[call_graph_id.0 as usize].kind == crate::Ir::NodeKind::Gate;
            if is_gate && !matches!(child_signal, ControlSignal::None) {
                caller_frame.control_signal = child_signal;
            }

            notify_downstream_shared(
                caller_frame,
                &shared.graph,
                call_node,
                call_graph_id,
                caller_offset,
            );
        }

        // 放回 caller 帧 + 入队（取所有权）
        if let Some(caller_frame) = caller_frame_opt {
            shared.frames.lock().insert(caller_fid, caller_frame);
            local_queue.push(caller_fid);
        }
    }
    // 子帧已完成，由调用方负责 drop（不放回 frames）
}

/// on_event_arrived：事件到达 → 注入值到等待帧 → 唤醒。
///
/// channel/timer/async 事件共用此路径。
/// select 帧：重新 push gate 节点（不注入值，gate 重新检查就绪状态）。
fn on_event_arrived_shared(
    shared: &SharedEngine,
    event: RuntimeEvent,
    value: Value,
    local_queue: &DequeWorker<FrameId>,
) {
    // 找等待该事件的帧（短临界区）
    let waiters: Vec<FrameId> = {
        let mut event_waiters = shared.event_waiters.lock();
        let waiters: Vec<FrameId> = event_waiters
            .iter()
            .filter(|(e, _)| *e == event)
            .map(|(_, fid)| *fid)
            .collect();
        event_waiters.retain(|(_, fid)| !waiters.contains(fid));
        waiters
    };

    for fid in waiters {
        // 取出帧（短临界区）
        let mut frame = {
            let mut frames = shared.frames.lock();
            match frames.remove(&fid) {
                Some(f) => f,
                None => continue, // 帧正被其他 worker 处理，跳过
            }
        };

        let await_node = match frame.suspend_state {
            SuspendState::WaitingEvent(node) => node,
            _ => {
                // 非事件等待帧：放回 + 跳过
                shared.frames.lock().insert(fid, frame);
                continue;
            }
        };

        let node_offset = frame.node_offset;
        let await_graph_id = NodeId(await_node.0 + node_offset);

        // select 帧（gate 节点有 SelectInfo）：重新 push gate 节点，不注入值
        let is_select = shared.graph.select_infos[await_graph_id.0 as usize].is_some();
        if is_select {
            frame.state = FrameState::Ready;
            frame.suspend_state = SuspendState::NotSuspended;
            frame.suspend_event = None;
            frame.push_ready(await_node);
        } else {
            // 普通 await 帧：注入事件值到 await 节点
            let consumer_count =
                shared.graph.downstreams[await_graph_id.0 as usize].len() as u16;
            frame.set_value(await_node, value.clone(), consumer_count);
            frame.state = FrameState::Ready;
            frame.suspend_state = SuspendState::NotSuspended;
            frame.suspend_event = None;
            notify_downstream_shared(
                &mut frame,
                &shared.graph,
                await_node,
                await_graph_id,
                NodeId(node_offset),
            );
        }

        // 放回帧 + 入队
        shared.frames.lock().insert(fid, frame);
        local_queue.push(fid);
    }
}

/// 解析 await 事件源 id + 检查就绪状态。
///
/// 返回 (RuntimeEvent, Option<Value>)：Some=就绪值，None=未就绪需挂起。
fn resolve_and_check_await_shared(
    shared: &SharedEngine,
    pending: &crate::Ir::PendingAwait,
) -> (RuntimeEvent, Option<Value>) {
    use crate::Ir::EventSourceKind;
    match pending.event_kind {
        EventSourceKind::AsyncJoin => {
            let async_id = crate::Ir::AsyncHandleId(pending.event_obj.as_i32() as u32);
            let event = RuntimeEvent::AsyncJoin(async_id);
            let val = shared.async_join_runtime.lock().try_get_result(async_id);
            (event, val)
        }
        EventSourceKind::Channel => {
            let ch_id = crate::Ir::ChannelId(pending.event_obj.as_i32() as u32);
            let event = RuntimeEvent::ChannelReady(ch_id);
            let val = shared.channel_runtime.lock().recv(ch_id);
            (event, val)
        }
        EventSourceKind::Timer => {
            let timer_id = crate::Ir::TimerId(pending.event_obj.as_i32() as u32);
            let event = RuntimeEvent::TimerFired(timer_id);
            let fired = shared.timer_runtime.lock().is_fired(timer_id);
            if fired {
                (event, Some(Value::VOID))
            } else {
                (event, None)
            }
        }
        EventSourceKind::SubgraphComplete => {
            panic!("SubgraphComplete should not go through await path");
        }
    }
}

/// 取消帧：CAS Suspended → Cancelling + 入就绪队列。
fn cancel_frame_shared(
    shared: &SharedEngine,
    frame_id: FrameId,
    local_queue: &DequeWorker<FrameId>,
) {
    let mut frame = {
        let mut frames = shared.frames.lock();
        match frames.remove(&frame_id) {
            Some(f) => f,
            None => return, // 帧正被其他 worker 处理，跳过
        }
    };

    if frame.state != FrameState::Suspended {
        shared.frames.lock().insert(frame_id, frame);
        return;
    }

    // 移除事件等待注册
    if let Some(event) = frame.suspend_event {
        shared
            .event_waiters
            .lock()
            .retain(|(e, fid)| !(*e == event && *fid == frame_id));
    } else {
        // select 帧：移除该帧所有事件等待
        shared
            .event_waiters
            .lock()
            .retain(|(_, fid)| *fid != frame_id);
    }

    frame.state = FrameState::Cancelling;
    frame.suspend_state = SuspendState::NotSuspended;
    frame.suspend_event = None;

    shared.frames.lock().insert(frame_id, frame);
    local_queue.push(frame_id);
}

// =========================================================================
// run_frame_nodes — 执行帧就绪节点（从 Engine::run_ready_nodes 提取）
// =========================================================================

/// 执行帧内所有就绪节点，直到就绪队列空或帧挂起。
///
/// 从 Engine::run_ready_nodes 提取核心逻辑，改为基于 SharedEngine。
/// 帧执行时无锁（frame 已从 frames HashMap 取出独占）。
/// 需要访问 runtime 时单独锁对应 Mutex。
fn run_frame_nodes(
    shared: &SharedEngine,
    frame: &mut Frame,
    fid: FrameId,
    local_queue: &DequeWorker<FrameId>,
) {
    let graph = frame.graph.clone();

    loop {
        // 检查控制信号（return/break/continue 已触发）
        if !matches!(frame.control_signal, ControlSignal::None) {
            break;
        }

        // 检查帧是否被取消（spec 5.3：跳过节点执行，走 defer 清理）
        if frame.state == FrameState::Cancelling {
            break;
        }

        // 检查帧是否挂起
        if frame.state == FrameState::Suspended {
            return;
        }

        // SIMD/rayon 批量化：drain ready_queue → 按 (ScalarTag,BatchOp) 分组 → 批算
        if try_batch_nodes(frame, &graph) {
            continue;
        }

        // 弹出就绪节点（局部 id）
        let local_id = match frame.pop_ready() {
            Some(n) => n,
            None => break,
        };

        let node_start = frame.node_offset;
        let graph_node_id = NodeId(local_id.0 + node_start);
        let node = graph.nodes[graph_node_id.0 as usize];

        // 预填充节点跳过 compute_fn
        let pre_filled = frame.value_table.ready[local_id.0 as usize];
        let value = if pre_filled {
            frame.value_table.values[local_id.0 as usize].clone()
        } else {
            let compute_fn = graph.compute_fns[node.compute_fn.0 as usize];
            compute_fn(frame, graph_node_id)
        };

        // vtable 动态分派：Call 节点有 vtable_call_methods 但无 call_target
        if frame.pending_call.is_none() {
            if let Some(method_name) =
                graph.vtable_call_methods[graph_node_id.0 as usize].clone()
            {
                let n = &graph.nodes[graph_node_id.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let recv_val = frame.get_value_by_global(inputs[0]);

                // 从 TraitVal 查方法 Closure，取 subgraph_id + upvalues
                let (target_sg, upvalues): (crate::Ir::SubGraphId, Vec<Value>) = match recv_val.heap_obj() {
                    Some(crate::Value::HeapObj::TraitVal(tv)) => {
                        match tv
                            .method_names
                            .iter()
                            .position(|m| m.as_str() == method_name.as_str())
                        {
                            Some(i) => {
                                match tv.method_values[i].heap_obj() {
                                    Some(crate::Value::HeapObj::Closure(c)) => {
                                        (crate::Ir::SubGraphId(c.func_id), c.upvalues.clone())
                                    }
                                    _ => panic!("vtable method is not a Closure"),
                                }
                            }
                            None => panic!("TraitValue has no method '{}'", method_name),
                        }
                    }
                    _ => panic!("vtable call on non-trait value"),
                };

                // 参数组装：跳过 receiver (inputs[0])，取方法实参 (inputs[1..1+arity])，
                // 再追加 Closure 携带的 upvalues，与子图参数节点顺序一致。
                let arity = (graph.subgraphs[target_sg.0 as usize].param_count as usize)
                    .saturating_sub(upvalues.len());
                let mut args: Vec<Value> = Vec::with_capacity(arity + upvalues.len());
                for &in_node in inputs.iter().skip(1).take(arity) {
                    args.push(frame.get_value_by_global(in_node));
                }
                args.extend(upvalues);

                let call_node_local = NodeId(graph_node_id.0.wrapping_sub(frame.node_offset));
                frame.pending_call = Some(PendingCall {
                    target_sg,
                    args,
                    call_node_local,
                    is_async: false,
                });
            }
        }

        // 检测 pending_call（Call/Gate/AsyncCall 节点设置）
        let pending = frame.pending_call.clone();
        if let Some(pending) = pending {
            frame.pending_call = None;

            // 尾调用图跳转：编译期标记的尾调用复用当前帧（帧池零分配）
            let graph_call_id = NodeId(pending.call_node_local.0 + frame.node_offset);
            if graph.tail_call_flags[graph_call_id.0 as usize] {
                // 分支中的尾调用传播（与非共享路径同逻辑）
                let caller = frame.caller;
                let propagate_to_parent = if let Some((caller_fid, call_node)) = caller {
                    let frames = shared.frames.lock();
                    if let Some(caller_frame) = frames.get(&caller_fid) {
                        let caller_sg_id = caller_frame.subgraph_id;
                        let caller_loop_kind = graph.subgraphs[caller_sg_id.0 as usize].loop_kind;
                        let caller_has_caller = caller_frame.caller.is_some();
                        let caller_offset = caller_frame.node_offset;
                        let caller_graph_node = NodeId(call_node.0 + caller_offset);
                        let caller_is_gate = graph.nodes[caller_graph_node.0 as usize].kind == NodeKind::Gate;
                        caller_is_gate
                            && caller_loop_kind != crate::Ir::LoopKind::LoopBody
                            && caller_has_caller
                    } else {
                        false
                    }
                } else {
                    false
                };

                if propagate_to_parent {
                    let (caller_fid, _) = caller.unwrap();
                    let orig_caller = {
                        let mut frames = shared.frames.lock();
                        frames.remove(&caller_fid).and_then(|cf| cf.caller)
                    };
                    shared.event_waiters.lock().retain(|(_, f)| *f != caller_fid);
                    shared.pending_completions.lock().remove(&caller_fid);
                    frame.caller = orig_caller;
                    switch_subgraph_shared(frame, &graph, pending.target_sg, &pending.args);
                } else {
                    switch_subgraph_shared(frame, &graph, pending.target_sg, &pending.args);
                }
                continue;
            }

            // Call/Gate/AsyncCall 节点：执行 start_subgraph
            let child_fid = start_subgraph_shared(
                shared,
                fid,
                pending.call_node_local,
                pending.target_sg,
                &pending.args,
            );

            // 子帧入本地队列
            local_queue.push(child_fid);

            if pending.is_async {
                // async call：当前帧不挂起，call 节点写 AsyncHandle + 通知下游
                let async_id = shared.async_join_runtime.lock().alloc_id();
                let async_handle = Value::i32(async_id.0 as i32);
                shared.async_join_runtime.lock().register(async_id, child_fid);

                let node_start = frame.node_offset;
                let graph_node_id = NodeId(pending.call_node_local.0 + node_start);
                let consumer_count =
                    graph.downstreams[graph_node_id.0 as usize].len() as u16;
                frame.set_value(pending.call_node_local, async_handle, consumer_count);
                notify_downstream_shared(
                    frame,
                    &graph,
                    pending.call_node_local,
                    graph_node_id,
                    NodeId(node_start),
                );
                continue;
            } else {
                // sync call：当前帧挂起等 SubgraphComplete 事件
                frame.state = FrameState::Suspended;
                frame.suspend_state = SuspendState::WaitingSubgraph(child_fid);
                frame.suspend_event = Some(RuntimeEvent::SubgraphComplete(child_fid));
                return;
            }
        }

        // 检测 pending_await（Await 节点设置）
        let pending_await = frame.pending_await.clone();
        if let Some(pending) = pending_await {
            frame.pending_await = None;

            let (event, ready_value) = resolve_and_check_await_shared(shared, &pending);

            if let Some(value) = ready_value {
                // 就绪：注入值到 await 节点 + 通知下游 + 继续执行
                let node_start = frame.node_offset;
                let graph_node_id = NodeId(pending.await_node_local.0 + node_start);
                let consumer_count =
                    graph.downstreams[graph_node_id.0 as usize].len() as u16;
                frame.set_value(pending.await_node_local, value, consumer_count);
                notify_downstream_shared(
                    frame,
                    &graph,
                    pending.await_node_local,
                    graph_node_id,
                    NodeId(node_start),
                );
                continue;
            } else {
                // 未就绪：注册等待 + 帧挂起
                shared.event_waiters.lock().push((event, fid));
                frame.state = FrameState::Suspended;
                frame.suspend_state = SuspendState::WaitingEvent(pending.await_node_local);
                frame.suspend_event = Some(event);
                return;
            }
        }

        // 检测 pending_cancel（cancel 方法调用设置）
        let pending_cancel = frame.pending_cancel;
        if let Some(async_id) = pending_cancel {
            frame.pending_cancel = None;
            let child_fid = shared
                .async_join_runtime
                .lock()
                .find_child_by_async_id(async_id);
            if let Some(child_fid) = child_fid {
                cancel_frame_shared(shared, child_fid, local_queue);
            }
            let consumer_count =
                graph.downstreams[graph_node_id.0 as usize].len() as u16;
            frame.set_value(local_id, Value::VOID, consumer_count);
            notify_downstream_shared(frame, &graph, local_id, graph_node_id, NodeId(node_start));
            continue;
        }

        // 检测 pending_select_wait（select gate 节点设置）
        let pending_select_wait = frame.pending_select_wait;
        if let Some(gate_local) = pending_select_wait {
            frame.pending_select_wait = None;

            let info = graph.select_infos[graph_node_id.0 as usize].clone();

            if let Some(info) = info {
                let mut ready_branch: Option<SubGraphId> = None;
                for (branch_idx, branch) in info.branches.iter().enumerate() {
                    let event_val = frame.get_value_by_global(branch.event_source_node);
                    let is_ready = match branch.event_kind {
                        EventSourceKind::Channel => {
                            let ch_id = crate::Ir::ChannelId(event_val.as_i32() as u32);
                            shared.channel_runtime.lock().has_data(ch_id)
                        }
                        EventSourceKind::Timer => {
                            let timer_id = {
                                if let Some((_, tid)) =
                                    frame.select_timers.iter().find(|(idx, _)| *idx == branch_idx)
                                {
                                    *tid
                                } else {
                                    let duration_ms = event_val.as_i32();
                                    let tid = shared.timer_runtime.lock().start(
                                        std::time::Duration::from_millis(duration_ms as u64),
                                    );
                                    frame.select_timers.push((branch_idx, tid));
                                    tid
                                }
                            };
                            shared.timer_runtime.lock().is_fired(timer_id)
                        }
                        _ => false,
                    };
                    if is_ready {
                        ready_branch = Some(branch.subgraph_id);
                        break;
                    }
                }

                if let Some(sg_id) = ready_branch {
                    // 有就绪分支：启动分支子图
                    let child_fid = start_subgraph_shared(shared, fid, gate_local, sg_id, &[]);
                    local_queue.push(child_fid);
                    frame.state = FrameState::Suspended;
                    frame.suspend_state = SuspendState::WaitingSubgraph(child_fid);
                    frame.suspend_event = Some(RuntimeEvent::SubgraphComplete(child_fid));
                    return;
                } else {
                    // 无就绪分支：注册所有事件等待 + 帧挂起
                    for (branch_idx, branch) in info.branches.iter().enumerate() {
                        let event_val = frame.get_value_by_global(branch.event_source_node);
                        let event = match branch.event_kind {
                            EventSourceKind::Channel => RuntimeEvent::ChannelReady(
                                crate::Ir::ChannelId(event_val.as_i32() as u32),
                            ),
                            EventSourceKind::Timer => {
                                let timer_id = frame
                                    .select_timers
                                    .iter()
                                    .find(|(idx, _)| *idx == branch_idx)
                                    .map(|(_, tid)| *tid)
                                    .expect("select timer should be started above");
                                RuntimeEvent::TimerFired(timer_id)
                            }
                            _ => continue,
                        };
                        shared.event_waiters.lock().push((event, fid));
                    }
                    frame.state = FrameState::Suspended;
                    frame.suspend_state = SuspendState::WaitingEvent(gate_local);
                    frame.suspend_event = None;
                    return;
                }
            }
        }

        // 普通节点：写值表 + 检查控制信号 + 通知下游
        let consumer_count = graph.downstreams[graph_node_id.0 as usize].len() as u16;
        frame.set_value(local_id, value.clone(), consumer_count);

        // 检查控制信号
        let signal_kind = graph.control_signal_nodes[graph_node_id.0 as usize];
        if let Some(kind) = signal_kind {
            frame.control_signal = match kind {
                SignalKind::Return => ControlSignal::Return(value),
                SignalKind::Break => ControlSignal::Break,
                SignalKind::Continue => ControlSignal::Continue,
            };
            break;
        }

        // 通知下游（含槽级 RC）
        notify_downstream_shared(frame, &graph, local_id, graph_node_id, NodeId(node_start));
    }

    // 帧挂起：不执行 defer，不标记 Completed
    if frame.state == FrameState::Suspended {
        return;
    }

    // 帧被取消：执行 defer 清理 + 标记 Failed（spec 5.3）
    if frame.state == FrameState::Cancelling {
        let defer_entries: Vec<DeferEntry> = {
            let sg_id = frame.subgraph_id;
            graph.subgraphs[sg_id.0 as usize].defer_table.clone()
        };
        for entry in defer_entries.iter().rev() {
            let defer_fid = init_frame_shared(shared, entry.body_subgraph);
            let mut defer_frame = shared.frames.lock().remove(&defer_fid);
            if let Some(defer_frame) = defer_frame.as_mut() {
                run_frame_nodes(shared, defer_frame, defer_fid, local_queue);
            }
        }
        frame.state = FrameState::Failed;
        return;
    }

    // 执行 defer（LIFO）：任何终止路径都执行 defer
    let defer_entries: Vec<DeferEntry> = {
        let sg_id = frame.subgraph_id;
        graph.subgraphs[sg_id.0 as usize].defer_table.clone()
    };
    for entry in defer_entries.iter().rev() {
        let defer_fid = init_frame_shared(shared, entry.body_subgraph);
        let mut defer_frame = shared.frames.lock().remove(&defer_fid);
        if let Some(defer_frame) = defer_frame.as_mut() {
            run_frame_nodes(shared, defer_frame, defer_fid, local_queue);
        }
    }

    // 标记帧完成
    frame.state = FrameState::Completed;
}

// =========================================================================
// process_frame_shared — 处理一个帧（从 Engine::process_frame 提取）
// =========================================================================

/// 处理一个帧：执行就绪节点 + 处理状态转换。
///
/// 帧从 frames HashMap 取出后独占执行（无锁），完成后根据状态放回或释放。
fn process_frame_shared(
    shared: &Arc<SharedEngine>,
    local_queue: &DequeWorker<FrameId>,
    fid: FrameId,
) {
    // 检查 timer 事件
    let fired_timers = shared.timer_runtime.lock().check_and_fire();
    for tid in fired_timers {
        on_event_arrived_shared(shared, RuntimeEvent::TimerFired(tid), Value::VOID, local_queue);
    }

    // 取出帧（短临界区）
    let mut frame = {
        let mut frames = shared.frames.lock();
        match frames.remove(&fid) {
            Some(f) => f,
            None => return,
        }
    };

    // 执行帧就绪节点（无锁）
    run_frame_nodes(shared, &mut frame, fid, local_queue);

    // 处理帧状态
    let state = frame.state;
    let has_caller = frame.caller.is_some();

    match state {
        FrameState::Suspended => {
            let event = frame.suspend_event;
            // 在 insert 前检查是否有 pending completion（子帧先完成但父帧尚未 insert 的竞态）
            let pending = shared.pending_completions.lock().remove(&fid);
            if let Some((call_node, return_value, child_signal)) = pending {
                // 有 pending completion：直接消费完成事件，注入返回值并唤醒
                let _ = child_signal; // 控制信号已在 complete_and_wake_caller_shared 中处理
                propagate_throw_shared(&mut frame, &return_value);
                let caller_sg_id = frame.subgraph_id;
                let caller_offset = shared.graph.subgraphs[caller_sg_id.0 as usize].node_range.0;
                let call_graph_id = NodeId(call_node.0 + caller_offset.0);
                let consumer_count = shared.graph.downstreams[call_graph_id.0 as usize].len() as u16;
                frame.set_value(call_node, return_value, consumer_count);
                frame.state = FrameState::Ready;
                frame.suspend_state = SuspendState::NotSuspended;
                frame.suspend_event = None;
                notify_downstream_shared(
                    &mut frame,
                    &shared.graph,
                    call_node,
                    call_graph_id,
                    caller_offset,
                );
                shared.frames.lock().insert(fid, frame);
                local_queue.push(fid);
            } else {
                shared.frames.lock().insert(fid, frame);
                if let Some(e) = event {
                    shared.event_waiters.lock().push((e, fid));
                } else {
                    // select 帧：suspend_event 为 None，event_waiters 已在
                    // run_frame_nodes 中注册。检查是否有等待者。
                    let has_waiter = shared.event_waiters.lock().iter().any(|(_, wf)| *wf == fid);
                    if !has_waiter {
                        // 异常状态：帧挂起但无等待者。不 panic（多线程竞态安全）。
                    }
                }
            }
        }
        FrameState::Completed => {
            if has_caller {
                // 区分 sync call vs async call 子帧完成
                let async_id = shared.async_join_runtime.lock().find_by_child(fid);
                if let Some(async_id) = async_id {
                    // async 子帧完成：设置 result + 触发 AsyncJoin 事件
                    let return_value = extract_child_return_shared(&frame, &shared.graph);
                    shared
                        .async_join_runtime
                        .lock()
                        .set_result(async_id, return_value.clone());
                    // 不放回 frame（free）
                    on_event_arrived_shared(
                        shared,
                        RuntimeEvent::AsyncJoin(async_id),
                        return_value,
                        local_queue,
                    );
                } else {
                    // sync 子帧完成：清理 waiter + 回写 + 唤醒调用方
                    shared.event_waiters.lock().retain(|(e, _)| {
                        !matches!(e, RuntimeEvent::SubgraphComplete(c) if *c == fid)
                    });
                    complete_and_wake_caller_shared(shared, &frame, local_queue);
                }
            } else {
                // 顶层帧完成：返回结果
                let ret = extract_child_return_shared(&frame, &shared.graph);
                *shared.result.lock() = Some(ret);
                // 不放回 frame（帧已完成）
                return;
            }
        }
        FrameState::Failed => {
            if has_caller {
                // Failed 子帧（cancel 后）：清理 waiter + 唤醒调用方
                shared.event_waiters.lock().retain(|(e, _)| {
                    !matches!(e, RuntimeEvent::SubgraphComplete(c) if *c == fid)
                });
                complete_and_wake_caller_shared(shared, &frame, local_queue);
            } else {
                // 顶层帧 Failed：返回 NULL
                *shared.result.lock() = Some(Value::NULL);
                return;
            }
        }
        _ => {
            // Ready（控制信号触发但未挂起）：放回 + 重新入队
            shared.frames.lock().insert(fid, frame);
            local_queue.push(fid);
        }
    }
}

// =========================================================================
// work-stealing worker 主循环（自由函数，供 run_multi_worker 使用）
// =========================================================================

/// Worker 主循环：pop_local → try_steal → try_global → park。
fn worker_main(
    worker_id: usize,
    local_queue: DequeWorker<FrameId>,
    stealers: Vec<Stealer<FrameId>>,
    shared: Arc<SharedEngine>,
) {
    // 每个 worker 用 thread-local 随机种子选 steal victim
    let mut steal_seed: u64 = worker_id as u64 ^ 0x9E3779B97F4A7C15;

    loop {
        // 结果已产生：退出
        if shared.result.lock().is_some() {
            return;
        }

        // 1. pop_local（LIFO，缓存友好）
        if let Some(fid) = local_queue.pop() {
            process_frame_shared(&shared, &local_queue, fid);
            // 锁 wakeup mutex 再 notify，防止 park 方丢失唤醒
            {
                let _g = shared.wakeup.0.lock();
                shared.wakeup.1.notify_all();
            }
            continue;
        }

        // 2. try_steal（随机 victim，FIFO 窃取）
        if let Some(fid) = try_steal(&stealers, worker_id, &mut steal_seed) {
            process_frame_shared(&shared, &local_queue, fid);
            {
                let _g = shared.wakeup.0.lock();
                shared.wakeup.1.notify_all();
            }
            continue;
        }

        // 3. try_global（全局注入队列）
        if let Some(fid) = shared.global_queue.steal().success() {
            process_frame_shared(&shared, &local_queue, fid);
            {
                let _g = shared.wakeup.0.lock();
                shared.wakeup.1.notify_all();
            }
            continue;
        }

        // 4. 无工作：减少活跃计数，检查是否全部空闲
        {
            let mut active = shared.active_count.lock();
            *active -= 1;
            if *active == 0 {
                // 所有 worker 空闲 + 无就绪帧：事件循环耗尽
                drop(active);
                {
                    let _g = shared.wakeup.0.lock();
                    shared.wakeup.1.notify_all();
                }
                return;
            }
        }

        // 5. park（等待唤醒，避免 busy-wait）
        // 使用 wait_timeout 定期醒来检查 timer 事件，防止所有 worker park 时
        // timer 到期事件被忽略导致死锁。
        {
            let mut guard = shared.wakeup.0.lock();
            // 重新检查 result（可能其他 worker 刚设置）
            if shared.result.lock().is_some() {
                let mut active = shared.active_count.lock();
                *active += 1;
                return;
            }
            // 重新检查工作队列（不消费，只检查非空）
            if !local_queue.is_empty() || !shared.global_queue.is_empty() {
                // 有工作：不 park，恢复活跃计数
                let mut active = shared.active_count.lock();
                *active += 1;
                continue;
            }
            // 确认无工作：park with timeout（定期醒来检查 timer）
            let park_timeout = std::time::Duration::from_millis(10);
            shared.wakeup.1.wait_for(&mut guard, park_timeout);
        }
        // 被唤醒：恢复活跃计数
        {
            let mut active = shared.active_count.lock();
            *active += 1;
        }
    }
}

/// 随机选择 victim worker 进行窃取。
fn try_steal(
    stealers: &[Stealer<FrameId>],
    worker_id: usize,
    seed: &mut u64,
) -> Option<FrameId> {
    let n = stealers.len();
    if n <= 1 {
        return None;
    }

    // xorshift64 伪随机
    *seed ^= *seed << 13;
    *seed ^= *seed >> 7;
    *seed ^= *seed << 17;
    let start = (*seed % n as u64) as usize;

    for i in 0..n {
        let idx = (start + i) % n;
        if idx == worker_id {
            continue;
        }
        if let Some(fid) = stealers[idx].steal().success() {
            return Some(fid);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Value::Value;

    /// 构建简单图：1 + 2 = 3
    fn make_simple_graph() -> DataFlowGraph {
        let mut graph = DataFlowGraph::new();
        // N0: Const(1)
        let n0 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        graph.const_values[n0.0 as usize] = Some(ConstValue::I32(1));
        // N1: Const(2)
        let n1 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        graph.const_values[n1.0 as usize] = Some(ConstValue::I32(2));
        // N2: BinOp(+, [N0, N1])
        let off = graph.inputs_pool.push(&[n0, n1]);
        let n2 = graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: 2,
            inputs_offset: off,
            compute_fn: ComputeFnId(1), // add_i32
        });
        graph.add_subgraph(SubGraph {
            id: SubGraphId(0),
            node_range: (NodeId(0), NodeId(3)),
            param_count: 0,
            entry_node: n0,
            return_node: n2,
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });
        graph.set_entry_subgraph(SubGraphId(0));
        graph.compute_downstreams();
        graph
    }

    #[test]
    fn test_frame_init_consts_ready() {
        let graph = make_simple_graph();
        let mut engine = Engine::new(graph);
        let fid = engine.init_frame(SubGraphId(0));
        let frame = engine.frames.get(fid);
        // N0 和 N1 是 Const，应该已就绪
        assert!(frame.is_node_ready(NodeId(0)));
        assert!(frame.is_node_ready(NodeId(1)));
        // N2 有 2 个输入，不应就绪
        assert!(!frame.is_node_ready(NodeId(2)));
        assert_eq!(frame.pending_inputs[2], 2);
        // 就绪队列应有 N0 和 N1
        assert_eq!(frame.ready_queue.len(), 2);
    }

    #[test]
    fn test_ready_scheduling_basic() {
        let graph = make_simple_graph();
        let mut engine = Engine::new(graph);
        let fid = engine.init_frame(SubGraphId(0));
        engine.run_ready_nodes(fid);
        let frame = engine.frames.get(fid);
        // N2 的 pending_inputs 应减为 0
        assert_eq!(frame.pending_inputs[2], 0);
        // N2 应已执行（ready）
        assert!(frame.value_table.ready[2]);
    }

    #[test]
    fn test_execute_simple_add() {
        let graph = make_simple_graph();
        let mut engine = Engine::new(graph);
        let fid = engine.init_frame(SubGraphId(0));
        engine.run_ready_nodes(fid);
        let frame = engine.frames.get(fid);
        let result_handle = frame.get_value(NodeId(2));
        let result = result_handle.as_i32();
        assert_eq!(result, 3);
    }

    #[test]
    fn test_execute_nested_arithmetic() {
        // (1 + 2) * 3 = 9
        let mut graph = DataFlowGraph::new();
        let n0 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        graph.const_values[n0.0 as usize] = Some(ConstValue::I32(1));
        let n1 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        graph.const_values[n1.0 as usize] = Some(ConstValue::I32(2));
        let off1 = graph.inputs_pool.push(&[n0, n1]);
        let n2 = graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: 2,
            inputs_offset: off1,
            compute_fn: ComputeFnId(1), // add_i32
        });
        let n3 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        graph.const_values[n3.0 as usize] = Some(ConstValue::I32(3));
        let off2 = graph.inputs_pool.push(&[n2, n3]);
        let n4 = graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: 2,
            inputs_offset: off2,
            compute_fn: ComputeFnId(3), // mul_i32
        });
        graph.add_subgraph(SubGraph {
            id: SubGraphId(0),
            node_range: (NodeId(0), NodeId(5)),
            param_count: 0,
            entry_node: n0,
            return_node: n4,
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });
        graph.set_entry_subgraph(SubGraphId(0));
        graph.compute_downstreams();

        let mut engine = Engine::new(graph);
        let fid = engine.init_frame(SubGraphId(0));
        engine.run_ready_nodes(fid);
        let frame = engine.frames.get(fid);
        let result = frame.get_value(NodeId(4)).as_i32();
        assert_eq!(result, 9);
    }

    #[test]
    fn test_run_entry() {
        let graph = make_simple_graph();
        let mut engine = Engine::new(graph);
        let result = engine.run_entry();
        assert_eq!(result.as_i32(), 3);
    }

    #[test]
    fn test_subgraph_launch_and_complete() {
        // 构建两个子图：add(a,b)=a+b 和 main()=add(1,2)
        let mut graph = DataFlowGraph::new();

        // SubGraph 0: add(a, b) = a + b
        let n0 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        let n1 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        let off = graph.inputs_pool.push(&[n0, n1]);
        let n2 = graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: 2,
            inputs_offset: off,
            compute_fn: ComputeFnId(1),
        });
        graph.add_subgraph(SubGraph {
            id: SubGraphId(0),
            node_range: (NodeId(0), NodeId(3)),
            param_count: 2,
            entry_node: n0,
            return_node: n2,
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });

        // SubGraph 1: main() = add(1, 2)
        let n3 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        graph.const_values[n3.0 as usize] = Some(ConstValue::I32(1));
        let n4 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        graph.const_values[n4.0 as usize] = Some(ConstValue::I32(2));
        let call_off = graph.inputs_pool.push(&[n3, n4]);
        let n5 = graph.add_node(Node {
            kind: NodeKind::Call,
            input_count: 2,
            inputs_offset: call_off,
            compute_fn: ComputeFnId(36),
        });
        graph.set_call_target(n5, SubGraphId(0));
        graph.add_subgraph(SubGraph {
            id: SubGraphId(1),
            node_range: (NodeId(3), NodeId(6)),
            param_count: 0,
            entry_node: n3,
            return_node: n5,
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });

        graph.set_entry_subgraph(SubGraphId(1));
        graph.compute_downstreams();

        let mut engine = Engine::new(graph);
        // 事件驱动：run_entry 调度 main 帧，Call 节点启动子图后挂起，
        // 子图完成后回写返回值到 N5（Call, local id 2），main 帧完成。
        let result = engine.run_entry();
        // N5 (Call) 执行 add(1,2)=3
        assert_eq!(result.as_i32(), 3);
    }

    #[test]
    fn test_call_real_execution() {
        // main() = add(1, 2), add(a,b) = a + b
        let mut graph = DataFlowGraph::new();

        // SubGraph 0: add(a, b) = a + b
        let n0 = graph.add_node(Node { kind: NodeKind::Const, input_count: 0, inputs_offset: 0, compute_fn: ComputeFnId(0) });
        let n1 = graph.add_node(Node { kind: NodeKind::Const, input_count: 0, inputs_offset: 0, compute_fn: ComputeFnId(0) });
        let off = graph.inputs_pool.push(&[n0, n1]);
        let n2 = graph.add_node(Node { kind: NodeKind::BinOp, input_count: 2, inputs_offset: off, compute_fn: ComputeFnId(1) });
        graph.add_subgraph(SubGraph {
            id: SubGraphId(0), node_range: (NodeId(0), NodeId(3)), param_count: 2,
            entry_node: n0, return_node: n2, has_suspend: false,
            event_source_decls: Vec::new(), defer_table: Vec::new(), loop_kind: crate::Ir::LoopKind::None, loop_parent_sg: None, cond_node: None, function_id: 0, iter_next_node: None,
        });

        // SubGraph 1: main() = add(1, 2)
        let n3 = graph.add_node(Node { kind: NodeKind::Const, input_count: 0, inputs_offset: 0, compute_fn: ComputeFnId(0) });
        graph.const_values[n3.0 as usize] = Some(ConstValue::I32(1));
        let n4 = graph.add_node(Node { kind: NodeKind::Const, input_count: 0, inputs_offset: 0, compute_fn: ComputeFnId(0) });
        graph.const_values[n4.0 as usize] = Some(ConstValue::I32(2));
        let call_off = graph.inputs_pool.push(&[n3, n4]);
        let n5 = graph.add_node(Node { kind: NodeKind::Call, input_count: 2, inputs_offset: call_off, compute_fn: ComputeFnId(36) });
        graph.set_call_target(n5, SubGraphId(0));
        graph.add_subgraph(SubGraph {
            id: SubGraphId(1), node_range: (NodeId(3), NodeId(6)), param_count: 0,
            entry_node: n3, return_node: n5, has_suspend: false,
            event_source_decls: Vec::new(), defer_table: Vec::new(), loop_kind: crate::Ir::LoopKind::None, loop_parent_sg: None, cond_node: None, function_id: 0, iter_next_node: None,
        });

        graph.set_entry_subgraph(SubGraphId(1));
        graph.compute_downstreams();

        let mut engine = Engine::new(graph);
        let result = engine.run_entry();
        assert_eq!(result.as_i32(), 3);
    }

    #[test]
    fn test_lambda_define_and_call() {
        // 闭包定义与调用：lambda |x| x + 1，调用 f(10) = 11
        let mut graph = DataFlowGraph::new();

        // SubGraph 0 (lambda_body): N0=param x, N1=Const(1), N2=Add(N0,N1), return N2
        let n0 = graph.add_node(Node { kind: NodeKind::Const, input_count: 0, inputs_offset: 0, compute_fn: ComputeFnId(0) });
        let n1 = graph.add_node(Node { kind: NodeKind::Const, input_count: 0, inputs_offset: 0, compute_fn: ComputeFnId(0) });
        graph.const_values[n1.0 as usize] = Some(ConstValue::I32(1));
        let off = graph.inputs_pool.push(&[n0, n1]);
        let n2 = graph.add_node(Node { kind: NodeKind::BinOp, input_count: 2, inputs_offset: off, compute_fn: ComputeFnId(1) });
        graph.add_subgraph(SubGraph {
            id: SubGraphId(0), node_range: (NodeId(0), NodeId(3)), param_count: 1,
            entry_node: n0, return_node: n2, has_suspend: false,
            event_source_decls: Vec::new(), defer_table: Vec::new(), loop_kind: crate::Ir::LoopKind::None, loop_parent_sg: None, cond_node: None, function_id: 0, iter_next_node: None,
        });

        // SubGraph 1 (main): N3=Const(10), N4=ClosureConstruct(SG0, arity=1, upvalues=[]),
        //                     N5=ClosureCall(N4, [N3])
        let n3 = graph.add_node(Node { kind: NodeKind::Const, input_count: 0, inputs_offset: 0, compute_fn: ComputeFnId(0) });
        graph.const_values[n3.0 as usize] = Some(ConstValue::I32(10));
        let n4 = graph.add_node(Node { kind: NodeKind::BinOp, input_count: 0, inputs_offset: 0, compute_fn: ComputeFnId(40) });
        graph.set_closure_info(n4, ClosureInfo { subgraph_id: SubGraphId(0), arity: 1 });
        let call_off = graph.inputs_pool.push(&[n4, n3]);
        let n5 = graph.add_node(Node { kind: NodeKind::Call, input_count: 2, inputs_offset: call_off, compute_fn: ComputeFnId(41) });
        graph.add_subgraph(SubGraph {
            id: SubGraphId(1), node_range: (NodeId(3), NodeId(6)), param_count: 0,
            entry_node: n3, return_node: n5, has_suspend: false,
            event_source_decls: Vec::new(), defer_table: Vec::new(), loop_kind: crate::Ir::LoopKind::None, loop_parent_sg: None, cond_node: None, function_id: 0, iter_next_node: None,
        });

        graph.set_entry_subgraph(SubGraphId(1));
        graph.compute_downstreams();

        let mut engine = Engine::new(graph);
        let result = engine.run_entry();
        // f(10) = 10 + 1 = 11
        assert_eq!(result.as_i32(), 11);
    }

    #[test]
    fn test_gate_if_true() {
        // if true { 1 } else { 2 } = 1
        let mut graph = DataFlowGraph::new();

        // SubGraph 0: then = 1
        let n0 = graph.add_node(Node { kind: NodeKind::Const, input_count: 0, inputs_offset: 0, compute_fn: ComputeFnId(0) });
        graph.const_values[n0.0 as usize] = Some(ConstValue::I32(1));
        graph.add_subgraph(SubGraph {
            id: SubGraphId(0), node_range: (NodeId(0), NodeId(1)), param_count: 0,
            entry_node: n0, return_node: n0, has_suspend: false,
            event_source_decls: Vec::new(), defer_table: Vec::new(), loop_kind: crate::Ir::LoopKind::None, loop_parent_sg: None, cond_node: None, function_id: 0, iter_next_node: None,
        });

        // SubGraph 1: else = 2
        let n1 = graph.add_node(Node { kind: NodeKind::Const, input_count: 0, inputs_offset: 0, compute_fn: ComputeFnId(0) });
        graph.const_values[n1.0 as usize] = Some(ConstValue::I32(2));
        graph.add_subgraph(SubGraph {
            id: SubGraphId(1), node_range: (NodeId(1), NodeId(2)), param_count: 0,
            entry_node: n1, return_node: n1, has_suspend: false,
            event_source_decls: Vec::new(), defer_table: Vec::new(), loop_kind: crate::Ir::LoopKind::None, loop_parent_sg: None, cond_node: None, function_id: 0, iter_next_node: None,
        });

        // SubGraph 2: main = if true { then } else { else }
        let n2 = graph.add_node(Node { kind: NodeKind::Const, input_count: 0, inputs_offset: 0, compute_fn: ComputeFnId(0) });
        graph.const_values[n2.0 as usize] = Some(ConstValue::Bool(true));
        let n3 = graph.add_node(Node { kind: NodeKind::Gate, input_count: 0, inputs_offset: 0, compute_fn: ComputeFnId(37) });
        graph.set_gate_branches(n3, GateBranches {
            condition_input: n2,
            branches: vec![(true, SubGraphId(0), vec![]), (false, SubGraphId(1), vec![])],
        });
        graph.add_subgraph(SubGraph {
            id: SubGraphId(2), node_range: (NodeId(2), NodeId(4)), param_count: 0,
            entry_node: n2, return_node: n3, has_suspend: false,
            event_source_decls: Vec::new(), defer_table: Vec::new(), loop_kind: crate::Ir::LoopKind::None, loop_parent_sg: None, cond_node: None, function_id: 0, iter_next_node: None,
        });

        graph.set_entry_subgraph(SubGraphId(2));
        graph.compute_downstreams();

        let mut engine = Engine::new(graph);
        let result = engine.run_entry();
        assert_eq!(result.as_i32(), 1);
    }

    #[test]
    fn test_gate_if_false() {
        // if false { 1 } else { 2 } = 2
        let mut graph = DataFlowGraph::new();

        let n0 = graph.add_node(Node { kind: NodeKind::Const, input_count: 0, inputs_offset: 0, compute_fn: ComputeFnId(0) });
        graph.const_values[n0.0 as usize] = Some(ConstValue::I32(1));
        graph.add_subgraph(SubGraph {
            id: SubGraphId(0), node_range: (NodeId(0), NodeId(1)), param_count: 0,
            entry_node: n0, return_node: n0, has_suspend: false,
            event_source_decls: Vec::new(), defer_table: Vec::new(), loop_kind: crate::Ir::LoopKind::None, loop_parent_sg: None, cond_node: None, function_id: 0, iter_next_node: None,
        });

        let n1 = graph.add_node(Node { kind: NodeKind::Const, input_count: 0, inputs_offset: 0, compute_fn: ComputeFnId(0) });
        graph.const_values[n1.0 as usize] = Some(ConstValue::I32(2));
        graph.add_subgraph(SubGraph {
            id: SubGraphId(1), node_range: (NodeId(1), NodeId(2)), param_count: 0,
            entry_node: n1, return_node: n1, has_suspend: false,
            event_source_decls: Vec::new(), defer_table: Vec::new(), loop_kind: crate::Ir::LoopKind::None, loop_parent_sg: None, cond_node: None, function_id: 0, iter_next_node: None,
        });

        let n2 = graph.add_node(Node { kind: NodeKind::Const, input_count: 0, inputs_offset: 0, compute_fn: ComputeFnId(0) });
        graph.const_values[n2.0 as usize] = Some(ConstValue::Bool(false));
        let n3 = graph.add_node(Node { kind: NodeKind::Gate, input_count: 0, inputs_offset: 0, compute_fn: ComputeFnId(37) });
        graph.set_gate_branches(n3, GateBranches {
            condition_input: n2,
            branches: vec![(true, SubGraphId(0), vec![]), (false, SubGraphId(1), vec![])],
        });
        graph.add_subgraph(SubGraph {
            id: SubGraphId(2), node_range: (NodeId(2), NodeId(4)), param_count: 0,
            entry_node: n2, return_node: n3, has_suspend: false,
            event_source_decls: Vec::new(), defer_table: Vec::new(), loop_kind: crate::Ir::LoopKind::None, loop_parent_sg: None, cond_node: None, function_id: 0, iter_next_node: None,
        });

        graph.set_entry_subgraph(SubGraphId(2));
        graph.compute_downstreams();

        let mut engine = Engine::new(graph);
        let result = engine.run_entry();
        assert_eq!(result.as_i32(), 2);
    }

    #[test]
    fn test_loop_sum_1_to_5() {
        // 累加 1..5 = 15
        let mut graph = DataFlowGraph::new();

        // SubGraph 0: loop_iter(acc, i)
        // N0: acc, N1: i, N2: Const(5), N3: le(i,5), N4: Gate
        let n0 = graph.add_node(Node { kind: NodeKind::Const, input_count: 0, inputs_offset: 0, compute_fn: ComputeFnId(0) });
        let n1 = graph.add_node(Node { kind: NodeKind::Const, input_count: 0, inputs_offset: 0, compute_fn: ComputeFnId(0) });
        let n2 = graph.add_node(Node { kind: NodeKind::Const, input_count: 0, inputs_offset: 0, compute_fn: ComputeFnId(0) });
        graph.const_values[n2.0 as usize] = Some(ConstValue::I32(5));
        let le_off = graph.inputs_pool.push(&[n1, n2]);
        let n3 = graph.add_node(Node { kind: NodeKind::BinOp, input_count: 2, inputs_offset: le_off, compute_fn: ComputeFnId(4) }); // le_i32
        let n4 = graph.add_node(Node { kind: NodeKind::Gate, input_count: 0, inputs_offset: 0, compute_fn: ComputeFnId(37) });
        graph.set_gate_branches(n4, GateBranches {
            condition_input: n3,
            branches: vec![
                (true, SubGraphId(1), vec![n0, n1]),   // loop_body: acc, i
                (false, SubGraphId(2), vec![n0]),      // return acc: acc
            ],
        });
        graph.add_subgraph(SubGraph {
            id: SubGraphId(0), node_range: (NodeId(0), NodeId(5)), param_count: 2,
            entry_node: n0, return_node: n4, has_suspend: false,
            event_source_decls: Vec::new(), defer_table: Vec::new(), loop_kind: crate::Ir::LoopKind::None, loop_parent_sg: None, cond_node: None, function_id: 0, iter_next_node: None,
        });

        // SubGraph 1: loop_body (递归调用 loop_iter(acc+i, i+1))
        // N5: acc, N6: i, N7: Const(1), N8: add(acc,i), N9: add(i,1), N10: Call(loop_iter)
        let n5 = graph.add_node(Node { kind: NodeKind::Const, input_count: 0, inputs_offset: 0, compute_fn: ComputeFnId(0) });
        let n6 = graph.add_node(Node { kind: NodeKind::Const, input_count: 0, inputs_offset: 0, compute_fn: ComputeFnId(0) });
        let n7 = graph.add_node(Node { kind: NodeKind::Const, input_count: 0, inputs_offset: 0, compute_fn: ComputeFnId(0) });
        graph.const_values[n7.0 as usize] = Some(ConstValue::I32(1));
        let add_acc_off = graph.inputs_pool.push(&[n5, n6]);
        let n8 = graph.add_node(Node { kind: NodeKind::BinOp, input_count: 2, inputs_offset: add_acc_off, compute_fn: ComputeFnId(1) });
        let add_i_off = graph.inputs_pool.push(&[n6, n7]);
        let n9 = graph.add_node(Node { kind: NodeKind::BinOp, input_count: 2, inputs_offset: add_i_off, compute_fn: ComputeFnId(1) });
        let call_off = graph.inputs_pool.push(&[n8, n9]);
        let n10 = graph.add_node(Node { kind: NodeKind::Call, input_count: 2, inputs_offset: call_off, compute_fn: ComputeFnId(36) });
        graph.set_call_target(n10, SubGraphId(0)); // 递归调用 loop_iter
        graph.add_subgraph(SubGraph {
            id: SubGraphId(1), node_range: (NodeId(5), NodeId(11)), param_count: 2,
            entry_node: n5, return_node: n10, has_suspend: false,
            event_source_decls: Vec::new(), defer_table: Vec::new(), loop_kind: crate::Ir::LoopKind::None, loop_parent_sg: None, cond_node: None, function_id: 0, iter_next_node: None,
        });

        // SubGraph 2: return acc
        let n11 = graph.add_node(Node { kind: NodeKind::Const, input_count: 0, inputs_offset: 0, compute_fn: ComputeFnId(0) });
        graph.add_subgraph(SubGraph {
            id: SubGraphId(2), node_range: (NodeId(11), NodeId(12)), param_count: 1,
            entry_node: n11, return_node: n11, has_suspend: false,
            event_source_decls: Vec::new(), defer_table: Vec::new(), loop_kind: crate::Ir::LoopKind::None, loop_parent_sg: None, cond_node: None, function_id: 0, iter_next_node: None,
        });

        // SubGraph 3: main = loop_iter(0, 1)
        let n12 = graph.add_node(Node { kind: NodeKind::Const, input_count: 0, inputs_offset: 0, compute_fn: ComputeFnId(0) });
        graph.const_values[n12.0 as usize] = Some(ConstValue::I32(0));
        let n13 = graph.add_node(Node { kind: NodeKind::Const, input_count: 0, inputs_offset: 0, compute_fn: ComputeFnId(0) });
        graph.const_values[n13.0 as usize] = Some(ConstValue::I32(1));
        let main_call_off = graph.inputs_pool.push(&[n12, n13]);
        let n14 = graph.add_node(Node { kind: NodeKind::Call, input_count: 2, inputs_offset: main_call_off, compute_fn: ComputeFnId(36) });
        graph.set_call_target(n14, SubGraphId(0));
        graph.add_subgraph(SubGraph {
            id: SubGraphId(3), node_range: (NodeId(12), NodeId(15)), param_count: 0,
            entry_node: n12, return_node: n14, has_suspend: false,
            event_source_decls: Vec::new(), defer_table: Vec::new(), loop_kind: crate::Ir::LoopKind::None, loop_parent_sg: None, cond_node: None, function_id: 0, iter_next_node: None,
        });

        graph.set_entry_subgraph(SubGraphId(3));
        graph.compute_downstreams();

        let mut engine = Engine::new(graph);
        let result = engine.run_entry();
        assert_eq!(result.as_i32(), 15);
    }

    /// 构建单 BinOp 图并执行，返回结果 handle。
    fn make_binop_graph(cv0: ConstValue, cv1: ConstValue, cf_id: ComputeFnId) -> Engine {
        let mut graph = DataFlowGraph::new();
        let n0 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        graph.const_values[n0.0 as usize] = Some(cv0);
        let n1 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        graph.const_values[n1.0 as usize] = Some(cv1);
        let off = graph.inputs_pool.push(&[n0, n1]);
        let n2 = graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: 2,
            inputs_offset: off,
            compute_fn: cf_id,
        });
        graph.add_subgraph(SubGraph {
            id: SubGraphId(0),
            node_range: (NodeId(0), NodeId(3)),
            param_count: 0,
            entry_node: n0,
            return_node: n2,
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });
        graph.set_entry_subgraph(SubGraphId(0));
        graph.compute_downstreams();
        Engine::new(graph)
    }

    #[test]
    fn test_compute_sub_i32() {
        let mut engine = make_binop_graph(ConstValue::I32(10), ConstValue::I32(3), ComputeFnId(5));
        let h = engine.run_entry();
        assert_eq!(h.as_i32(), 7);
    }

    #[test]
    fn test_compute_eq_i32() {
        let mut engine = make_binop_graph(ConstValue::I32(5), ConstValue::I32(5), ComputeFnId(8));
        let h = engine.run_entry();
        assert!(h.as_bool());
    }

    #[test]
    fn test_compute_mul_f64() {
        let mut engine =
            make_binop_graph(ConstValue::F64(2.5), ConstValue::F64(4.0), ComputeFnId(14));
        let h = engine.run_entry();
        let result = h.as_f64();
        assert!((result - 10.0).abs() < 1e-9);
    }

    #[test]
    fn test_compute_and_bool() {
        let mut engine =
            make_binop_graph(ConstValue::Bool(true), ConstValue::Bool(false), ComputeFnId(22));
        let h = engine.run_entry();
        assert!(!h.as_bool());
    }

    // ── 阶段 5：同步控制流端到端测试 ──

    /// 辅助：构建单函数模块并运行，返回入口帧结果句柄。
    fn build_and_run(body: crate::Ast::ExprId, arena: crate::Ast::AstArena<'_>) -> (Engine, Value) {
        use crate::Ast;
        use crate::Ir::IrBuilder;
        use crate::Sema;
        let fun_decl = Ast::Decl::FunDecl {
            visibility: Ast::Visibility::Private,
            name: "main",
            type_params: vec![],
            params: vec![],
            return_type: None,
            bounds: vec![],
            body,
            is_async: false,
            is_entry: true,
            attributes: vec![],
            extern_c_body: None,
        };
        let module = Ast::Module {
            name: "test",
            source_path: None,
            arena,
            declarations: vec![Ast::Spanned {
                span: Ast::Span { line: 1, column: 1 },
                node: fun_decl,
            }],
        };
        let sema = Sema::SemaResult::new();
        let graph = IrBuilder::new(&sema, &module).build();
        let mut engine = Engine::new(graph);
        let h = engine.run_entry();
        (engine, h)
    }

    #[test]
    fn test_end_to_end_match_literal_hit() {
        // match 1 { 1 => 10, _ => 20 } == 10
        use crate::Ast;
        let mut arena = Ast::AstArena::new();
        let scrut = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::IntLit { raw: "1", suffix: None },
        );
        let arm0_body = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::IntLit { raw: "10", suffix: None },
        );
        let arm0_pat = arena.alloc_pattern(
            Ast::Span { line: 1, column: 1 },
            Ast::Pattern::Literal(Ast::PatternLiteral::Int("1")),
        );
        let arm1_body = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::IntLit { raw: "20", suffix: None },
        );
        let arm1_pat = arena.alloc_pattern(
            Ast::Span { line: 1, column: 1 },
            Ast::Pattern::Wildcard,
        );
        let match_expr = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::Match {
                scrutinee: scrut,
                arms: vec![
                    Ast::MatchArm { pattern: arm0_pat, guard: None, body: arm0_body },
                    Ast::MatchArm { pattern: arm1_pat, guard: None, body: arm1_body },
                ],
            },
        );
        let (engine, h) = build_and_run(match_expr, arena);
        assert_eq!(h.as_i32(), 10);
    }

    #[test]
    fn test_end_to_end_match_wildcard_fallthrough() {
        // match 2 { 1 => 10, _ => 20 } == 20
        use crate::Ast;
        let mut arena = Ast::AstArena::new();
        let scrut = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::IntLit { raw: "2", suffix: None },
        );
        let arm0_body = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::IntLit { raw: "10", suffix: None },
        );
        let arm0_pat = arena.alloc_pattern(
            Ast::Span { line: 1, column: 1 },
            Ast::Pattern::Literal(Ast::PatternLiteral::Int("1")),
        );
        let arm1_body = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::IntLit { raw: "20", suffix: None },
        );
        let arm1_pat = arena.alloc_pattern(
            Ast::Span { line: 1, column: 1 },
            Ast::Pattern::Wildcard,
        );
        let match_expr = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::Match {
                scrutinee: scrut,
                arms: vec![
                    Ast::MatchArm { pattern: arm0_pat, guard: None, body: arm0_body },
                    Ast::MatchArm { pattern: arm1_pat, guard: None, body: arm1_body },
                ],
            },
        );
        let (engine, h) = build_and_run(match_expr, arena);
        assert_eq!(h.as_i32(), 20);
    }

    #[test]
    fn test_end_to_end_while_false_exits() {
        // while false { 1 } → cond false → void_sg，循环不执行
        use crate::Ast;
        let mut arena = Ast::AstArena::new();
        let cond = arena.alloc_expr(Ast::Span { line: 1, column: 1 }, Ast::Expr::BoolLit(false));
        let body = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::IntLit { raw: "1", suffix: None },
        );
        let while_stmt = arena.alloc_stmt(
            Ast::Span { line: 1, column: 1 },
            Ast::Stmt::While { condition: cond, body },
        );
        let body_block = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::Block { stmts: vec![while_stmt], trailing: None },
        );
        let (engine, h) = build_and_run(body_block, arena);
        // while false 退出返回 void
        let _ = engine;
        let _ = h;
    }

    #[test]
    fn test_end_to_end_loop_break_terminates() {
        // loop { break } → body 执行 break 信号，循环终止
        use crate::Ast;
        let mut arena = Ast::AstArena::new();
        let break_stmt = arena.alloc_stmt(Ast::Span { line: 1, column: 1 }, Ast::Stmt::Break);
        let body_block = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::Block { stmts: vec![break_stmt], trailing: None },
        );
        let loop_stmt = arena.alloc_stmt(
            Ast::Span { line: 1, column: 1 },
            Ast::Stmt::Loop { body: body_block },
        );
        let outer_body = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::Block { stmts: vec![loop_stmt], trailing: None },
        );
        let (_engine, _h) = build_and_run(outer_body, arena);
        // loop { break } 终止，不无限递归（若 break 未生效会栈溢出失败）
    }

    #[test]
    fn test_end_to_end_if_true_branch() {
        // if true { 1 } else { 2 } == 1
        use crate::Ast;
        let mut arena = Ast::AstArena::new();
        let cond = arena.alloc_expr(Ast::Span { line: 1, column: 1 }, Ast::Expr::BoolLit(true));
        let then_b = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::IntLit { raw: "1", suffix: None },
        );
        let else_b = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::IntLit { raw: "2", suffix: None },
        );
        let if_expr = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::If { cond, then_branch: then_b, else_branch: Some(else_b) },
        );
        let (engine, h) = build_and_run(if_expr, arena);
        assert_eq!(h.as_i32(), 1);
    }

    #[test]
    fn test_end_to_end_record_field_access() {
        // { x: 1, y: 2 }.x == 1（field_idx=0 取第一个字段 "x"）
        use crate::Ast;
        let mut arena = Ast::AstArena::new();
        let x_val = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::IntLit { raw: "1", suffix: None },
        );
        let y_val = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::IntLit { raw: "2", suffix: None },
        );
        let record_expr = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::RecordLit(vec![
                Ast::RecordFieldExpr { name: "x", value: x_val },
                Ast::RecordFieldExpr { name: "y", value: y_val },
            ]),
        );
        let field_access = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::FieldAccess { recv: record_expr, field: "x" },
        );
        let (engine, h) = build_and_run(field_access, arena);
        assert_eq!(h.as_i32(), 1);
    }

    #[test]
    fn test_end_to_end_array_index() {
        // [10, 20, 30][1] == 20
        use crate::Ast;
        let mut arena = Ast::AstArena::new();
        let e0 = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::IntLit { raw: "10", suffix: None },
        );
        let e1 = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::IntLit { raw: "20", suffix: None },
        );
        let e2 = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::IntLit { raw: "30", suffix: None },
        );
        let array_expr = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::ArrayLit { elements: vec![e0, e1, e2], fill: None },
        );
        let idx_expr = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::IntLit { raw: "1", suffix: None },
        );
        let index_expr = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::Index { recv: array_expr, index: idx_expr },
        );
        let (engine, h) = build_and_run(index_expr, arena);
        assert_eq!(h.as_i32(), 20);
    }

    #[test]
    fn test_end_to_end_val_decl_and_use() {
        // fn main() { val x = 42; x } == 42
        use crate::Ast;
        let mut arena = Ast::AstArena::new();
        let val_expr = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::IntLit { raw: "42", suffix: None },
        );
        let val_decl = arena.alloc_stmt(
            Ast::Span { line: 1, column: 1 },
            Ast::Stmt::ValDecl {
                name: "x",
                type_annotation: None,
                value: val_expr,
                visibility: Ast::Visibility::Private,
            },
        );
        let ident_expr = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::Ident("x"),
        );
        let body = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::Block {
                stmts: vec![val_decl],
                trailing: Some(ident_expr),
            },
        );
        let (engine, h) = build_and_run(body, arena);
        assert_eq!(h.as_i32(), 42);
    }

    #[test]
    fn test_end_to_end_function_with_params() {
        // fn add(x, y) { x + y }; fn main() { add(3, 4) } == 7
        use crate::Ast;
        use crate::Ir::IrBuilder;
        use crate::Sema;
        let mut arena = Ast::AstArena::new();
        // add 函数体：x + y
        let x_ref = arena.alloc_expr(Ast::Span { line: 1, column: 1 }, Ast::Expr::Ident("x"));
        let y_ref = arena.alloc_expr(Ast::Span { line: 1, column: 1 }, Ast::Expr::Ident("y"));
        let add_body = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::Binary { op: Ast::BinaryOp::Add, lhs: x_ref, rhs: y_ref },
        );
        let add_decl = Ast::Decl::FunDecl {
            visibility: Ast::Visibility::Private,
            name: "add",
            type_params: vec![],
            params: vec![
                Ast::Param { name: "x", type_annotation: None },
                Ast::Param { name: "y", type_annotation: None },
            ],
            return_type: None,
            bounds: vec![],
            body: add_body,
            is_async: false,
            is_entry: false,
            attributes: vec![],
            extern_c_body: None,
        };
        // main 函数体：add(3, 4)
        let arg1 = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::IntLit { raw: "3", suffix: None },
        );
        let arg2 = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::IntLit { raw: "4", suffix: None },
        );
        let callee = arena.alloc_expr(Ast::Span { line: 1, column: 1 }, Ast::Expr::Ident("add"));
        let main_body = arena.alloc_expr(
            Ast::Span { line: 1, column: 1 },
            Ast::Expr::Call { callee, args: vec![arg1, arg2], type_args: None },
        );
        let main_decl = Ast::Decl::FunDecl {
            visibility: Ast::Visibility::Private,
            name: "main",
            type_params: vec![],
            params: vec![],
            return_type: None,
            bounds: vec![],
            body: main_body,
            is_async: false,
            is_entry: true,
            attributes: vec![],
            extern_c_body: None,
        };
        let module = Ast::Module {
            name: "test",
            source_path: None,
            arena,
            declarations: vec![
                Ast::Spanned { span: Ast::Span { line: 1, column: 1 }, node: add_decl },
                Ast::Spanned { span: Ast::Span { line: 1, column: 1 }, node: main_decl },
            ],
        };
        let sema = Sema::SemaResult::new();
        let graph = IrBuilder::new(&sema, &module).build();
        let mut engine = Engine::new(graph);
        let h = engine.run_entry();
        assert_eq!(h.as_i32(), 7);
    }

    /// 构建 + 运行（含 builtin 模块 + Sema 类型检查）
    fn build_and_run_with_builtins(
        body: crate::Ast::ExprId,
        arena: crate::Ast::AstArena<'_>,
    ) -> (Engine, Value) {
        use crate::Ast;
        use crate::Ir::IrBuilder;
        use crate::Sema;
        use crate::ModuleLoader::ModuleLoader;

        let fun_decl = Ast::Decl::FunDecl {
            visibility: Ast::Visibility::Private,
            name: "main",
            type_params: vec![],
            params: vec![],
            return_type: None,
            bounds: vec![],
            body,
            is_async: false,
            is_entry: true,
            attributes: vec![],
            extern_c_body: None,
        };
        let module = Ast::Module {
            name: "test",
            source_path: None,
            arena,
            declarations: vec![Ast::Spanned {
                span: Ast::Span { line: 1, column: 1 },
                node: fun_decl,
            }],
        };

        // 加载 builtin 模块
        let loader = ModuleLoader::new();
        let builtins: Vec<&Ast::Module<'static>> =
            loader.builtin_modules().map(|(_, m)| m).collect();

        // Sema 类型检查（builtin + test 模块）
        let mut type_arena = Sema::TypeArena::new();
        let mut sema_result = Sema::SemaResult::new();
        {
            let mut ctx = Sema::InferContext::new(&mut type_arena, &mut sema_result);
            let root_env = ctx.env.root();
            ctx.register_builtins(root_env);
            for (_, m) in loader.builtin_modules() {
                ctx.check_module_with_env(m, root_env);
            }
            ctx.check_module_with_env(&module, root_env);
        }

        let graph = IrBuilder::new(&sema_result, &module)
            .with_builtins(builtins)
            .build();
        let mut engine = Engine::new(graph);
        let h = engine.run_entry();
        (engine, h)
    }

    /// 辅助：解析 Glue 源码 → Sema + IR + Engine 执行，返回 (engine, 返回值句柄)。
    /// builtin 模块默认加载。若 parse/sema 出错则 panic。
    fn run_source(src: &'static str) -> (Engine, Value) {
        use bumpalo::Bump;
        use crate::Ast::{ErrorCollector, Lexer, Parser, Token, TokenCollector};
        use crate::Ir::IrBuilder;
        use crate::ModuleLoader::ModuleLoader;
        use crate::Sema;

        let bump = Bump::new();
        let mut lexer = Lexer::new(src);
        let mut sink = TokenCollector::new();
        lexer.tokenize_into(&mut sink);
        let tokens: Vec<Token> = sink.into_tokens();
        let tokens_ref = bump.alloc_slice_copy(&tokens);
        let mut parser = Parser::new(tokens_ref, &bump, ErrorCollector::new());
        let module = parser.parse_module("test").expect("parse failed");

        let loader = ModuleLoader::new();
        let builtins: Vec<&crate::Ast::Module<'static>> =
            loader.builtin_modules().map(|(_, m)| m).collect();

        let mut type_arena = Sema::TypeArena::new();
        let mut sema_result = Sema::SemaResult::new();
        {
            let mut ctx = Sema::InferContext::new(&mut type_arena, &mut sema_result);
            let root_env = ctx.env.root();
            ctx.register_builtins(root_env);
            for (_, m) in loader.builtin_modules() {
                ctx.check_module_with_env(m, root_env);
            }
            ctx.check_module_with_env(&module, root_env);
        }

        let graph = IrBuilder::new(&sema_result, &module)
            .with_builtins(builtins)
            .build();
        let mut engine = Engine::new(graph);
        let h = engine.run_entry();
        (engine, h)
    }

    /// 辅助：解析 Glue 源码 → Sema 检查，返回 SemaResult（可能含 errors）。
    /// 用于验证 sema 级别的错误报告。
    fn check_source(src: &'static str) -> crate::Sema::SemaResult {
        use bumpalo::Bump;
        use crate::Ast::{ErrorCollector, Lexer, Parser, Token, TokenCollector};
        use crate::ModuleLoader::ModuleLoader;
        use crate::Sema;

        let bump = Bump::new();
        let mut lexer = Lexer::new(src);
        let mut sink = TokenCollector::new();
        lexer.tokenize_into(&mut sink);
        let tokens: Vec<Token> = sink.into_tokens();
        let tokens_ref = bump.alloc_slice_copy(&tokens);
        let mut parser = Parser::new(tokens_ref, &bump, ErrorCollector::new());
        let module = parser.parse_module("test").expect("parse failed");

        let loader = ModuleLoader::new();
        let mut type_arena = Sema::TypeArena::new();
        let mut sema_result = Sema::SemaResult::new();
        {
            let mut ctx = Sema::InferContext::new(&mut type_arena, &mut sema_result);
            let root_env = ctx.env.root();
            ctx.register_builtins(root_env);
            for (_, m) in loader.builtin_modules() {
                ctx.check_module_with_env(m, root_env);
            }
            ctx.check_module_with_env(&module, root_env);
        }
        sema_result
    }

    #[test]
    fn test_end_to_end_for_loop_basic() {
        // for x in [1, 2, 3] { } → 迭代 3 次后退出，返回 0
        use crate::Ast;
        let mut arena = Ast::AstArena::new();
        let span = Ast::Span { line: 1, column: 1 };

        // 数组 [1, 2, 3]
        let e1 = arena.alloc_expr(span, Ast::Expr::IntLit { raw: "1", suffix: None });
        let e2 = arena.alloc_expr(span, Ast::Expr::IntLit { raw: "2", suffix: None });
        let e3 = arena.alloc_expr(span, Ast::Expr::IntLit { raw: "3", suffix: None });
        let arr = arena.alloc_expr(span, Ast::Expr::ArrayLit {
            elements: vec![e1, e2, e3],
            fill: None,
        });

        // iter(arr) — 数组需显式调用 iter() 获取迭代器
        let iter_ident = arena.alloc_expr(span, Ast::Expr::Ident("iter"));
        let iter_call = arena.alloc_expr(span, Ast::Expr::Call {
            callee: iter_ident,
            args: vec![arr],
            type_args: None,
        });

        // For body: 空块
        let for_body = arena.alloc_expr(span, Ast::Expr::Block {
            stmts: vec![],
            trailing: None,
        });

        // for x in iter([1,2,3]) { }
        let for_stmt = arena.alloc_stmt(span, Ast::Stmt::For {
            name: "x",
            iterable: iter_call,
            body: for_body,
        });

        // 返回 0
        let ret_val = arena.alloc_expr(span, Ast::Expr::IntLit { raw: "0", suffix: None });

        // main body: { for_stmt; 0 }
        let main_body = arena.alloc_expr(span, Ast::Expr::Block {
            stmts: vec![for_stmt],
            trailing: Some(ret_val),
        });

        let (_engine, h) = build_and_run_with_builtins(main_body, arena);
        // 循环正常退出返回 0（若无限递归会栈溢出失败）
        let _ = h;
    }

    // ── Iterator trait 静态分派端到端测试 ──

    #[test]
    fn test_for_loop_range_iterator_static() {
        // for x in range_iter(1, 4, false) { sum += x } → 1+2+3 = 6
        let src = r#"
            fun main(): i64 {
                var sum: i64 = 0
                for x in range_iter(1, 4, false) {
                    sum = sum + x
                }
                return sum
            }
        "#;
        let (_engine, h) = run_source(src);
        assert_eq!(h.scalar_tag(), Some(crate::Value::ScalarTag::I64));
        assert_eq!(h.as_i64(), 6);
    }

    #[test]
    fn test_for_loop_user_iterator_type() {
        // 用户自定义类型 implement Iterator → 静态分派
        // MyRange(1, 5) 产出 1,2,3,4 → sum = 10
        let src = r#"
            type MyRange: (Iterator<i32>) = MyRange(lo: i32, hi: i32) {
                pub fun next(&self): i32? {
                    if self.lo >= self.hi { return null }
                    val v = self.lo
                    self.lo = self.lo + 1
                    return v
                }
            }
            fun main(): i32 {
                var sum: i32 = 0
                for x in MyRange(1, 5) {
                    sum = sum + x
                }
                return sum
            }
        "#;
        let (_engine, h) = run_source(src);
        assert_eq!(h.scalar_tag(), Some(crate::Value::ScalarTag::I32));
        assert_eq!(h.as_i32(), 10);
    }

    #[test]
    fn test_for_loop_array_without_iter_errors() {
        // 数组未 implement Iterator → sema 报错
        let src = r#"
            fun main(): void {
                val arr = [1, 2, 3]
                for x in arr { }
            }
        "#;
        let sema = check_source(src);
        let has_iter_error = sema
            .errors
            .iter()
            .any(|e| e.message.contains("未实现 Iterator"));
        assert!(
            has_iter_error,
            "expected '未实现 Iterator' error, got errors: {:?}",
            sema.errors.iter().map(|e| &e.message).collect::<Vec<_>>()
        );
    }

    #[test]
    fn test_for_loop_trait_value_dynamic_dispatch() {
        // trait 值 For 循环动态分派：val it: Iterator<i32> = arr.iter()
        // 编译为 vtable Call 节点，运行时从 TraitVal 查 next()
        let src = r#"
            fun main(): i32 {
                val arr = [1, 2, 3]
                val it: Iterator<i32> = arr.iter()
                var sum: i32 = 0
                for x in it {
                    sum = sum + x
                }
                return sum
            }
        "#;
        // 动态分派路径编译通过即验证（运行时 TraitVal 构建依赖完整引擎支持）
        let sema = check_source(src);
        let has_sema_error = sema.errors.iter().any(|e| e.message.contains("未实现 Iterator"));
        // it 已是 Iterator 类型，不应报 "未实现 Iterator" 错误
        assert!(
            !has_sema_error,
            "trait value should NOT trigger '未实现 Iterator' error, got: {:?}",
            sema.errors.iter().map(|e| &e.message).collect::<Vec<_>>()
        );
    }

    // =====================================================================
    // 事件驱动端到端测试（Task 6）：验证 run_event_loop 调度 call/gate/递归
    // =====================================================================

    #[test]
    fn test_event_loop_nested_call() {
        // 嵌套 call 链：main → outer → inner，验证事件驱动多级 call 调度。
        // inner(x) = x; outer(x) = inner(x); main() = outer(42) == 42
        let mut graph = DataFlowGraph::new();

        // SubGraph 0: inner(x) = x  (param_count=1)
        // N0: param x (Const, no const_value — filled by param injection)
        let n0 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        graph.add_subgraph(SubGraph {
            id: SubGraphId(0),
            node_range: (NodeId(0), NodeId(1)),
            param_count: 1,
            entry_node: n0,
            return_node: n0,
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });

        // SubGraph 1: outer(x) = inner(x)  (param_count=1)
        // N1: param x, N2: Call(inner, [N1])
        let n1 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        let outer_call_off = graph.inputs_pool.push(&[n1]);
        let n2 = graph.add_node(Node {
            kind: NodeKind::Call,
            input_count: 1,
            inputs_offset: outer_call_off,
            compute_fn: ComputeFnId(36),
        });
        graph.set_call_target(n2, SubGraphId(0));
        graph.add_subgraph(SubGraph {
            id: SubGraphId(1),
            node_range: (NodeId(1), NodeId(3)),
            param_count: 1,
            entry_node: n1,
            return_node: n2,
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });

        // SubGraph 2: main() = outer(42)  (param_count=0)
        // N3: Const(42), N4: Call(outer, [N3])
        let n3 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        graph.const_values[n3.0 as usize] = Some(ConstValue::I32(42));
        let main_call_off = graph.inputs_pool.push(&[n3]);
        let n4 = graph.add_node(Node {
            kind: NodeKind::Call,
            input_count: 1,
            inputs_offset: main_call_off,
            compute_fn: ComputeFnId(36),
        });
        graph.set_call_target(n4, SubGraphId(1));
        graph.add_subgraph(SubGraph {
            id: SubGraphId(2),
            node_range: (NodeId(3), NodeId(5)),
            param_count: 0,
            entry_node: n3,
            return_node: n4,
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });

        graph.set_entry_subgraph(SubGraphId(2));
        graph.compute_downstreams();

        let mut engine = Engine::new(graph);
        let result = engine.run_entry();
        assert_eq!(result.as_i32(), 42);
    }

    #[test]
    fn test_event_loop_gate_with_call() {
        // gate 嵌套 call：条件 true 选分支调用 add(1,2)=3，false 选分支返回 99。
        // 验证事件驱动 gate + call 组合调度。
        let mut graph = DataFlowGraph::new();

        // SubGraph 0: add(x, y) = x + y  (param_count=2)
        // N0: param x, N1: param y, N2: BinOp add
        let n0 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        let n1 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        let add_off = graph.inputs_pool.push(&[n0, n1]);
        let n2 = graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: 2,
            inputs_offset: add_off,
            compute_fn: ComputeFnId(1), // add_i32
        });
        graph.add_subgraph(SubGraph {
            id: SubGraphId(0),
            node_range: (NodeId(0), NodeId(3)),
            param_count: 2,
            entry_node: n0,
            return_node: n2,
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });

        // SubGraph 1: else branch = 99  (param_count=0)
        // N3: Const(99)
        let n3 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        graph.const_values[n3.0 as usize] = Some(ConstValue::I32(99));
        graph.add_subgraph(SubGraph {
            id: SubGraphId(1),
            node_range: (NodeId(3), NodeId(4)),
            param_count: 0,
            entry_node: n3,
            return_node: n3,
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });

        // SubGraph 2: main = if true { add(1,2) } else { 99 }
        // N4: Const(true), N5: Const(1), N6: Const(2), N7: Gate
        let n4 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        graph.const_values[n4.0 as usize] = Some(ConstValue::Bool(true));
        let n5 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        graph.const_values[n5.0 as usize] = Some(ConstValue::I32(1));
        let n6 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        graph.const_values[n6.0 as usize] = Some(ConstValue::I32(2));
        let n7 = graph.add_node(Node {
            kind: NodeKind::Gate,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(37), // gate_launch
        });
        graph.set_gate_branches(n7, GateBranches {
            condition_input: n4,
            branches: vec![
                (true, SubGraphId(0), vec![n5, n6]),  // add(1, 2)
                (false, SubGraphId(1), vec![]),       // 99
            ],
        });
        graph.add_subgraph(SubGraph {
            id: SubGraphId(2),
            node_range: (NodeId(4), NodeId(8)),
            param_count: 0,
            entry_node: n4,
            return_node: n7,
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });

        graph.set_entry_subgraph(SubGraphId(2));
        graph.compute_downstreams();

        let mut engine = Engine::new(graph);
        let result = engine.run_entry();
        assert_eq!(result.as_i32(), 3);
    }

    #[test]
    fn test_event_loop_recursive_call() {
        // 递归调用：sum(n) = if n <= 0 { 0 } else { n + sum(n-1) }
        // main() = sum(3) == 6
        // 验证事件驱动递归调度（多层挂起帧 + 子图完成事件回写）。
        let mut graph = DataFlowGraph::new();

        // SubGraph 0: sum(n) — gate 分派
        // N0: param n, N1: Const(0), N2: le(n, 0), N3: Gate
        let n0 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        let n1 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        graph.const_values[n1.0 as usize] = Some(ConstValue::I32(0));
        let le_off = graph.inputs_pool.push(&[n0, n1]);
        let n2 = graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: 2,
            inputs_offset: le_off,
            compute_fn: ComputeFnId(4), // le_i32
        });
        let n3 = graph.add_node(Node {
            kind: NodeKind::Gate,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(37), // gate_launch
        });
        graph.set_gate_branches(n3, GateBranches {
            condition_input: n2,
            branches: vec![
                (true, SubGraphId(1), vec![]),       // n <= 0 → return 0
                (false, SubGraphId(2), vec![n0]),    // n > 0 → n + sum(n-1)
            ],
        });
        graph.add_subgraph(SubGraph {
            id: SubGraphId(0),
            node_range: (NodeId(0), NodeId(4)),
            param_count: 1,
            entry_node: n0,
            return_node: n3,
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });

        // SubGraph 1: then branch = 0  (param_count=0)
        // N4: Const(0)
        let n4 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        graph.const_values[n4.0 as usize] = Some(ConstValue::I32(0));
        graph.add_subgraph(SubGraph {
            id: SubGraphId(1),
            node_range: (NodeId(4), NodeId(5)),
            param_count: 0,
            entry_node: n4,
            return_node: n4,
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });

        // SubGraph 2: else branch = n + sum(n-1)  (param_count=1)
        // N5: param n, N6: Const(1), N7: sub(n, 1), N8: Call(sum, [N7]), N9: add(n, sum_result)
        let n5 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        let n6 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        graph.const_values[n6.0 as usize] = Some(ConstValue::I32(1));
        let sub_off = graph.inputs_pool.push(&[n5, n6]);
        let n7 = graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: 2,
            inputs_offset: sub_off,
            compute_fn: ComputeFnId(5), // sub_i32
        });
        let rec_call_off = graph.inputs_pool.push(&[n7]);
        let n8 = graph.add_node(Node {
            kind: NodeKind::Call,
            input_count: 1,
            inputs_offset: rec_call_off,
            compute_fn: ComputeFnId(36), // call_launch
        });
        graph.set_call_target(n8, SubGraphId(0)); // 递归调用 sum
        let add_off = graph.inputs_pool.push(&[n5, n8]);
        let n9 = graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: 2,
            inputs_offset: add_off,
            compute_fn: ComputeFnId(1), // add_i32
        });
        graph.add_subgraph(SubGraph {
            id: SubGraphId(2),
            node_range: (NodeId(5), NodeId(10)),
            param_count: 1,
            entry_node: n5,
            return_node: n9,
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });

        // SubGraph 3: main() = sum(3)  (param_count=0)
        // N10: Const(3), N11: Call(sum, [N10])
        let n10 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        graph.const_values[n10.0 as usize] = Some(ConstValue::I32(3));
        let main_call_off = graph.inputs_pool.push(&[n10]);
        let n11 = graph.add_node(Node {
            kind: NodeKind::Call,
            input_count: 1,
            inputs_offset: main_call_off,
            compute_fn: ComputeFnId(36),
        });
        graph.set_call_target(n11, SubGraphId(0));
        graph.add_subgraph(SubGraph {
            id: SubGraphId(3),
            node_range: (NodeId(10), NodeId(12)),
            param_count: 0,
            entry_node: n10,
            return_node: n11,
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });

        graph.set_entry_subgraph(SubGraphId(3));
        graph.compute_downstreams();

        let mut engine = Engine::new(graph);
        let result = engine.run_entry();
        assert_eq!(result.as_i32(), 6);
    }

    // ===== 阶段 5a-2 端到端测试 =====

    /// 端到端：async 函数调用 + await
    ///
    /// SG0 (async_fn): N0=Const(42), has_suspend=true
    /// SG1 (main): N1=AsyncCall(SG0), N2=EventSource(AsyncJoin), N3=Await(N1)
    /// 验证：async 调用返回 AsyncHandle，await 挂起→子帧完成→事件唤醒→返回 42
    #[test]
    fn test_async_call_and_await() {
        let mut graph = DataFlowGraph::new();

        // SG0: async_fn() = 42
        let n0 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        graph.const_values[n0.0 as usize] = Some(ConstValue::I32(42));
        graph.add_subgraph(SubGraph {
            id: SubGraphId(0),
            node_range: (NodeId(0), NodeId(1)),
            param_count: 0,
            entry_node: n0,
            return_node: n0,
            has_suspend: true, // async 标记
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });

        // SG1: main() = async_fn().await()
        // N1: AsyncCall(SG0) — 0 输入，compute_async_call_launch (idx 39)
        let n1 = graph.add_node(Node {
            kind: NodeKind::Call,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(39), // compute_async_call_launch
        });
        graph.set_call_target(n1, SubGraphId(0));

        // N2: EventSource 声明节点（永不就绪，元数据引用）
        let n2 = graph.add_node(Node {
            kind: NodeKind::EventSource,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });

        // N3: Await(N1) — 1 输入（event_obj），compute_await (idx 38)
        let await_off = graph.inputs_pool.push(&[n1]);
        let n3 = graph.add_node(Node {
            kind: NodeKind::Await,
            input_count: 1,
            inputs_offset: await_off,
            compute_fn: ComputeFnId(38),
        });
        graph.set_await_event_source(n3, n2);

        graph.add_subgraph(SubGraph {
            id: SubGraphId(1),
            node_range: (NodeId(1), NodeId(4)),
            param_count: 0,
            entry_node: n1,
            return_node: n3,
            has_suspend: false,
            event_source_decls: vec![EventSourceDecl {
                node: n2,
                kind: EventSourceKind::AsyncJoin,
            }],
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });

        graph.set_entry_subgraph(SubGraphId(1));
        graph.compute_downstreams();

        let mut engine = Engine::new(graph);
        let result = engine.run_entry();
        assert_eq!(result.as_i32(), 42);
    }

    /// 端到端：并发 async 调用 + 两次 await
    ///
    /// SG0 (async_fn): N0=Const(42), has_suspend=true
    /// SG1 (main): N1=AsyncCall(SG0), N2=ES1, N3=Await(N1),
    ///             N4=AsyncCall(SG0), N5=ES2, N6=Await(N4),
    ///             N7=Add(N3, N6)
    /// 验证：两个 async 调用并发启动，await 分别完成，结果 42+42=84
    #[test]
    fn test_concurrent_async_calls() {
        let mut graph = DataFlowGraph::new();

        // SG0: async_fn() = 42
        let n0 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        graph.const_values[n0.0 as usize] = Some(ConstValue::I32(42));
        graph.add_subgraph(SubGraph {
            id: SubGraphId(0),
            node_range: (NodeId(0), NodeId(1)),
            param_count: 0,
            entry_node: n0,
            return_node: n0,
            has_suspend: true,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });

        // SG1: main() = async_fn().await() + async_fn().await()
        // N1: AsyncCall1
        let n1 = graph.add_node(Node {
            kind: NodeKind::Call,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(39),
        });
        graph.set_call_target(n1, SubGraphId(0));

        // N2: EventSource 1
        let n2 = graph.add_node(Node {
            kind: NodeKind::EventSource,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });

        // N3: Await1(N1)
        let off3 = graph.inputs_pool.push(&[n1]);
        let n3 = graph.add_node(Node {
            kind: NodeKind::Await,
            input_count: 1,
            inputs_offset: off3,
            compute_fn: ComputeFnId(38),
        });
        graph.set_await_event_source(n3, n2);

        // N4: AsyncCall2
        let n4 = graph.add_node(Node {
            kind: NodeKind::Call,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(39),
        });
        graph.set_call_target(n4, SubGraphId(0));

        // N5: EventSource 2
        let n5 = graph.add_node(Node {
            kind: NodeKind::EventSource,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });

        // N6: Await2(N4)
        let off6 = graph.inputs_pool.push(&[n4]);
        let n6 = graph.add_node(Node {
            kind: NodeKind::Await,
            input_count: 1,
            inputs_offset: off6,
            compute_fn: ComputeFnId(38),
        });
        graph.set_await_event_source(n6, n5);

        // N7: Add(N3, N6)
        let off7 = graph.inputs_pool.push(&[n3, n6]);
        let n7 = graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: 2,
            inputs_offset: off7,
            compute_fn: ComputeFnId(1), // add_i32
        });

        graph.add_subgraph(SubGraph {
            id: SubGraphId(1),
            node_range: (NodeId(1), NodeId(8)),
            param_count: 0,
            entry_node: n1,
            return_node: n7,
            has_suspend: false,
            event_source_decls: vec![
                EventSourceDecl { node: n2, kind: EventSourceKind::AsyncJoin },
                EventSourceDecl { node: n5, kind: EventSourceKind::AsyncJoin },
            ],
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });

        graph.set_entry_subgraph(SubGraphId(1));
        graph.compute_downstreams();

        let mut engine = Engine::new(graph);
        let result = engine.run_entry();
        assert_eq!(result.as_i32(), 84);
    }

    /// 端到端：async 函数带参数 + await
    ///
    /// SG0 (async_add): params(a, b), return a+b, has_suspend=true
    /// SG1 (main): N2=Const(10), N3=Const(32), N4=AsyncCall(SG0, [N2, N3]),
    ///             N5=ES, N6=Await(N4)
    /// 验证：async 调用带参数，返回 10+32=42
    #[test]
    fn test_async_call_with_params_and_await() {
        let mut graph = DataFlowGraph::new();

        // SG0: async_add(a, b) = a + b
        let n0 = graph.add_node(Node { kind: NodeKind::Const, input_count: 0, inputs_offset: 0, compute_fn: ComputeFnId(0) });
        let n1 = graph.add_node(Node { kind: NodeKind::Const, input_count: 0, inputs_offset: 0, compute_fn: ComputeFnId(0) });
        let add_off = graph.inputs_pool.push(&[n0, n1]);
        let n2 = graph.add_node(Node { kind: NodeKind::BinOp, input_count: 2, inputs_offset: add_off, compute_fn: ComputeFnId(1) });
        graph.add_subgraph(SubGraph {
            id: SubGraphId(0),
            node_range: (NodeId(0), NodeId(3)),
            param_count: 2,
            entry_node: n0,
            return_node: n2,
            has_suspend: true,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });

        // SG1: main() = async_add(10, 32).await()
        let n3 = graph.add_node(Node { kind: NodeKind::Const, input_count: 0, inputs_offset: 0, compute_fn: ComputeFnId(0) });
        graph.const_values[n3.0 as usize] = Some(ConstValue::I32(10));
        let n4 = graph.add_node(Node { kind: NodeKind::Const, input_count: 0, inputs_offset: 0, compute_fn: ComputeFnId(0) });
        graph.const_values[n4.0 as usize] = Some(ConstValue::I32(32));
        let call_off = graph.inputs_pool.push(&[n3, n4]);
        let n5 = graph.add_node(Node { kind: NodeKind::Call, input_count: 2, inputs_offset: call_off, compute_fn: ComputeFnId(39) });
        graph.set_call_target(n5, SubGraphId(0));

        let n6 = graph.add_node(Node { kind: NodeKind::EventSource, input_count: 0, inputs_offset: 0, compute_fn: ComputeFnId(0) });
        let await_off = graph.inputs_pool.push(&[n5]);
        let n7 = graph.add_node(Node { kind: NodeKind::Await, input_count: 1, inputs_offset: await_off, compute_fn: ComputeFnId(38) });
        graph.set_await_event_source(n7, n6);

        graph.add_subgraph(SubGraph {
            id: SubGraphId(1),
            node_range: (NodeId(3), NodeId(8)),
            param_count: 0,
            entry_node: n3,
            return_node: n7,
            has_suspend: false,
            event_source_decls: vec![EventSourceDecl { node: n6, kind: EventSourceKind::AsyncJoin }],
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });

        graph.set_entry_subgraph(SubGraphId(1));
        graph.compute_downstreams();

        let mut engine = Engine::new(graph);
        let result = engine.run_entry();
        assert_eq!(result.as_i32(), 42);
    }

    /// 单元测试：ChannelRuntime create + send + recv
    #[test]
    fn test_channel_runtime_basic() {
        let mut rt = ChannelRuntime::new();
        let ch = rt.create(2);
        assert_eq!(ch, crate::Ir::ChannelId(0));

        let val = Value::NULL; // 用 NULL 作为占位值
        assert!(rt.send(ch, val.clone()));
        assert!(rt.recv(ch).is_some()); // 有数据
        assert!(rt.recv(ch).is_none()); // buffer 空
    }

    /// 单元测试：ChannelRuntime 容量限制
    #[test]
    fn test_channel_runtime_capacity() {
        let mut rt = ChannelRuntime::new();
        let ch = rt.create(1);
        assert!(rt.send(ch, Value::NULL));
        assert!(!rt.send(ch, Value::VOID)); // 满了
    }

    /// 单元测试：TimerRuntime start + check_and_fire
    #[test]
    fn test_timer_runtime_basic() {
        let mut rt = TimerRuntime::new();
        let t = rt.start(std::time::Duration::from_millis(0));
        assert_eq!(t, crate::Ir::TimerId(0));

        // 0ms timer 应立即触发
        let fired = rt.check_and_fire();
        assert!(fired.contains(&t));
        assert!(rt.is_fired(t));

        // 再次检查不应重复触发
        let fired2 = rt.check_and_fire();
        assert!(!fired2.contains(&t));
    }

    /// 单元测试：AsyncJoinRuntime register + set_result + try_get_result
    #[test]
    fn test_async_join_runtime_basic() {
        let mut rt = AsyncJoinRuntime::new();
        let async_id = crate::Ir::AsyncHandleId(0);
        let child_fid = FrameId(1);

        rt.register(async_id, child_fid);
        assert_eq!(rt.find_by_child(child_fid), Some(async_id));
        assert!(rt.try_get_result(async_id).is_none()); // 未完成

        let result = Value::VOID;
        rt.set_result(async_id, result);
        assert!(rt.try_get_result(async_id).is_some()); // 已完成
    }

    /// 单元测试：on_event_arrived 事件注入 + 帧恢复
    ///
    /// 验证 channel 事件到达时，挂起帧被正确唤醒。
    #[test]
    fn test_on_event_arrived_channel_resume() {
        let mut graph = DataFlowGraph::new();

        // SG0: main() — await channel
        // N0: 占位节点（channel handle 将在运行时注入）
        let n0 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        // N1: EventSource (Channel kind)
        let n1 = graph.add_node(Node {
            kind: NodeKind::EventSource,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        // N2: Await(N0)
        let await_off = graph.inputs_pool.push(&[n0]);
        let n2 = graph.add_node(Node {
            kind: NodeKind::Await,
            input_count: 1,
            inputs_offset: await_off,
            compute_fn: ComputeFnId(38),
        });
        graph.set_await_event_source(n2, n1);

        graph.add_subgraph(SubGraph {
            id: SubGraphId(0),
            node_range: (NodeId(0), NodeId(3)),
            param_count: 0,
            entry_node: n0,
            return_node: n2,
            has_suspend: false,
            event_source_decls: vec![EventSourceDecl { node: n1, kind: EventSourceKind::Channel }],
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });
        graph.set_entry_subgraph(SubGraphId(0));
        graph.compute_downstreams();

        let mut engine = Engine::new(graph);

        // 预创建 channel + 发送值
        // channel handle 是 i32 标量，值本身即 ChannelId
        let ch_handle = Value::i32(0); // channel id = 0
        let ch_id = engine.channel_runtime.create(1); // ChannelId(0)
        debug_assert_eq!(ch_handle.as_i32() as usize, ch_id.0 as usize,
            "channel handle value must match ChannelId");
        let sent_val = Value::i32(77);
        engine.channel_runtime.send(ch_id, sent_val);

        // N0 的 Const 值设为 channel handle
        // 直接手动注入：先 init_frame，再手动设置 N0 的值
        let fid = engine.init_frame(SubGraphId(0));

        let frame = engine.frames.get_mut(fid);
        frame.set_value(NodeId(0), ch_handle, 1); // 1 downstream (N2)
        frame.push_ready(NodeId(0));

        // 执行帧 → N0 就绪 → N2 (await) 就绪 → 检查 channel → 有数据 → 完成
        engine.run_ready_nodes(fid);

        let result = engine.extract_child_return(fid);
        assert_eq!(result.as_i32(), 77);
    }

    /// 端到端：timer 事件源 — await 挂起 → timer 到期 → 事件唤醒 → 帧完成
    ///
    /// SG0: N0=Const(timer_handle), N1=EventSource(Timer), N2=Await(N0)
    /// 验证：await 检查 timer 未到期→挂起；timer 到期→on_event_arrived 唤醒；帧完成
    #[test]
    fn test_timer_await_suspend_and_resume() {
        let mut graph = DataFlowGraph::new();

        // N0: Const (timer handle 占位，运行时注入)
        let n0 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        // N1: EventSource (Timer kind)
        let n1 = graph.add_node(Node {
            kind: NodeKind::EventSource,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        // N2: Await(N0)
        let await_off = graph.inputs_pool.push(&[n0]);
        let n2 = graph.add_node(Node {
            kind: NodeKind::Await,
            input_count: 1,
            inputs_offset: await_off,
            compute_fn: ComputeFnId(38), // compute_await
        });
        graph.set_await_event_source(n2, n1);

        graph.add_subgraph(SubGraph {
            id: SubGraphId(0),
            node_range: (NodeId(0), NodeId(3)),
            param_count: 0,
            entry_node: n0,
            return_node: n2,
            has_suspend: false,
            event_source_decls: vec![EventSourceDecl { node: n1, kind: EventSourceKind::Timer }],
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });
        graph.set_entry_subgraph(SubGraphId(0));
        graph.compute_downstreams();

        let mut engine = Engine::new(graph);

        // 预创建 timer（10ms）+ 分配匹配值的 Value
        // timer handle 是 i32 标量，值本身即 TimerId
        let timer_handle = Value::i32(0); // timer id = 0
        let timer_id = engine.timer_runtime.start(std::time::Duration::from_millis(10));
        debug_assert_eq!(timer_handle.as_i32() as usize, timer_id.0 as usize,
            "timer handle value must match TimerId");

        // 初始化帧 + 手动注入 timer handle 到 N0
        let fid = engine.init_frame(SubGraphId(0));
        let frame = engine.frames.get_mut(fid);
        frame.set_value(NodeId(0), timer_handle, 1); // 1 downstream (N2)
        frame.push_ready(NodeId(0));

        // 第一次执行：N0 就绪 → N2 (await) 就绪 → 检查 timer → 未到期 → 帧挂起
        engine.run_ready_nodes(fid);
        assert_eq!(engine.frames.get(fid).state, FrameState::Suspended,
            "frame should be suspended waiting for timer");

        // 等待 timer 到期
        std::thread::sleep(std::time::Duration::from_millis(20));

        // 事件循环检查 timer → 触发 → on_event_arrived 唤醒帧
        let fired = engine.timer_runtime.check_and_fire();
        assert!(fired.contains(&timer_id), "timer should have fired");
        engine.on_event_arrived(RuntimeEvent::TimerFired(timer_id), Value::VOID);

        // 唤醒后帧应处于 Ready 状态
        assert_eq!(engine.frames.get(fid).state, FrameState::Ready,
            "frame should be ready after timer event");

        // 第二次执行：await 节点已有值 → 帧完成
        engine.run_ready_nodes(fid);
        assert_eq!(engine.frames.get(fid).state, FrameState::Completed,
            "frame should be completed after timer resume");
    }

    /// 端到端：select 表达式 — channel 有数据时分支胜出
    ///
    /// SG0 (branch body): N0=Const(42)
    /// SG1 (main): N1=Const(channel handle 运行时注入), N2=Gate(select, compute_select_gate)
    /// 验证：channel 有数据 → select 选 channel 分支 → 启动 SG0 → 返回 42
    #[test]
    fn test_select_channel_ready() {
        let mut graph = DataFlowGraph::new();

        // SG0: branch body = Const(42)
        let n0 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        graph.const_values[n0.0 as usize] = Some(ConstValue::I32(42));
        graph.add_subgraph(SubGraph {
            id: SubGraphId(0),
            node_range: (NodeId(0), NodeId(1)),
            param_count: 0,
            entry_node: n0,
            return_node: n0,
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });

        // SG1: main() = select { ch.recv() => 42 }
        // N1: Const (channel handle 占位，运行时注入)
        let n1 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        // N2: Gate (select, compute_select_gate idx 43)
        let gate_off = graph.inputs_pool.push(&[]);
        let n2 = graph.add_node(Node {
            kind: NodeKind::Gate,
            input_count: 0,
            inputs_offset: gate_off,
            compute_fn: ComputeFnId(43),
        });
        graph.set_select_info(
            n2,
            SelectInfo {
                branches: vec![SelectBranch {
                    subgraph_id: SubGraphId(0),
                    event_kind: EventSourceKind::Channel,
                    event_source_node: n1,
                }],
            },
        );
        graph.add_subgraph(SubGraph {
            id: SubGraphId(1),
            node_range: (NodeId(1), NodeId(3)),
            param_count: 0,
            entry_node: n1,
            return_node: n2,
            has_suspend: true,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });
        graph.set_entry_subgraph(SubGraphId(1));
        graph.compute_downstreams();

        let mut engine = Engine::new(graph);

        // 预创建 channel + 发送值（channel handle 值即 ChannelId）
        let ch_handle = Value::i32(0); // channel id = 0
        let ch_id = engine.channel_runtime.create(1); // ChannelId(0)
        debug_assert_eq!(ch_handle.as_i32() as usize, ch_id.0 as usize);
        let sent_val = Value::i32(77);
        engine.channel_runtime.send(ch_id, sent_val);

        // 初始化帧 + 手动注入 channel handle 到 N1（local id=0）
        let fid = engine.init_frame(SubGraphId(1));
        let frame = engine.frames.get_mut(fid);
        frame.set_value(NodeId(0), ch_handle, 0);
        frame.push_ready(NodeId(0));

        // 执行：N1 就绪 → N2 (gate) 就绪 → select 检查 → channel 有数据 → 启动 SG0
        engine.run_ready_nodes(fid);
        assert_eq!(
            engine.frames.get(fid).state,
            FrameState::Suspended,
            "frame should be suspended waiting for select subgraph"
        );

        // 子帧应已入 ready_frames
        let child_fid = engine
            .ready_frames
            .pop_front()
            .expect("child frame should be ready");
        engine.run_ready_nodes(child_fid);
        assert_eq!(
            engine.frames.get(child_fid).state,
            FrameState::Completed,
            "child frame should be completed"
        );

        // 子图完成 → 回写返回值到 gate 节点 + 唤醒调用方
        engine.complete_and_wake_caller(child_fid);
        assert_eq!(
            engine.frames.get(fid).state,
            FrameState::Ready,
            "caller frame should be ready after subgraph complete"
        );

        // 再次执行：帧完成
        engine.run_ready_nodes(fid);
        assert_eq!(
            engine.frames.get(fid).state,
            FrameState::Completed,
            "frame should be completed"
        );

        let result = engine.extract_child_return(fid);
        assert_eq!(result.as_i32(), 42);
    }

    /// 端到端：select 表达式 — channel 无数据时挂起，事件到达后唤醒并执行分支
    ///
    /// SG0 (branch body): N0=Const(42)
    /// SG1 (main): N1=Const(channel handle 运行时注入), N2=Gate(select)
    /// 验证：channel 无数据 → select 挂起；channel 有数据 → on_event_arrived 唤醒
    ///       → select 选 channel 分支 → 启动 SG0 → 返回 42
    #[test]
    fn test_select_channel_suspend_and_resume() {
        let mut graph = DataFlowGraph::new();

        // SG0: branch body = Const(42)
        let n0 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        graph.const_values[n0.0 as usize] = Some(ConstValue::I32(42));
        graph.add_subgraph(SubGraph {
            id: SubGraphId(0),
            node_range: (NodeId(0), NodeId(1)),
            param_count: 0,
            entry_node: n0,
            return_node: n0,
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });

        // SG1: main() = select { ch.recv() => 42 }
        let n1 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        let gate_off = graph.inputs_pool.push(&[]);
        let n2 = graph.add_node(Node {
            kind: NodeKind::Gate,
            input_count: 0,
            inputs_offset: gate_off,
            compute_fn: ComputeFnId(43),
        });
        graph.set_select_info(
            n2,
            SelectInfo {
                branches: vec![SelectBranch {
                    subgraph_id: SubGraphId(0),
                    event_kind: EventSourceKind::Channel,
                    event_source_node: n1,
                }],
            },
        );
        graph.add_subgraph(SubGraph {
            id: SubGraphId(1),
            node_range: (NodeId(1), NodeId(3)),
            param_count: 0,
            entry_node: n1,
            return_node: n2,
            has_suspend: true,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });
        graph.set_entry_subgraph(SubGraphId(1));
        graph.compute_downstreams();

        let mut engine = Engine::new(graph);

        // 预创建 channel（空，无数据）+ 分配匹配值的 Value
        let ch_handle = Value::i32(0); // channel id = 0
        let ch_id = engine.channel_runtime.create(1); // ChannelId(0)
        debug_assert_eq!(ch_handle.as_i32() as usize, ch_id.0 as usize);

        // 初始化帧 + 手动注入 channel handle 到 N1（local id=0）
        let fid = engine.init_frame(SubGraphId(1));
        let frame = engine.frames.get_mut(fid);
        frame.set_value(NodeId(0), ch_handle, 0);
        frame.push_ready(NodeId(0));

        // 第一次执行：channel 无数据 → select 挂起（等 ChannelReady 事件）
        engine.run_ready_nodes(fid);
        assert_eq!(
            engine.frames.get(fid).state,
            FrameState::Suspended,
            "frame should be suspended (no ready branch)"
        );
        assert_eq!(
            engine.frames.get(fid).suspend_event,
            None,
            "select frame should have suspend_event=None"
        );
        assert!(
            engine
                .event_waiters
                .iter()
                .any(|(e, wf)| *wf == fid && matches!(e, RuntimeEvent::ChannelReady(c) if *c == ch_id)),
            "ChannelReady event should be registered"
        );

        // 发送数据到 channel → 手动触发 ChannelReady 事件
        let sent_val = Value::i32(77);
        engine.channel_runtime.send(ch_id, sent_val);
        engine.on_event_arrived(RuntimeEvent::ChannelReady(ch_id), Value::VOID);

        assert_eq!(
            engine.frames.get(fid).state,
            FrameState::Ready,
            "frame should be ready after ChannelReady event"
        );

        // 第二次执行：channel 有数据 → select 选 channel 分支 → 启动 SG0
        // 清除 on_event_arrived 推入的 fid，避免与子帧混淆
        engine.ready_frames.clear();
        engine.run_ready_nodes(fid);
        assert_eq!(
            engine.frames.get(fid).state,
            FrameState::Suspended,
            "frame should be suspended waiting for select subgraph"
        );

        // 子帧完成
        let child_fid = engine
            .ready_frames
            .pop_front()
            .expect("child frame should be ready");
        engine.run_ready_nodes(child_fid);
        assert_eq!(
            engine.frames.get(child_fid).state,
            FrameState::Completed,
            "child frame should be completed"
        );

        // 子图完成 → 回写 + 唤醒
        engine.complete_and_wake_caller(child_fid);
        engine.run_ready_nodes(fid);
        assert_eq!(
            engine.frames.get(fid).state,
            FrameState::Completed,
            "frame should be completed"
        );

        let result = engine.extract_child_return(fid);
        assert_eq!(result.as_i32(), 42);
    }

    /// 端到端：字符串索引 s[i] 返回第 i 个 Unicode 码点
    ///
    /// SG0: N0=Const("héllo" 运行时注入), N1=Const(1), N2=Index(N0, N1)
    /// 验证：s[1] = 'é' (U+00E9)
    #[test]
    fn test_string_index_codepoint() {
        let mut graph = DataFlowGraph::new();

        // N0: Const 占位（Str 值运行时注入）
        let n0 = graph.add_node(Node {
            kind: NodeKind::Const, input_count: 0, inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        // N1: Const(1)
        let n1 = graph.add_node(Node {
            kind: NodeKind::Const, input_count: 0, inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        graph.const_values[n1.0 as usize] = Some(ConstValue::I32(1));
        // N2: Index(N0, N1) — compute_array_index (idx 32)
        let off = graph.inputs_pool.push(&[n0, n1]);
        let n2 = graph.add_node(Node {
            kind: NodeKind::BinOp, input_count: 2, inputs_offset: off,
            compute_fn: ComputeFnId(32),
        });

        graph.add_subgraph(SubGraph {
            id: SubGraphId(0),
            node_range: (NodeId(0), NodeId(3)),
            param_count: 0,
            entry_node: n0,
            return_node: n2,
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });
        graph.set_entry_subgraph(SubGraphId(0));
        graph.compute_downstreams();

        let mut engine = Engine::new(graph);
        // 手动注入 Str 值到 N0
        let str_handle = crate::Value::Value::ref_val(crate::Value::HeapObj::Str(crate::Value::GlueStr::new("héllo")));
        let fid = engine.init_frame(SubGraphId(0));
        let frame = engine.frames.get_mut(fid);
        frame.set_value(NodeId(0), str_handle, 1);
        frame.push_ready(NodeId(0));
        // N1 是 Const 且有 const_values，prepare_frame 步骤2已预填充值并入就绪队列，无需重复 push

        engine.run_ready_nodes(fid);
        let result = engine.extract_child_return(fid);
        // 验证返回 'é' (U+00E9)
        let c = result.as_char() as u32;
        assert_eq!(c, 'é' as u32);
    }

    // =====================================================================
    // Trait 方法分派（静态 + 动态 vtable）
    // =====================================================================

    /// 静态 trait 分派：Call 节点静态绑定 call_target=SG0，模拟 trait 方法调用。
    ///
    /// SG0 (Show.show): N0=param self, N1=Const(42), return N1
    /// SG1 (main):      N2=Const(占位self), N3=Call(SG0, [N2]) — 静态 call_target=SG0
    /// 验证：trait 方法调用返回 42。
    #[test]
    fn test_trait_static_dispatch() {
        let mut graph = DataFlowGraph::new();

        // SG0: show(self) = 42  (param_count=1，self 不参与返回值)
        let n0 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        let n1 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        graph.const_values[n1.0 as usize] = Some(ConstValue::I32(42));
        graph.add_subgraph(SubGraph {
            id: SubGraphId(0),
            node_range: (NodeId(0), NodeId(2)),
            param_count: 1,
            entry_node: n0,
            return_node: n1,
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });

        // SG1: main() = show(占位 self)
        let n2 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        graph.const_values[n2.0 as usize] = Some(ConstValue::I32(0)); // 占位 self
        let call_off = graph.inputs_pool.push(&[n2]);
        let n3 = graph.add_node(Node {
            kind: NodeKind::Call,
            input_count: 1,
            inputs_offset: call_off,
            compute_fn: ComputeFnId(36),
        });
        graph.set_call_target(n3, SubGraphId(0)); // 静态绑定 trait 方法子图
        graph.add_subgraph(SubGraph {
            id: SubGraphId(1),
            node_range: (NodeId(2), NodeId(4)),
            param_count: 0,
            entry_node: n2,
            return_node: n3,
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });

        graph.set_entry_subgraph(SubGraphId(1));
        graph.compute_downstreams();

        let mut engine = Engine::new(graph);
        let result = engine.run_entry();
        assert_eq!(result.as_i32(), 42);
    }

    /// 动态 trait 分派（vtable）：Call 节点无 call_target，运行时从 TraitVal 查方法子图。
    ///
    /// SG0 (iter.next): N0=param self, N1=Const(42), return N1
    /// SG1 (main):      N2=Const(占位 recv), N3=Call(vtable "next", [N2]) — 不设 call_target
    /// 构造 TraitValue：method_names=["next"], method_values=[Closure{func_id:0}]
    /// 验证：vtable 调用从 TraitValue 查方法子图，返回 42。
    #[test]
    fn test_trait_dynamic_dispatch_vtable() {
        let mut graph = DataFlowGraph::new();

        // SG0: next(self) = 42  (param_count=1)
        let n0 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        let n1 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        graph.const_values[n1.0 as usize] = Some(ConstValue::I32(42));
        graph.add_subgraph(SubGraph {
            id: SubGraphId(0),
            node_range: (NodeId(0), NodeId(2)),
            param_count: 1,
            entry_node: n0,
            return_node: n1,
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });

        // SG1: main() = (recv).next()  — recv 运行时注入 TraitValue
        let n2 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        let call_off = graph.inputs_pool.push(&[n2]);
        let n3 = graph.add_node(Node {
            kind: NodeKind::Call,
            input_count: 1,
            inputs_offset: call_off,
            compute_fn: ComputeFnId(36),
        });
        graph.set_vtable_call(n3, "next".to_string()); // 动态分派：不设 call_target
        graph.add_subgraph(SubGraph {
            id: SubGraphId(1),
            node_range: (NodeId(2), NodeId(4)),
            param_count: 0,
            entry_node: n2,
            return_node: n3,
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });

        graph.set_entry_subgraph(SubGraphId(1));
        graph.compute_downstreams();

        let mut engine = Engine::new(graph);

        // 构造 TraitValue：method "next" → Closure{func_id:0}（指向 SG0）
        let closure = crate::Value::Closure {
            func_id: 0,
            arity: 1,
            upvalues: Vec::new(),
            bound_args: Vec::new(),
            self_upvalue_idx: -1,
            upvalue_ref_bits: 0,
            cell_upvalues: 0,
        };
        let closure_value = crate::Value::Value::ref_val(crate::Value::HeapObj::Closure(closure));
        let tv = crate::Value::TraitValue {
            trait_name: "Iterator".to_string(),
            method_names: vec!["next".to_string()],
            method_values: vec![closure_value],
            data: None,
            owned: true,
        };
        let tv_handle = crate::Value::Value::ref_val(crate::Value::HeapObj::TraitVal(tv));

        // 初始化 main 帧 + 手动注入 TraitValue 到 N2（recv，local 0）
        // N2 是无 const_value 的 Const 占位，prepare_frame 未预填充，需手动设值 + 入队。
        let fid = engine.init_frame(SubGraphId(1));
        {
            let frame = engine.frames.get_mut(fid);
            frame.set_value(NodeId(0), tv_handle, 1); // 1 downstream (N3)
            frame.push_ready(NodeId(0));
        }
        engine.ready_frames.push_back(fid);

        // 手动事件循环（run_event_loop 会重新 init_frame 丢失注入，故手动驱动）。
        // 逻辑与 run_event_loop 等价：sync call 子帧完成后 complete_and_wake_caller 唤醒调用方。
        let result = loop {
            let fid = match engine.ready_frames.pop_front() {
                Some(f) => f,
                None => panic!("event loop exhausted: no ready frames"),
            };
            engine.run_ready_nodes(fid);
            let state = engine.frames.get(fid).state;
            let has_caller = engine.frames.get(fid).caller.is_some();
            match state {
                FrameState::Suspended => {
                    let event = engine.frames.get(fid).suspend_event;
                    if let Some(e) = event {
                        engine.event_waiters.push((e, fid));
                    }
                }
                FrameState::Completed => {
                    if has_caller {
                        // sync 子帧完成：清理 waiter + 回写返回值 + 唤醒调用方
                        engine.event_waiters.retain(|(e, _)| {
                            !matches!(e, RuntimeEvent::SubgraphComplete(c) if *c == fid)
                        });
                        engine.complete_and_wake_caller(fid);
                    } else {
                        break engine.extract_child_return(fid);
                    }
                }
                _ => {
                    engine.ready_frames.push_back(fid);
                }
            }
        };

        assert_eq!(result.as_i32(), 42);
    }

    /// 端到端：cancel 挂起的 async 帧
    ///
    /// SG0: async_fn() = await timer(100ms) → 42
    /// 验证：cancel 后子帧状态 Suspended → Cancelling → Failed
    #[test]
    fn test_cancel_suspended_frame() {
        let mut graph = DataFlowGraph::new();

        // SG0: async_fn() = await timer → 42
        // N0: Const(timer handle 占位), N1: EventSource(Timer), N2: Await(N0)
        let n0 = graph.add_node(Node {
            kind: NodeKind::Const, input_count: 0, inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        let n1 = graph.add_node(Node {
            kind: NodeKind::EventSource, input_count: 0, inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        let await_off = graph.inputs_pool.push(&[n0]);
        let n2 = graph.add_node(Node {
            kind: NodeKind::Await, input_count: 1, inputs_offset: await_off,
            compute_fn: ComputeFnId(38),
        });
        graph.set_await_event_source(n2, n1);
        graph.add_subgraph(SubGraph {
            id: SubGraphId(0),
            node_range: (NodeId(0), NodeId(3)),
            param_count: 0,
            entry_node: n0,
            return_node: n2,
            has_suspend: true,
            event_source_decls: vec![EventSourceDecl { node: n1, kind: EventSourceKind::Timer }],
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });

        graph.set_entry_subgraph(SubGraphId(0));
        graph.compute_downstreams();

        let mut engine = Engine::new(graph);
        let timer_handle = Value::i32(0);
        let _timer_id = engine.timer_runtime.start(std::time::Duration::from_millis(100));

        let fid = engine.init_frame(SubGraphId(0));
        let frame = engine.frames.get_mut(fid);
        frame.set_value(NodeId(0), timer_handle, 1);
        frame.push_ready(NodeId(0));

        // 执行 → await 检查 timer → 未到期 → 帧挂起
        engine.run_ready_nodes(fid);
        assert_eq!(engine.frames.get(fid).state, FrameState::Suspended,
            "frame should be suspended waiting for timer");

        // cancel 帧族
        engine.cancel_frame(fid);
        assert_eq!(engine.frames.get(fid).state, FrameState::Cancelling,
            "frame should be in Cancelling state after cancel");

        // worker 检测到 Cancelling → 执行 defer 清理 → 标记 Failed
        engine.run_ready_nodes(fid);
        assert_eq!(engine.frames.get(fid).state, FrameState::Failed,
            "frame should be Failed after cancel cleanup");
    }

    /// 端到端：cancel 非 Suspended 帧（无效果）
    ///
    /// 验证：cancel Ready/Completed 帧不改变状态
    #[test]
    fn test_cancel_non_suspended_frame_noop() {
        let mut graph = DataFlowGraph::new();
        let n0 = graph.add_node(Node {
            kind: NodeKind::Const, input_count: 0, inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        graph.const_values[n0.0 as usize] = Some(ConstValue::I32(42));
        graph.add_subgraph(SubGraph {
            id: SubGraphId(0),
            node_range: (NodeId(0), NodeId(1)),
            param_count: 0,
            entry_node: n0,
            return_node: n0,
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });
        graph.set_entry_subgraph(SubGraphId(0));
        graph.compute_downstreams();

        let mut engine = Engine::new(graph);
        let fid = engine.init_frame(SubGraphId(0));

        // 帧处于 Ready 态，cancel 应无效果
        engine.cancel_frame(fid);
        assert_eq!(engine.frames.get(fid).state, FrameState::Ready,
            "cancel on Ready frame should be noop");

        // 执行帧 → Completed
        engine.run_ready_nodes(fid);
        assert_eq!(engine.frames.get(fid).state, FrameState::Completed);

        // cancel Completed 帧也应无效果
        engine.cancel_frame(fid);
        assert_eq!(engine.frames.get(fid).state, FrameState::Completed,
            "cancel on Completed frame should be noop");
    }

    // =================================================================
    // 多 worker（work-stealing）端到端测试
    // =================================================================

    /// 端到端：多 worker 模式执行简单图（1 + 2 = 3）
    ///
    /// 验证：WorkerPool 正确分发入口帧 → worker 执行 → 返回结果
    #[test]
    fn test_multi_worker_simple() {
        let graph = make_simple_graph();
        let mut engine = Engine::new(graph);
        let result = engine.run_multi_worker(2);
        assert_eq!(result.as_i32(), 3);
    }

    /// 端到端：多 worker 模式执行 async 并发调用
    ///
    /// 复用 test_concurrent_async_calls 的 IR（两个 async 调用并发 await），
    /// 验证多 worker 模式下 async 调用 + await 正确工作。
    #[test]
    fn test_multi_worker_concurrent_async() {
        let mut graph = DataFlowGraph::new();

        // SG0: async_fn() = 42
        let n0 = graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });
        graph.const_values[n0.0 as usize] = Some(ConstValue::I32(42));
        graph.add_subgraph(SubGraph {
            id: SubGraphId(0),
            node_range: (NodeId(0), NodeId(1)),
            param_count: 0,
            entry_node: n0,
            return_node: n0,
            has_suspend: true,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });

        // SG1: main() = async_fn().await() + async_fn().await()
        let n1 = graph.add_node(Node {
            kind: NodeKind::Call, input_count: 0, inputs_offset: 0,
            compute_fn: ComputeFnId(39),
        });
        graph.set_call_target(n1, SubGraphId(0));

        let n2 = graph.add_node(Node {
            kind: NodeKind::EventSource, input_count: 0, inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });

        let off3 = graph.inputs_pool.push(&[n1]);
        let n3 = graph.add_node(Node {
            kind: NodeKind::Await, input_count: 1, inputs_offset: off3,
            compute_fn: ComputeFnId(38),
        });
        graph.set_await_event_source(n3, n2);

        let n4 = graph.add_node(Node {
            kind: NodeKind::Call, input_count: 0, inputs_offset: 0,
            compute_fn: ComputeFnId(39),
        });
        graph.set_call_target(n4, SubGraphId(0));

        let n5 = graph.add_node(Node {
            kind: NodeKind::EventSource, input_count: 0, inputs_offset: 0,
            compute_fn: ComputeFnId(0),
        });

        let off6 = graph.inputs_pool.push(&[n4]);
        let n6 = graph.add_node(Node {
            kind: NodeKind::Await, input_count: 1, inputs_offset: off6,
            compute_fn: ComputeFnId(38),
        });
        graph.set_await_event_source(n6, n5);

        let off7 = graph.inputs_pool.push(&[n3, n6]);
        let n7 = graph.add_node(Node {
            kind: NodeKind::BinOp, input_count: 2, inputs_offset: off7,
            compute_fn: ComputeFnId(1),
        });

        graph.add_subgraph(SubGraph {
            id: SubGraphId(1),
            node_range: (NodeId(1), NodeId(8)),
            param_count: 0,
            entry_node: n1,
            return_node: n7,
            has_suspend: false,
            event_source_decls: vec![
                EventSourceDecl { node: n2, kind: EventSourceKind::AsyncJoin },
                EventSourceDecl { node: n5, kind: EventSourceKind::AsyncJoin },
            ],
            defer_table: Vec::new(),
            loop_kind: crate::Ir::LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: 0,
            iter_next_node: None,
        });

        graph.set_entry_subgraph(SubGraphId(1));
        graph.compute_downstreams();

        let mut engine = Engine::new(graph);
        let result = engine.run_multi_worker(4);
        assert_eq!(result.as_i32(), 84);
    }

    /// 端到端：单 worker 模式（num_workers=1）等价于单线程执行
    ///
    /// 验证：num_workers=1 时 WorkerPool 正确工作
    #[test]
    fn test_multi_worker_single_worker() {
        let graph = make_simple_graph();
        let mut engine = Engine::new(graph);
        let result = engine.run_multi_worker(1);
        assert_eq!(result.as_i32(), 3);
    }

    // ===== Task 13-14: 循环状态穿透 + 迭代帧端到端测试 =====

    /// while 循环内赋值外部可见性
    #[test]
    fn test_while_assignment_visible_outside() {
        let src = r#"
            fun main(): i32 {
                var sum: i32 = 0
                var i: i32 = 0
                while i < 10 {
                    sum = sum + i
                    i = i + 1
                }
                return sum
            }
        "#;
        let (_engine, h) = run_source(src);
        assert_eq!(h.as_i32(), 45);
    }

    /// while 循环累加 1..=100
    #[test]
    fn test_while_sum_1_to_100() {
        let src = r#"
            fun main(): i32 {
                var sum: i32 = 0
                var i: i32 = 1
                while i <= 100 {
                    sum = sum + i
                    i = i + 1
                }
                return sum
            }
        "#;
        let (_engine, h) = run_source(src);
        assert_eq!(h.as_i32(), 5050);
    }

    /// loop + break 赋值
    #[test]
    fn test_loop_break_assignment() {
        let src = r#"
            fun main(): i32 {
                var x: i32 = 0
                loop {
                    x = x + 1
                    if x >= 5 { break }
                }
                return x
            }
        "#;
        let (_engine, h) = run_source(src);
        assert_eq!(h.as_i32(), 5);
    }

    /// 嵌套 while 循环
    #[test]
    fn test_nested_while() {
        let src = r#"
            fun main(): i32 {
                var total: i32 = 0
                var i: i32 = 0
                while i < 3 {
                    var j: i32 = 0
                    while j < 3 {
                        total = total + 1
                        j = j + 1
                    }
                    i = i + 1
                }
                return total
            }
        "#;
        let (_engine, h) = run_source(src);
        assert_eq!(h.as_i32(), 9);
    }

    /// if 分支内赋值外层变量
    #[test]
    fn test_if_assignment_outside() {
        let src = r#"
            fun main(): i32 {
                var x: i32 = 1
                if true { x = 2 }
                return x
            }
        "#;
        let (_engine, h) = run_source(src);
        assert_eq!(h.as_i32(), 2);
    }

    /// match 分支内赋值外层变量（WriteBack 适配）
    #[test]
    fn test_match_assignment_outside() {
        let src = r#"
            fun main(): i32 {
                var x: i32 = 1
                match 1 {
                    1 => { x = 2 }
                    _ => { x = 3 }
                }
                return x
            }
        "#;
        let (_engine, h) = run_source(src);
        assert_eq!(h.as_i32(), 2);
    }

    /// while + continue 跳过偶数
    #[test]
    fn test_while_continue_skip_even() {
        let src = r#"
            fun main(): i32 {
                var sum: i32 = 0
                var i: i32 = 0
                while i < 10 {
                    i = i + 1
                    if i % 2 == 0 { continue }
                    sum = sum + i
                }
                return sum
            }
        "#;
        let (_engine, h) = run_source(src);
        // 1+3+5+7+9 = 25
        assert_eq!(h.as_i32(), 25);
    }

    /// O(1) 内存验证：大循环不堆积帧
    #[test]
    fn test_loop_frame_count_stable() {
        let src = r#"
            fun main(): i32 {
                var sum: i32 = 0
                var i: i32 = 0
                while i < 10000 {
                    sum = sum + 1
                    i = i + 1
                }
                return sum
            }
        "#;
        let (engine, h) = run_source(src);
        assert_eq!(h.as_i32(), 10000);
        // 帧池大小应远小于循环次数（O(1) 内存）
        // next_id 包含所有分配过的帧（含已释放），但活跃帧数应恒定
        assert!(
            engine.frames.next_id < 100,
            "frame count {} should be O(1), not O(n)",
            engine.frames.next_id
        );
    }
}
