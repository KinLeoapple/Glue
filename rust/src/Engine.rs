//! Engine.rs — 数据流就绪调度执行引擎
//!
//! 基于 Ir.rs 的 DataFlowGraph，实现：
//! - Frame 管理（HashMap + LockStrategy）
//! - 就绪调度（核心循环）
//! - 子图启动（start/complete）
//! - compute_fn 执行
//!
//! 设计原则（见 docs/superpowers/specs/2026-07-31-dataflow-engine-design.md）：
//! - 无 dispatch：调度器只认"输入就绪"，节点自带 compute_fn
//! - sync/async 统一：子图有无挂起点
//! - 帧级回收 + 槽级 RC

use crate::ir::Ir::*;
use crate::Value::{Value, ValueArena};
use std::cell::{RefCell, RefMut};
use std::ops::DerefMut;
use parking_lot::{Condvar, Mutex as ParkingMutex, MutexGuard as ParkingMutexGuard};
use hashbrown::HashMap;
use crossbeam_deque::{Injector, Stealer, Worker as DequeWorker};
use std::sync::Arc;

// =========================================================================
// 哨兵常量 — 集中定义，避免散落魔数
// =========================================================================

/// Thunk 帧使用的哨兵 FrameId（不参与正常分配，避免与 alloc_frame_id 冲突）。
const THUNK_FRAME_ID: FrameId = FrameId(u32::MAX);
/// LoopBody 回退子帧使用的哨兵 FrameId（不参与正常分配）。
const LOOPBODY_FALLBACK_FRAME_ID: FrameId = FrameId(u32::MAX - 1);
/// `pending_inputs` 槽位哨兵：标记"永不就绪/外部源"（实际入度必须 < 255）。
const PENDING_EXTERNAL: u8 = u8::MAX;
/// splitmix64 黄金比例散列常量（确保各 worker 的 steal 顺序互异）。
const GOLDEN_RATIO_64: u64 = 0x9E3779B97F4A7C15;

/// IO 写入成功返回值（i32）。仅在 `#[cfg(not(has_extern_c))]` 的 fallback 路径使用。
#[allow(dead_code)]
const IO_OK: i32 = 0;
/// IO 写入失败返回值（i32）。仅在 `#[cfg(not(has_extern_c))]` 的 fallback 路径使用。
#[allow(dead_code)]
const IO_ERR: i32 = -1;
/// UTF-8 解码失败/越界返回值（i64）。
const UTF8_DECODE_ERR: i64 = -1;

/// Result 变体构造器名（与 stdlib 的 Result 类型定义保持同步）。
const CTOR_OK: &str = "Ok";
const CTOR_ERR: &str = "Error";
const CTOR_ERR_ALT: &str = "Err";

/// Timer 事件 Record 中 duration 字段名。
const TIMER_DURATION_NS_FIELD: &str = "duration_ns";

/// reflect 类型名常量（单点维护，供 __reflect_type_name / compute_cast_to_str 共用）。
const TYPE_NAME_NULL: &str = "null";
const TYPE_NAME_VOID: &str = "void";
const TYPE_NAME_STR: &str = "str";
const TYPE_NAME_ARRAY: &str = "array";
const TYPE_NAME_UNKNOWN: &str = "unknown";

// =========================================================================
// reflect 辅助函数 — 消除 FFI/fallback 双路径重复
// =========================================================================

/// 返回 Value 的 reflect kind 编号（ABI 协议：0-12）。
/// 单一权威来源，FFI 与 fallback 路径共用，确保一致。
fn reflect_kind(v: &Value) -> u8 {
    match v {
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
        },
    }
}

/// 返回 Value 的 reflect kind 显示名（单点维护，FFI 与 fallback 共用）。
fn reflect_kind_str(v: &Value) -> &'static str {
    match v {
        Value::Null => "Null",
        Value::Void => "Void",
        Value::Scalar(_, _) => "Primitive",
        Value::Ref(r) => match &**r {
            crate::Value::HeapObj::Str(_) => "Str",
            crate::Value::HeapObj::Array(_) => "Array",
            crate::Value::HeapObj::Record(_) => "Record",
            crate::Value::HeapObj::Adt(_) => "Adt",
            crate::Value::HeapObj::Newtype(_) => "Newtype",
            crate::Value::HeapObj::Closure(_) => "Closure",
            crate::Value::HeapObj::TraitVal(_) => "Trait",
            _ => "Ref",
        },
    }
}

/// 返回 Value 的类型名（单点维护，FFI 与 fallback / cast_to_str 共用）。
fn reflect_type_name(v: &Value) -> String {
    match v {
        Value::Null => TYPE_NAME_NULL.to_string(),
        Value::Void => TYPE_NAME_VOID.to_string(),
        Value::Scalar(_, tag) => tag.type_name().to_string(),
        Value::Ref(r) => match &**r {
            crate::Value::HeapObj::Str(_) => TYPE_NAME_STR.to_string(),
            crate::Value::HeapObj::Array(_) => TYPE_NAME_ARRAY.to_string(),
            crate::Value::HeapObj::Record(rec) => rec.type_name.clone(),
            crate::Value::HeapObj::Adt(a) => a.type_name.clone(),
            crate::Value::HeapObj::Newtype(n) => n.type_name.clone(),
            _ => TYPE_NAME_UNKNOWN.to_string(),
        },
    }
}

/// UTF-8 解码：从 bytes[offset] 起解码一个 codepoint。
/// 成功返回 (codepoint, consumed_bytes)，失败（越界/非法首字节）返回 None。
/// 单一实现，消除 FFI/fallback 双路径重复。
fn utf8_decode_at(bytes: &[u8], offset: usize) -> Option<(u32, usize)> {
    if offset >= bytes.len() {
        return None;
    }
    let c = bytes[offset];
    // ASCII（1 字节）
    if c < 0x80 {
        return Some((c as u32, 1));
    }
    // 2 字节序列：110xxxxx 10xxxxxx
    if (c & 0xE0) == 0xC0 {
        if offset + 1 >= bytes.len() {
            return None;
        }
        let cp = ((c as u32 & 0x1F) << 6) | (bytes[offset + 1] as u32 & 0x3F);
        return Some((cp, 2));
    }
    // 3 字节序列：1110xxxx 10xxxxxx 10xxxxxx
    if (c & 0xF0) == 0xE0 {
        if offset + 2 >= bytes.len() {
            return None;
        }
        let cp = ((c as u32 & 0x0F) << 12)
            | ((bytes[offset + 1] as u32 & 0x3F) << 6)
            | (bytes[offset + 2] as u32 & 0x3F);
        return Some((cp, 3));
    }
    // 4 字节序列：11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
    if (c & 0xF8) == 0xF0 {
        if offset + 3 >= bytes.len() {
            return None;
        }
        let cp = ((c as u32 & 0x07) << 18)
            | ((bytes[offset + 1] as u32 & 0x3F) << 12)
            | ((bytes[offset + 2] as u32 & 0x3F) << 6)
            | (bytes[offset + 3] as u32 & 0x3F);
        return Some((cp, 4));
    }
    // 非法首字节
    None
}

/// 将 u32 codepoint 转为 char，非法 codepoint 回退为 U+0000。
/// 单点统一，消除 3 处重复的 `char::from_u32(x).unwrap_or('\0')`。
#[inline]
fn char_from_u32_or_nul(u: u32) -> char {
    char::from_u32(u).unwrap_or('\0')
}

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
///
/// 算术逻辑复用 Value.rs 的纯算术核心（`arith_*` 函数），runtime 与编译期 ConstFold 共用。
/// compute_fn 仅负责 Frame 取值与 Value 包装，算术本身无 Frame 依赖。
macro_rules! impl_int_ops {
    ($ty:ident, $rust:ty, $ctor:ident, $acc:ident) => {
        pastey::paste! {
            pub fn [<compute_add_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                let b = frame.get_value_by_global(inputs[1]).$acc();
                Value::$ctor(crate::Value::[<arith_add_$ty>](a, b))
            }
            pub fn [<compute_sub_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                let b = frame.get_value_by_global(inputs[1]).$acc();
                Value::$ctor(crate::Value::[<arith_sub_$ty>](a, b))
            }
            pub fn [<compute_mul_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                let b = frame.get_value_by_global(inputs[1]).$acc();
                Value::$ctor(crate::Value::[<arith_mul_$ty>](a, b))
            }
            pub fn [<compute_div_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                let b = frame.get_value_by_global(inputs[1]).$acc();
                // 整数除零返回 0（checked 语义，由 arith_div_$ty 实现）
                Value::$ctor(crate::Value::[<arith_div_$ty>](a, b))
            }
            pub fn [<compute_mod_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                let b = frame.get_value_by_global(inputs[1]).$acc();
                Value::$ctor(crate::Value::[<arith_mod_$ty>](a, b))
            }
            pub fn [<compute_bitand_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                let b = frame.get_value_by_global(inputs[1]).$acc();
                Value::$ctor(crate::Value::[<arith_bitand_$ty>](a, b))
            }
            pub fn [<compute_bitor_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                let b = frame.get_value_by_global(inputs[1]).$acc();
                Value::$ctor(crate::Value::[<arith_bitor_$ty>](a, b))
            }
            pub fn [<compute_bitxor_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                let b = frame.get_value_by_global(inputs[1]).$acc();
                Value::$ctor(crate::Value::[<arith_bitxor_$ty>](a, b))
            }
            pub fn [<compute_shl_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                // 移位量按 i32 读取（与原语义一致），纯函数内部 cast u32
                let shift = frame.get_value_by_global(inputs[1]).as_i32();
                Value::$ctor(crate::Value::[<arith_shl_$ty>](a, shift))
            }
            pub fn [<compute_shr_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                let shift = frame.get_value_by_global(inputs[1]).as_i32();
                Value::$ctor(crate::Value::[<arith_shr_$ty>](a, shift))
            }
            pub fn [<compute_neg_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                Value::$ctor(crate::Value::[<arith_neg_$ty>](a))
            }
            pub fn [<compute_bitnot_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                Value::$ctor(crate::Value::[<arith_bitnot_$ty>](a))
            }
        }
    };
}

/// 为指定浮点类型生成全套 compute_fn（add/sub/mul/div/mod/neg）
///
/// 算术逻辑复用 Value.rs 的纯算术核心（`arith_*` 函数）。
macro_rules! impl_float_ops {
    ($ty:ident, $rust:ty, $ctor:ident, $acc:ident) => {
        pastey::paste! {
            pub fn [<compute_add_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                let b = frame.get_value_by_global(inputs[1]).$acc();
                Value::$ctor(crate::Value::[<arith_add_$ty>](a, b))
            }
            pub fn [<compute_sub_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                let b = frame.get_value_by_global(inputs[1]).$acc();
                Value::$ctor(crate::Value::[<arith_sub_$ty>](a, b))
            }
            pub fn [<compute_mul_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                let b = frame.get_value_by_global(inputs[1]).$acc();
                Value::$ctor(crate::Value::[<arith_mul_$ty>](a, b))
            }
            pub fn [<compute_div_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                let b = frame.get_value_by_global(inputs[1]).$acc();
                Value::$ctor(crate::Value::[<arith_div_$ty>](a, b))
            }
            pub fn [<compute_mod_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                let b = frame.get_value_by_global(inputs[1]).$acc();
                Value::$ctor(crate::Value::[<arith_mod_$ty>](a, b))
            }
            pub fn [<compute_neg_$ty>](frame: &mut Frame, node: NodeId) -> Value {
                let graph = frame.graph.clone();
                let n = &graph.nodes[node.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let a = frame.get_value_by_global(inputs[0]).$acc();
                Value::$ctor(crate::Value::[<arith_neg_$ty>](a))
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

/// compute_fn: bool 与（复用纯算术核心）
pub fn compute_and_bool(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let a = frame.get_value_by_global(inputs[0]).as_bool();
    let b = frame.get_value_by_global(inputs[1]).as_bool();
    Value::bool_val(crate::Value::arith_and_bool(a, b))
}

/// compute_fn: bool 或（复用纯算术核心）
pub fn compute_or_bool(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let a = frame.get_value_by_global(inputs[0]).as_bool();
    let b = frame.get_value_by_global(inputs[1]).as_bool();
    Value::bool_val(crate::Value::arith_or_bool(a, b))
}

/// compute_fn: bool 非（一元，复用纯算术核心）
pub fn compute_not_bool(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let a = frame.get_value_by_global(inputs[0]).as_bool();
    Value::bool_val(crate::Value::arith_not_bool(a))
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
    // Record（错误类型）→ 直接作为 Err payload
    if let Some(HeapObj::Record(record)) = v.heap_obj() {
        return Value::ref_val(HeapObj::ThrowVal(ThrowValue {
            payload: ThrowPayload::Err(Arc::new(record.clone())),
        }));
    }
    // Adt（错误类型 ADT）→ 转换为 Record 后作为 Err payload
    if let Some(HeapObj::Adt(a)) = v.heap_obj() {
        let record = RecordValue {
            type_name: a.type_name.clone(),
            fields: a.fields.iter().map(|f| f.value.clone()).collect(),
            field_names: a.fields.iter().map(|f| f.name.clone()).collect(),
            field_ref_bits: 0,
        };
        return Value::ref_val(HeapObj::ThrowVal(ThrowValue {
            payload: ThrowPayload::Err(Arc::new(record)),
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
    use crate::Value::{HeapObj, RecordValue, ThrowValue, ThrowPayload};
    read_node_inputs!(frame, node, graph, n, inputs);
    let v = frame.get_value_by_global(inputs[0]);
    // v 应为 Record 或 Adt（由 record_construct 节点产生）
    if let Some(HeapObj::Record(record)) = v.heap_obj() {
        Value::ref_val(HeapObj::ThrowVal(ThrowValue {
            payload: ThrowPayload::Err(Arc::new(record.clone())),
        }))
    } else if let Some(HeapObj::Adt(a)) = v.heap_obj() {
        // Adt → 转换为 Record 后作为 Err payload
        let record = RecordValue {
            type_name: a.type_name.clone(),
            fields: a.fields.iter().map(|f| f.value.clone()).collect(),
            field_names: a.fields.iter().map(|f| f.name.clone()).collect(),
            field_ref_bits: 0,
        };
        Value::ref_val(HeapObj::ThrowVal(ThrowValue { payload: ThrowPayload::Err(Arc::new(record)) }))
    } else {
        // 非 record/adt 值，包装为单字段 Error record
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
///
/// 输入为 Nullable 值：
/// - null → 设 frame.control_signal = Return(null)，函数提前返回 null（要求外层返回类型为 T?）
/// - 非 null → 返回值本身（nullable 值与非空值表示同构，直接透传）
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
    } else if v.is_null() {
        // Nullable 传播：值为 null 时，设 Return 信号携带 null 提前返回
        frame.control_signal = ControlSignal::Return(v.clone());
        Value::VOID
    } else {
        // 非 null 的 Nullable 值：直接透传（nullable 值与非空值表示同构）
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

    // 将 FFI 读取的数据写回 Glue u8[] 数组（原地修改底层 HeapObj，&self 语义）。
    //
    // extract_u8_buf 返回 clone 的 Vec，FFI 写入局部 Vec 后需写回原数组，
    // 否则 Glue 侧读取的数据为零（H-2 修复）。
    // 仅写回 buf[0..n]，n 由 FFI 返回值决定（调用方传入）。
    fn writeback_u8_buf(buf_val: &Value, data: &[u8], n: usize) {
        if let Value::Ref(arc) = buf_val {
            // Safety: 引擎单线程执行，caller 帧在 callee 执行期间 Suspended，
            // 不会有并发访问同一 HeapObj 的路径（与 compute_record_field_set 一致）。
            let ptr = std::sync::Arc::as_ptr(arc) as *mut crate::Value::HeapObj;
            unsafe {
                if let crate::Value::HeapObj::Array(arr) = &mut *ptr {
                    let len = n.min(data.len()).min(arr.elements.len());
                    // SOA 快路径：U8 连续存储直接 memcpy
                    if let Some(crate::Value::ScalarSoA::U8(ref mut soa_data)) = arr.scalar_soa {
                        let len = len.min(soa_data.len());
                        soa_data[..len].copy_from_slice(&data[..len]);
                    } else {
                        for i in 0..len {
                            arr.elements[i] = Value::u8(data[i]);
                        }
                    }
                }
            }
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
            let buf_val = frame.get_value_by_global(inputs[1]);
            let mut buf = extract_u8_buf(&buf_val);
            let len = frame.get_value_by_global(inputs[2]).as_usize();
            let n = unsafe { wrapper::__file_read_into(fd, &mut buf, len) };
            if n > 0 { writeback_u8_buf(&buf_val, &buf, n as usize); }
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
            let buf_val = frame.get_value_by_global(inputs[0]);
            let mut buf = extract_u8_buf(&buf_val);
            let n = unsafe { wrapper::__stdin_readln_into(&mut buf) };
            if n > 0 { writeback_u8_buf(&buf_val, &buf, n as usize); }
            Value::i64(n)
        }

        // ── IO: stat/fstat ──
        "__file_stat_into" => {
            let path = extract_str(&frame.get_value_by_global(inputs[0]));
            let buf_val = frame.get_value_by_global(inputs[1]);
            let mut buf = extract_u8_buf(&buf_val);
            let rc = unsafe { wrapper::__file_stat_into(&path, &mut buf) };
            if rc == 0 { writeback_u8_buf(&buf_val, &buf, buf.len()); }
            Value::i32(rc)
        }
        "__file_fstat_into" => {
            let fd = frame.get_value_by_global(inputs[0]).as_i64();
            let buf_val = frame.get_value_by_global(inputs[1]);
            let mut buf = extract_u8_buf(&buf_val);
            let rc = unsafe { wrapper::__file_fstat_into(fd, &mut buf) };
            if rc == 0 { writeback_u8_buf(&buf_val, &buf, buf.len()); }
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
            let names_val = frame.get_value_by_global(inputs[1]);
            let offsets_val = frame.get_value_by_global(inputs[2]);
            let kinds_val = frame.get_value_by_global(inputs[3]);
            let mut names_buf = extract_u8_buf(&names_val);
            let mut name_offsets = extract_u8_buf(&offsets_val);
            let mut kinds_buf = extract_u8_buf(&kinds_val);
            let max_count = frame.get_value_by_global(inputs[4]).as_usize();
            let count = unsafe {
                wrapper::__dir_list_into(&path, &mut names_buf, &mut name_offsets, &mut kinds_buf, max_count)
            };
            if count > 0 {
                writeback_u8_buf(&names_val, &names_buf, names_buf.len());
                writeback_u8_buf(&offsets_val, &name_offsets, name_offsets.len());
                writeback_u8_buf(&kinds_val, &kinds_buf, kinds_buf.len());
            }
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
            let buf_val = frame.get_value_by_global(inputs[1]);
            let mut buf = extract_u8_buf(&buf_val);
            let len = frame.get_value_by_global(inputs[2]).as_usize();
            let n = unsafe { wrapper::__net_tcp_read(fd, &mut buf, len) };
            if n > 0 { writeback_u8_buf(&buf_val, &buf, n as usize); }
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
            let buf_val = frame.get_value_by_global(inputs[1]);
            let mut buf = extract_u8_buf(&buf_val);
            let len = frame.get_value_by_global(inputs[2]).as_usize();
            let n = unsafe { wrapper::__net_udp_recv_from_v4(fd, &mut buf, len) };
            if n > 0 { writeback_u8_buf(&buf_val, &buf, n as usize); }
            Value::i64(n)
        }

        // ── net: resolve ──
        "__net_resolve_into" => {
            let host = extract_str(&frame.get_value_by_global(inputs[0]));
            let buf_val = frame.get_value_by_global(inputs[1]);
            let mut out_buf = extract_u8_buf(&buf_val);
            let max_count = frame.get_value_by_global(inputs[2]).as_usize();
            let count = unsafe { wrapper::__net_resolve_into(&host, &mut out_buf, max_count) };
            if count > 0 { writeback_u8_buf(&buf_val, &out_buf, out_buf.len()); }
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
            let buf_val = frame.get_value_by_global(inputs[1]);
            let mut buf = extract_u8_buf(&buf_val);
            let len = frame.get_value_by_global(inputs[2]).as_usize();
            let n = unsafe { wrapper::__net_udp_recv_from_v6(fd, &mut buf, len) };
            if n > 0 { writeback_u8_buf(&buf_val, &buf, n as usize); }
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
            let r = unsafe { wrapper::__cast_char_to_u8(char_from_u32_or_nul(x)) };
            Value::u8(r)
        }

        // ── reflect: __reflect_format/__reflect_scalar_to_str 已拆分为独立
        // compute_fn（CF_REFLECT_FORMAT/CF_REFLECT_SCALAR_TO_STR，idx 290/291），
        // 不再走 FFI 分派路径 ──
        "__reflect_kind" => {
            let v = frame.get_value_by_global(inputs[0]);
            Value::u8(reflect_kind(&v))
        }
        "__reflect_type_name" => {
            let v = frame.get_value_by_global(inputs[0]);
            let name = reflect_type_name(&v);
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
                Value::Scalar(_, tag) => tag.byte_width(),
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
        "__reflect_kind_str" => {
            let v = frame.get_value_by_global(inputs[0]);
            let kind = reflect_kind_str(&v);
            Value::ref_val(crate::Value::HeapObj::Str(crate::Value::GlueStr::from_rust_str(kind)))
        }
        "__reflect_layout_size" => {
            let v = frame.get_value_by_global(inputs[0]);
            let size: u32 = crate::Reflect::reflect_layout_size(&v);
            Value::u32(size)
        }
        "__reflect_layout_alignment" => {
            let v = frame.get_value_by_global(inputs[0]);
            let align: u32 = crate::Reflect::reflect_layout_alignment(&v);
            Value::u32(align)
        }

        // ── str: UTF-8 逐字符解码（纯 Rust 位运算，与 C 实现语义一致）──
        "__str_utf8_decode_at" => {
            let s = extract_str(&frame.get_value_by_global(inputs[0]));
            let offset = frame.get_value_by_global(inputs[1]).as_usize();
            let bytes = s.as_bytes();
            match utf8_decode_at(bytes, offset) {
                Some((cp, _)) => Value::i64(cp as i64),
                None => Value::i64(UTF8_DECODE_ERR),
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
                Value::i32(IO_OK)
            } else {
                Value::i32(IO_ERR)
            }
        }
        "__stderr_write_raw" => {
            if let Some(crate::Value::HeapObj::Str(s)) = frame.get_value_by_global(inputs[0]).heap_obj() {
                use std::io::Write;
                let _ = std::io::stderr().write_all(s.bytes().as_bytes());
                Value::i32(IO_OK)
            } else {
                Value::i32(IO_ERR)
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

        // ── reflect: __reflect_format/__reflect_scalar_to_str 已拆分为独立
        // compute_fn（CF_REFLECT_FORMAT/CF_REFLECT_SCALAR_TO_STR，idx 290/291），
        // 不再走 FFI 分派路径 ──
        "__reflect_kind" => {
            let v = frame.get_value_by_global(inputs[0]);
            Value::u8(reflect_kind(&v))
        }
        "__reflect_type_name" => {
            let v = frame.get_value_by_global(inputs[0]);
            let name = reflect_type_name(&v);
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
                Value::Scalar(_, tag) => tag.byte_width(),
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
        "__reflect_kind_str" => {
            let v = frame.get_value_by_global(inputs[0]);
            let kind = reflect_kind_str(&v);
            Value::ref_val(crate::Value::HeapObj::Str(crate::Value::GlueStr::from_rust_str(kind)))
        }
        "__reflect_layout_size" => {
            let v = frame.get_value_by_global(inputs[0]);
            let size: u32 = crate::Reflect::reflect_layout_size(&v);
            Value::u32(size)
        }
        "__reflect_layout_alignment" => {
            let v = frame.get_value_by_global(inputs[0]);
            let align: u32 = crate::Reflect::reflect_layout_alignment(&v);
            Value::u32(align)
        }

        // ── str: UTF-8 逐字符解码（纯 Rust 位运算，与 C 实现语义一致）──
        "__str_utf8_decode_at" => {
            let s = match frame.get_value_by_global(inputs[0]).heap_obj() {
                Some(crate::Value::HeapObj::Str(s)) => s.bytes().to_string(),
                _ => String::new(),
            };
            let offset = frame.get_value_by_global(inputs[1]).as_usize();
            let bytes = s.as_bytes();
            match utf8_decode_at(bytes, offset) {
                Some((cp, _)) => Value::i64(cp as i64),
                None => Value::i64(UTF8_DECODE_ERR),
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

// =========================================================================
// reflect 独立 compute_fn（290-291）
//
// 从 compute_ffi_call 拆分出来，避免 lazy force 逻辑与 FFI 调用耦合。
// 这两个函数是唯一涉及 LazyValue 强制求值的 reflect 操作，独立后：
//   - 不再依赖 ffi_call_name 元数据
//   - 不走 FFI 分派路径
//   - lazy force 逻辑与 reflect 格式化逻辑内聚
// =========================================================================

/// compute_fn (idx 290): `__reflect_format` — 任意值 → str
///
/// 格式化前先强制求值 LazyValue（若输入是 lazy），再调用 Reflect::format_value。
/// 不依赖 ffi_call_name，直接读取 inputs[0]。
pub fn compute_reflect_format(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, _n, inputs);
    let v = frame.get_value_by_global(inputs[0]);
    let v = force_lazy_value_sync(frame, &v);
    let s = crate::Reflect::format_value(&v, 0);
    Value::ref_val(crate::Value::HeapObj::Str(crate::Value::GlueStr::from_rust_str(&s)))
}

/// compute_fn (idx 291): `__reflect_scalar_to_str` — 标量值 → str
///
/// 语义与 compute_reflect_format 一致（均走 format_value），独立保留以
/// 对应 Raw.glue 中的两个不同 @extern("C") 原语声明。
pub fn compute_reflect_scalar_to_str(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, _n, inputs);
    let v = frame.get_value_by_global(inputs[0]);
    let v = force_lazy_value_sync(frame, &v);
    let s = crate::Reflect::format_value(&v, 0);
    Value::ref_val(crate::Value::HeapObj::Str(crate::Value::GlueStr::from_rust_str(&s)))
}

/// compute_fn: 类型构造（从输入收集字段值，根据 kind 构造 Record/Adt/Newtype HeapObj）
pub fn compute_record_construct(frame: &mut Frame, node: NodeId) -> Value {
    use crate::ir::Ir::{RecordLitKind, RecordLitInfo};
    use crate::Value::{AdtField, AdtValue, HeapObj, NewtypeValue, RecordValue, ValueArena};
    read_node_inputs!(frame, node, graph, n, inputs);
    let fields: Vec<Value> = inputs
        .iter()
        .map(|&input_node| frame.get_value_by_global(input_node))
        .collect();
    let info: &RecordLitInfo = graph.record_lit_infos[node.0 as usize]
        .as_ref()
        .expect("record construct node has no RecordLitInfo");
    match info.kind {
        RecordLitKind::Record => {
            Value::ref_val(HeapObj::Record(RecordValue {
                type_name: info.type_name.clone(),
                fields,
                field_names: info.field_names.clone(),
                field_ref_bits: 0,
            }))
        }
        RecordLitKind::Adt => {
            let adt_fields: Vec<AdtField> = fields
                .into_iter()
                .enumerate()
                .map(|(i, v)| AdtField {
                    name: info.field_names.get(i).and_then(|n| n.clone()),
                    value: v,
                })
                .collect();
            Value::ref_val(HeapObj::Adt(AdtValue {
                type_name: info.type_name.clone(),
                constructor: info.constructor.clone(),
                fields: adt_fields,
                field_ref_bits: 0,
            }))
        }
        RecordLitKind::Newtype => {
            // Newtype：单字段，将 inner Value 存入全局 arena 得到 ValueHandle
            let inner_val = fields.into_iter().next().unwrap_or(Value::VOID);
            let inner = ValueArena::with_global_mut(|a| a.alloc_value(&inner_val));
            Value::ref_val(HeapObj::Newtype(NewtypeValue {
                type_name: info.type_name.clone(),
                inner,
            }))
        }
    }
}

/// compute_fn: 记录字段访问（按 field 名称从 Record/Adt 取字段值）
///
/// 统一机制：Record 与 Adt 均通过 `find_field(name)` 按名取值，
/// 不依赖编译期 field_idx，消除 idx fallback 与 Record/Adt 双路径差异。
pub fn compute_record_field_get(frame: &mut Frame, node: NodeId) -> Value {
    use std::sync::Arc;
    use crate::Value::{HeapObj, RecordValue, ThrowValue, ThrowPayload};
    read_node_inputs!(frame, node, graph, n, inputs);
    let record_val = frame.get_value_by_global(inputs[0]);
    let name = graph.field_set_names[node.0 as usize].as_deref();
    let make_err = |msg: &str| {
        let record = Arc::new(RecordValue {
            type_name: "FieldError".to_string(),
            fields: vec![Value::ref_val(HeapObj::Str(crate::Value::GlueStr::new(msg)))],
            field_names: vec![Some("message".to_string())],
            field_ref_bits: 1,
        });
        Value::ref_val(HeapObj::ThrowVal(ThrowValue { payload: ThrowPayload::Err(record) }))
    };
    let Some(h) = record_val.heap_obj() else {
        return make_err("field access on non-record value");
    };
    let Some(name) = name else {
        return make_err("field_get node has no field name");
    };
    h.field_get(name).unwrap_or_else(|| {
        make_err(&format!("no such field '{}' on record", name))
    })
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

/// compute_fn: 栈分配版记录构造（288）
///
/// 分析器标记为不逃逸的分配点使用此 compute_fn。
/// 当前实现等同 compute_record_construct（Value 模型限制下 Arc 是唯一引用方式），
/// 预留分离点：未来 Value 模型支持帧局部分配后，此函数切换为真正的栈分配。
pub fn compute_record_construct_stack(frame: &mut Frame, node: NodeId) -> Value {
    compute_record_construct(frame, node)
}

/// compute_fn: 栈分配版数组构造（289）
///
/// 分析器标记为不逃逸的分配点使用此 compute_fn。
/// 当前实现等同 compute_array_construct，预留分离点。
pub fn compute_array_construct_stack(frame: &mut Frame, node: NodeId) -> Value {
    compute_array_construct(frame, node)
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
    let val = guard.clone().unwrap_or(Value::NULL);
    val
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
/// 检查 scrutinee 是否为 ADT 且 constructor 匹配，或 Record 且 type_name 匹配，
/// 或 ThrowVal 且构造器名为 "Ok"/"Error" 匹配对应 payload 变体。
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
        // Newtype：构造器名 == 类型名，匹配 NewtypeValue.type_name
        Some(crate::Value::HeapObj::Newtype(n)) => n.type_name == *ctor_name,
        Some(crate::Value::HeapObj::ThrowVal(tv)) => match &tv.payload {
            crate::Value::ThrowPayload::Ok(_) => ctor_name == CTOR_OK,
            crate::Value::ThrowPayload::Err(_) => ctor_name == CTOR_ERR || ctor_name == CTOR_ERR_ALT,
        },
        _ => false,
    };
    Value::bool_val(matched)
}

/// compute_fn: 模式匹配 — ADT/Record/ThrowVal 按位置提取字段（idx 275）。
///
/// 输入：scrutinee。元数据：字段索引（graph.pattern_field_indices）。
/// 从 ADT 按位置取字段值，或从 Record 按位置取字段值，
/// 或从 ThrowVal 取内部值（索引 0：Ok 的 val 或 Err 的 record）。
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
        // Newtype：单字段，idx 0 取 inner 值（通过 ValueArena 全局句柄解引用）
        Some(crate::Value::HeapObj::Newtype(n)) => {
            if idx == 0 {
                crate::Value::ValueArena::with_global(|a| a.get_value(n.inner))
            } else {
                Value::VOID
            }
        }
        Some(crate::Value::HeapObj::ThrowVal(tv)) => {
            if idx == 0 {
                match &tv.payload {
                    crate::Value::ThrowPayload::Ok(v) => v.clone(),
                    crate::Value::ThrowPayload::Err(r) => {
                        Value::ref_val(crate::Value::HeapObj::Record((**r).clone()))
                    }
                }
            } else {
                Value::VOID
            }
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

/// compute_fn: str 比较（292-297）
///
/// 按 Unicode 码点序列字典序比较（Rust str 的 Ord 语义，UTF-8 字节序与码点序一致）。
/// 操作数非 str 时返回 false（Eq/Le/Ge）或按 Ord 语义不 panic 地返回 false。
/// 使用 GlueStr.compare（Ordering）避免重复分配。
fn str_compare_operands(frame: &mut Frame, node: NodeId) -> Option<std::cmp::Ordering> {
    read_node_inputs!(frame, node, graph, n, inputs);
    let lhs = frame.get_value_by_global(inputs[0]);
    let rhs = frame.get_value_by_global(inputs[1]);
    match (lhs.heap_obj(), rhs.heap_obj()) {
        (Some(crate::Value::HeapObj::Str(a)), Some(crate::Value::HeapObj::Str(b))) => {
            Some(a.compare(b))
        }
        _ => None,
    }
}

pub fn compute_eq_str(frame: &mut Frame, node: NodeId) -> Value {
    Value::bool_val(str_compare_operands(frame, node) == Some(std::cmp::Ordering::Equal))
}

pub fn compute_ne_str(frame: &mut Frame, node: NodeId) -> Value {
    Value::bool_val(str_compare_operands(frame, node) != Some(std::cmp::Ordering::Equal))
}

pub fn compute_lt_str(frame: &mut Frame, node: NodeId) -> Value {
    Value::bool_val(str_compare_operands(frame, node) == Some(std::cmp::Ordering::Less))
}

pub fn compute_gt_str(frame: &mut Frame, node: NodeId) -> Value {
    Value::bool_val(str_compare_operands(frame, node) == Some(std::cmp::Ordering::Greater))
}

pub fn compute_le_str(frame: &mut Frame, node: NodeId) -> Value {
    Value::bool_val(matches!(str_compare_operands(frame, node), Some(std::cmp::Ordering::Less) | Some(std::cmp::Ordering::Equal)))
}

pub fn compute_ge_str(frame: &mut Frame, node: NodeId) -> Value {
    Value::bool_val(matches!(str_compare_operands(frame, node), Some(std::cmp::Ordering::Greater) | Some(std::cmp::Ordering::Equal)))
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
        Value::Null => TYPE_NAME_NULL.to_string(),
        Value::Void => TYPE_NAME_VOID.to_string(),
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

    let target_tag = match ScalarTag::from_name(target_ty) {
        Some(tag) => tag,
        // 未知目标类型：safe cast 返回 Null，否则返回 Void
        None => {
            return if graph.safe_op_flags[node.0 as usize] {
                Value::Null
            } else {
                Value::VOID
            };
        }
    };

    // 源值是否为浮点
    let src_is_float = matches!(
        &val,
        Value::Scalar(_, ScalarTag::F16 | ScalarTag::F32 | ScalarTag::F64 | ScalarTag::F128)
    );
    // 统一读取源值为 f64：浮点用 as_float_f64，整数用 as_int_i128 as f64
    let src_f64 = if src_is_float { val.as_float_f64() } else { val.as_int_i128() as f64 };

    match target_tag {
        ScalarTag::I8 => Value::i8(if src_is_float { src_f64 as i8 } else { val.as_i8() }),
        ScalarTag::I16 => Value::i16(if src_is_float { src_f64 as i16 } else { val.as_i16() }),
        ScalarTag::I32 => Value::i32(if src_is_float { src_f64 as i32 } else { val.as_i32() }),
        ScalarTag::I64 => Value::i64(if src_is_float { src_f64 as i64 } else { val.as_i64() }),
        ScalarTag::I128 => Value::i128(if src_is_float { src_f64 as i128 } else { val.as_i128() }),
        ScalarTag::U8 => Value::u8(if src_is_float { src_f64 as u8 } else { val.as_u8() }),
        ScalarTag::U16 => Value::u16(if src_is_float { src_f64 as u16 } else { val.as_u16() }),
        ScalarTag::U32 => Value::u32(if src_is_float { src_f64 as u32 } else { val.as_u32() }),
        ScalarTag::U64 => Value::u64(if src_is_float { src_f64 as u64 } else { val.as_u64() }),
        ScalarTag::U128 => Value::u128(if src_is_float { src_f64 as u128 } else { val.as_u128() }),
        ScalarTag::Isize => Value::isize_val(if src_is_float { src_f64 as isize } else { val.as_isize() }),
        ScalarTag::Usize => Value::usize_val(if src_is_float { src_f64 as usize } else { val.as_usize() }),
        ScalarTag::F16 => Value::f16(crate::Value::F16::from_f64(src_f64)),
        ScalarTag::F32 => Value::f32(src_f64 as f32),
        ScalarTag::F64 => Value::f64(src_f64),
        ScalarTag::F128 => Value::f128(crate::Value::F128::from_f64(src_f64)),
        ScalarTag::Bool => Value::bool_val(if src_is_float { src_f64 != 0.0 } else { val.as_int_i128() != 0 }),
        ScalarTag::Char => Value::char_val(char_from_u32_or_nul(if src_is_float { src_f64 as u32 } else { val.as_int_i128() as u32 })),
    }
}

/// compute_fn (idx 279): 非空断言 `expr!`。
///
/// 输入为 nullable 值：Null → panic（编程错误，非可恢复流程）；
/// 非 Null → 原样返回（Scalar/Ref 透传，即解包 nullable）。
pub fn compute_non_null_assert(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let v = frame.get_value_by_global(inputs[0]);
    if v.is_null() {
        panic!("non-null assertion failed: value is null");
    }
    v
}

/// compute_fn (idx 280): 取引用 `&expr`（RefOf）。
///
/// 将输入值包装进 `Arc<HeapObj::Cell>`，返回 `Value::Ref(arc)`。
/// 多个引用共享同一 Cell（通过 Arc clone），写入对所有人可见。
/// 对于已是 Ref 的值（record 等），直接共享同一 Arc（无需二次包装）。
pub fn compute_ref_of(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let v = frame.get_value_by_global(inputs[0]);
    match &v {
        // 标量/Null/Void → 包装进 Cell
        Value::Scalar(_, _) | Value::Null | Value::Void => {
            let cell = crate::Value::Cell::new(v.clone());
            Value::ref_val(crate::Value::HeapObj::Cell(cell))
        }
        // 已是堆引用：直接共享 Arc（引用语义，不深拷贝）
        Value::Ref(_) => v,
    }
}

/// compute_fn (idx 281): 解引用读取 `*ref`（Deref）。
///
/// 输入为 `Arc<HeapObj::Cell>`：返回 Cell 内部值。
/// 输入为其他 Ref（record/array 等）：原样返回（`&rec` 共享 Arc，`*r` 即 rec 本身）。
pub fn compute_deref_read(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let v = frame.get_value_by_global(inputs[0]);
    match v.heap_obj() {
        Some(crate::Value::HeapObj::Cell(c)) => c.get(),
        _ => v,
    }
}

/// compute_fn (idx 282): 解引用写入 `*ref = value`（DerefAssign）。
///
/// inputs[0] = 引用（Cell），inputs[1] = 新值。
/// 将新值写入 Cell，返回写入的值（供链式使用）。
/// 对非 Cell 引用（record 共享 Arc）不做处理（record 字段写入走 record_field_set）。
pub fn compute_deref_write(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let ref_val = frame.get_value_by_global(inputs[0]);
    let new_val = frame.get_value_by_global(inputs[1]);
    if let Some(crate::Value::HeapObj::Cell(c)) = ref_val.heap_obj() {
        c.set(new_val.clone());
    }
    new_val
}


/// compute_fn: 记录字段赋值（就地修改 RecordValue 的字段，返回 void）
///
/// inputs[0] = 记录值节点，inputs[1] = 新值。
/// 字段名从 graph.field_set_names[node] 获取，通过 Arc::make_mut 就地修改。
/// 修改后写回值表槽，使变更对其他节点可见。
pub fn compute_record_field_set(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let new_value = frame.get_value_by_global(inputs[1]);
    let field_name = graph.field_set_names[node.0 as usize]
        .as_ref()
        .expect("field set node has no field name");
    let record_node_local = NodeId(inputs[0].0.wrapping_sub(frame.node_offset));
    // &self 语义：直接修改 Arc 底层 HeapObj，确保修改对所有持有者可见。
    // 这对迭代器模式（next() 修改 self.pos）等场景至关重要：
    // for 循环通过尾递归传递迭代器引用，若 COW 则 pos 永不更新 → 死循环。
    //
    // Arc::make_mut 在 refcount>1 时 COW，破坏 &self 引用语义。
    // 此处通过 Arc::as_ptr 获取可变指针直接修改，绕过 Rust 别名规则。
    //
    // Safety: 引擎单线程执行（LockStrategy::Single 无锁，Multi 在帧级别互斥），
    // caller 帧在 callee 执行期间处于 Suspended 状态，不会有并发访问同一 HeapObj。
    // Arc 的引用计数不变（不 clone 也不 drop），仅修改堆数据。
    if let Some(val) = frame.value_table.get_value_mut(record_node_local.0 as usize) {
        if let Value::Ref(arc) = val {
            let ptr = std::sync::Arc::as_ptr(arc) as *mut crate::Value::HeapObj;
            unsafe {
                match &mut *ptr {
                    crate::Value::HeapObj::Record(r) => {
                        if let Some(idx) = r.field_names.iter().position(|n| n.as_deref() == Some(field_name.as_str())) {
                            if idx < r.fields.len() {
                                r.fields[idx] = new_value.clone();
                            }
                        }
                    }
                    crate::Value::HeapObj::Adt(a) => {
                        if let Some(idx) = a.fields.iter().position(|f| f.name.as_deref() == Some(field_name.as_str())) {
                            a.fields[idx].value = new_value.clone();
                        }
                    }
                    _ => {}
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

/// compute_fn: 长度（返回 i32，与默认整数运算类型一致）
/// - Array：元素个数
/// - Str：Unicode 码点数（与 str[i] 索引语义一致，均按码点计数）
pub fn compute_array_len(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let val = frame.get_value_by_global(inputs[0]);
    let len = match val.heap_obj() {
        Some(crate::Value::HeapObj::Array(arr)) => arr.len() as i32,
        Some(crate::Value::HeapObj::Str(s)) => s.codepoint_count() as i32,
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

/// compute_fn: 复合类型（record/adt/newtype/array/closure/throw 等）语义相等。
/// 对 Ref 走 heap_equals 深度比较；对标量/Null/Void 回退到 value_equals。
pub fn compute_eq_obj(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let lhs = frame.get_value_by_global(inputs[0]);
    let rhs = frame.get_value_by_global(inputs[1]);
    let eq = crate::Value::ValueArena::with_global(|arena| {
        crate::Value::value_equals_with_arena(&lhs, &rhs, arena)
    });
    Value::bool_val(eq)
}

/// compute_fn: 复合类型语义不等，compute_eq_obj 的否定。
pub fn compute_ne_obj(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let lhs = frame.get_value_by_global(inputs[0]);
    let rhs = frame.get_value_by_global(inputs[1]);
    let neq = crate::Value::ValueArena::with_global(|arena| {
        !crate::Value::value_equals_with_arena(&lhs, &rhs, arena)
    });
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

        frame.pending = Some(Pending::Call(PendingCall {
            target_sg,
            args,
            call_node_local,
            is_async: false,
            closure_val: None,
        }));
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
    let cond_raw = frame.get_value_by_global(branches.condition_input);
    let cond = cond_raw.as_bool();

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

    frame.pending = Some(Pending::Call(PendingCall {
        target_sg,
        args,
        call_node_local: gate_node_local,
        is_async: false,
        closure_val: None,
    }));

    Value::VOID
}

/// compute_await（idx 38）：await 节点执行时设置 frame.pending_await。
///
/// spec 4.4：事件源未就绪 → await 未就绪 → 帧无更多就绪节点 → 挂起。
/// compute_await 无法访问 Engine 运行时，只设置 pending_await，
/// 核心循环消费后解析事件源 → 检查就绪 → 就绪则注入值继续 → 未就绪则挂起。
pub fn compute_await(frame: &mut Frame, node: NodeId) -> Value {
    use crate::ir::Ir::PendingAwait;

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
            .unwrap_or(crate::ir::Ir::EventSourceKind::AsyncJoin),
        None => crate::ir::Ir::EventSourceKind::AsyncJoin,
    };

    frame.pending = Some(Pending::Await(PendingAwait {
        await_node_local,
        event_obj,
        event_kind,
    }));

    Value::VOID
}

/// compute_channel_create（idx 283）：创建 ChannelValue 堆对象。
///
/// 输入：inputs[0] = capacity (usize)
/// 输出：Value::ref_val(HeapObj::ChannelVal(Arc<ChannelValue>))
pub fn compute_channel_create(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let capacity = frame.get_value_by_global(inputs[0]).as_usize();
    Value::ref_val(crate::Value::HeapObj::ChannelVal(
        std::sync::Arc::new(crate::Value::ChannelValue::new(capacity)),
    ))
}

/// compute_channel_send（idx 284）：非阻塞发送 + 设置 pending_channel_notify。
///
/// 输入：inputs[0] = channel ref, inputs[1] = value
/// 发送后设置 pending_channel_notify，run_ready_nodes 消费时触发 ChannelReady 事件
/// 唤醒等待该 channel 的挂起帧（内联触发，零延迟）。
pub fn compute_channel_send(frame: &mut Frame, node: NodeId) -> Value {
    use std::sync::Arc;
    use crate::Value::{HeapObj, RecordValue, ThrowValue, ThrowPayload};
    read_node_inputs!(frame, node, graph, n, inputs);
    let ch_val = frame.get_value_by_global(inputs[0]);
    let val = frame.get_value_by_global(inputs[1]);
    let make_err = |msg: &str| {
        let record = Arc::new(RecordValue {
            type_name: "ChannelError".to_string(),
            fields: vec![Value::ref_val(HeapObj::Str(crate::Value::GlueStr::new(msg)))],
            field_names: vec![Some("message".to_string())],
            field_ref_bits: 1,
        });
        Value::ref_val(HeapObj::ThrowVal(ThrowValue { payload: ThrowPayload::Err(record) }))
    };
    let ch = match ch_val.heap_obj().and_then(|h| h.channel()) {
        Some(ch) => ch,
        None => return make_err("send on non-channel value"),
    };
    match ch.send(val) {
        Ok(()) => {
            let ch_id = crate::ir::Ir::ChannelId(ch.id());
            frame.pending = Some(Pending::ChannelNotify(ch_id));
            Value::VOID
        }
        Err(e) => make_err(e.message()),
    }
}

/// compute_channel_close（idx 285）：关闭 channel。
///
/// 输入：inputs[0] = channel ref
pub fn compute_channel_close(frame: &mut Frame, node: NodeId) -> Value {
    read_node_inputs!(frame, node, graph, n, inputs);
    let ch_val = frame.get_value_by_global(inputs[0]);
    let ch = ch_val.heap_obj().and_then(|h| h.channel())
        .expect("close on non-channel value");
    ch.close();
    Value::VOID
}

/// compute_async_call_launch（idx 39）：async 函数调用，启动子帧但不挂起当前帧。
///
/// 与 compute_call_launch 相同参数收集逻辑，但 is_async=true。
/// 核心循环检测 is_async=true 后：启动子帧 + call 节点写 AsyncHandle + 通知下游 + 不挂起。
pub fn compute_async_call_launch(frame: &mut Frame, node: NodeId) -> Value {
    use crate::ir::Ir::PendingCall;

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

    frame.pending = Some(Pending::Call(PendingCall {
        target_sg,
        args,
        call_node_local,
        is_async: true,
        closure_val: None,
    }));

    Value::VOID
}

/// compute_fn: 闭包构造（idx 40）。
///
/// 从 graph.closure_infos 取子图 id + arity，合并 inputs（捕获值）构造 Closure 堆对象。
/// 节点的 inputs 即捕获的 upvalues（按 compile_lambda 中 captured 顺序）。
pub fn compute_closure_construct(frame: &mut Frame, node: NodeId) -> Value {
    use crate::Value::{HeapObj, Closure, Cell};
    read_node_inputs!(frame, node, graph, n, inputs);
    let info = graph.closure_infos[node.0 as usize]
        .expect("closure construct node has no ClosureInfo");
    // 用 Cell 包装每个 upvalue，使逃逸闭包（跨函数调用）能通过 Cell
    // 的 interior mutability 持久化 upvalue 修改。
    // same_function 调用不使用 Cell（直接从父帧读最新值）。
    let upvalues: Vec<Value> = inputs
        .iter()
        .map(|&in_node| frame.get_value_by_global(in_node))
        .map(|v| Value::ref_val(HeapObj::Cell(Cell::new(v))))
        .collect();
    let cell_bits = if upvalues.len() >= 8 { 0xFF } else { (1u8 << upvalues.len()) - 1 };
    Value::ref_val(HeapObj::Closure(Closure {
        func_id: info.subgraph_id.0,
        arity: info.arity,
        upvalues,
        bound_args: Vec::new(),
        self_upvalue_idx: info.self_upvalue_idx,
        upvalue_ref_bits: 0,
        cell_upvalues: cell_bits,
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
/// 此函数在 compute_reflect_format / compute_reflect_scalar_to_str 中调用，
/// 用于在格式化前强制求值 lazy 值。
pub fn force_lazy_value_sync(caller_frame: &mut Frame, lazy_val: &Value) -> Value {
    use crate::Value::HeapObj;

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
    let mut thunk_frame = Frame::new(THUNK_FRAME_ID, thunk_sg, node_count, graph.clone());
    prepare_frame_nodes(&mut thunk_frame, &graph);

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
/// - 帧内节点按就绪队列调度执行
/// - 遇到 Call 节点时递归调用 run_frame_sync 执行子帧
/// - 控制信号（return/break/continue）终止循环
///
/// defer 执行：帧完成后（任何终止路径），按 LIFO 顺序执行 defer_table 中的
/// defer body 子图。defer body 通过递归 run_frame_sync 执行（支持嵌套 defer）。
fn run_frame_sync(frame: &mut Frame, graph: &DataFlowGraph) -> Value {
    let result = run_frame_sync_inner(frame, graph);
    // 执行 defer（LIFO）：任何终止路径都执行 defer
    run_defers_sync(frame, graph);
    result
}

/// 执行帧的 defer_table 中的 defer body（LIFO 顺序）。
/// defer body 是独立子图，创建新帧并通过 run_frame_sync 同步执行。
fn run_defers_sync(frame: &mut Frame, graph: &DataFlowGraph) {
    let sg_id = frame.subgraph_id;
    let defer_entries: Vec<crate::ir::Ir::DeferEntry> =
        graph.subgraphs[sg_id.0 as usize].defer_table.clone();
    for entry in defer_entries.iter().rev() {
        let (dn_start, dn_end) = graph.subgraphs[entry.body_subgraph.0 as usize].node_range;
        let dn_count = (dn_end.0 - dn_start.0) as usize;
        let mut defer_frame = Frame::new(
            FrameId(u32::MAX),
            entry.body_subgraph,
            dn_count,
            frame.graph.clone(),
        );
        prepare_frame_nodes(&mut defer_frame, graph);
        let _ = run_frame_sync(&mut defer_frame, graph);
    }
}

/// run_frame_sync 的内部实现（不执行 defer）。
///
/// - 弹出就绪节点 → 调用 compute_fn → 处理 pending_call/control_signal
/// - pending_call：递归创建子帧 + 同步执行 + 注入返回值
/// - control_signal：Return 直接返回，Break/Continue 传播
///
/// 不支持：async/await、channel/timer 事件、select、循环体复用。
/// 适用于 thunk 子图（纯计算 + 同步函数调用）。
fn run_frame_sync_inner(frame: &mut Frame, graph: &DataFlowGraph) -> Value {
    use crate::ir::Ir::{ControlSignal, LoopKind, NodeKind, PendingCall, SignalKind, SubGraphId};

    let mut iter_guard: u64 = 0;
    loop {
        iter_guard += 1;
        if iter_guard > 100000 {
            return Value::VOID;
        }
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

        // 3. 执行 compute_fn（safe_op 标记：inputs[0] 为 Null 时短路返回 Null）
        let pre_filled = frame.value_table.ready[local_id.0 as usize];
        let value = if pre_filled {
            frame.value_table.values[local_id.0 as usize].clone()
        } else if graph.safe_op_flags[graph_node_id.0 as usize] {
            let inputs = graph.inputs_pool.get(node.inputs_offset, node.input_count);
            if !inputs.is_empty() && matches!(frame.get_value_by_global(inputs[0]), Value::Null) {
                Value::Null
            } else {
                let compute_fn = graph.compute_fns[node.compute_fn.0 as usize];
                compute_fn(frame, graph_node_id)
            }
        } else {
            let compute_fn = graph.compute_fns[node.compute_fn.0 as usize];
            compute_fn(frame, graph_node_id)
        };
        // 4. vtable 动态分派（Call 节点有 vtable_call_methods 但无 call_target）
        if frame.pending.is_none() {
            if let Some(method_idx) = graph.vtable_call_methods[graph_node_id.0 as usize] {
                let n = &graph.nodes[graph_node_id.0 as usize];
                let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                let recv_val = frame.get_value_by_global(inputs[0]);

                let (target_sg, upvalues): (SubGraphId, Vec<Value>) = match recv_val.heap_obj() {
                    Some(crate::Value::HeapObj::TraitVal(tv)) => {
                        let idx = method_idx as usize;
                        match tv.method_values.get(idx).and_then(|v| v.heap_obj()) {
                            Some(crate::Value::HeapObj::Closure(c)) => {
                                (SubGraphId(c.func_id), c.upvalues.clone())
                            }
                            _ => panic!("vtable method_idx {} is not a Closure", method_idx),
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
                frame.pending = Some(Pending::Call(PendingCall {
                    target_sg,
                    args,
                    call_node_local,
                    is_async: false,
                    closure_val: None,
                }));
            }
        }

        // 5. 处理 pending_call
        let pending = frame.pending.clone();
        if let Some(Pending::Call(pending)) = pending {
            frame.pending = None;

            // 尾调用：复用当前帧
            if graph.tail_call_flags[graph_node_id.0 as usize] {
                switch_subgraph(frame, graph, pending.target_sg, &pending.args);
                continue;
            }

            let target_loop_kind = graph.subgraphs[pending.target_sg.0 as usize].loop_kind;

            // LoopBody：不支持循环体复用（thunk 不应有循环），回退为普通调用
            let (child_start, child_end) = graph.subgraphs[pending.target_sg.0 as usize].node_range;
            let child_count = (child_end.0 - child_start.0) as usize;
            let mut child_frame = Frame::new(
                LOOPBODY_FALLBACK_FRAME_ID,
                pending.target_sg,
                child_count,
                frame.graph.clone(),
            );
            prepare_frame_nodes(&mut child_frame, graph);

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
            child_frame.closure_val = pending.closure_val.clone();

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
                        notify_downstream(
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

            notify_downstream(frame, graph, pending.call_node_local, graph_node_id, NodeId(node_start));
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

            notify_downstream(frame, graph, local_id, graph_node_id, NodeId(node_start));
        }
    }
}

/// compute_fn: 偏应用构造（idx 286）。
///
/// 从 partial_infos 取子图 id + bound_count，合并 inputs（已绑定参数值）
/// 构造 HeapObj::Partial。remaining_arity = subgraph.param_count - bound_count。
/// 顶层函数偏应用时 upvalues 为空，self_upvalue_idx = -1。
pub fn compute_partial_construct(frame: &mut Frame, node: NodeId) -> Value {
    use crate::Value::{HeapObj, PartialApplication};
    read_node_inputs!(frame, node, graph, n, inputs);
    let info = graph.partial_infos[node.0 as usize]
        .expect("partial construct node has no PartialInfo");
    let bound_args: Vec<Value> = inputs
        .iter()
        .map(|&in_node| frame.get_value_by_global(in_node))
        .collect();
    let param_count = graph.subgraphs[info.subgraph_id.0 as usize].param_count as usize;
    let remaining_arity = param_count.saturating_sub(bound_args.len()) as u8;
    Value::ref_val(HeapObj::Partial(PartialApplication {
        func_id: info.subgraph_id.0,
        upvalues: Vec::new(),
        bound_args,
        remaining_arity,
        self_upvalue_idx: -1,
    }))
}

/// compute_str_bytes（idx 287）：str.bytes() → u8[]
/// 将 GlueStr 的 UTF-8 字节序列构造为 u8 数组。
pub fn compute_str_bytes(frame: &mut Frame, node: NodeId) -> Value {
    use crate::Value::{HeapObj, ArrayValue};
    read_node_inputs!(frame, node, graph, n, inputs);
    let val = frame.get_value_by_global(inputs[0]);
    let bytes: Vec<Value> = match val.heap_obj() {
        Some(HeapObj::Str(s)) => s.bytes().as_bytes()
            .iter()
            .map(|&b| Value::u8(b))
            .collect(),
        _ => Vec::new(),
    };
    Value::ref_val(HeapObj::Array(ArrayValue::new(bytes)))
}

/// compute_fn: 可调用值调用（idx 41）— 统一处理 Closure | Partial。
///
/// inputs[0] = 可调用值节点，inputs[1..1+arg_count] = 调用参数节点（arg_count 从
/// closure_call_arg_counts 元数据读取，不含闭包值和 effect 依赖）。
///
/// 统一调用语义：
/// - Closure: needed_arity = subgraph.param_count - upvalues.len()
/// - Partial: needed_arity = remaining_arity
///
/// 当新参数数 < needed_arity → 产出新的 Partial（链式偏应用）；
/// 当新参数数 >= needed_arity → 合并 bound_args + 新参数 + upvalues，设 pending_call。
/// 解包 Cell 包装的 upvalue：若值是 Cell 则返回内部值的克隆，否则原样克隆。
/// 用于 compute_closure_call 将 Cell upvalues 转为原始值注入子帧参数。
fn unwrap_cell(v: &Value) -> Value {
    match v.heap_obj() {
        Some(crate::Value::HeapObj::Cell(cell)) => cell.get(),
        _ => v.clone(),
    }
}

pub fn compute_closure_call(frame: &mut Frame, node: NodeId) -> Value {
    use crate::Value::{HeapObj, PartialApplication};
    read_node_inputs!(frame, node, graph, n, inputs);
    let callable_val = frame.get_value_by_global(inputs[0]);

    // 从元数据读取实参数（不含闭包值和 effect 依赖）
    let arg_count = graph.closure_call_arg_counts[node.0 as usize]
        .expect("closure_call node has no arg_count") as usize;
    let new_args: Vec<Value> = inputs
        .iter()
        .skip(1)
        .take(arg_count)
        .map(|&in_node| frame.get_value_by_global(in_node))
        .collect();

    // 统一提取可调用值的启动信息
    let (func_id, upvalues, bound_args, needed_arity, self_upvalue_idx) = match callable_val.heap_obj() {
        Some(HeapObj::Closure(c)) => {
            let total_params = graph.subgraphs[c.func_id as usize].param_count as usize;
            let needed = total_params.saturating_sub(c.upvalues.len());
            // 解包 Cell upvalues 为原始值注入参数（Cell 用于逃逸闭包的持久化回写）
            let upvalues: Vec<Value> = c.upvalues.iter().map(|v| unwrap_cell(v)).collect();
            (c.func_id, upvalues, Vec::new(), needed, c.self_upvalue_idx)
        }
        Some(HeapObj::Partial(p)) => {
            let upvalues: Vec<Value> = p.upvalues.iter().map(|v| unwrap_cell(v)).collect();
            (p.func_id, upvalues, p.bound_args.clone(), p.remaining_arity as usize, p.self_upvalue_idx)
        }
        _ => panic!("compute_closure_call: input is not callable (Closure or Partial)"),
    };

    // 链式偏应用：新参数不足 → 产出新 Partial
    if new_args.len() < needed_arity {
        let provided = new_args.len();
        let mut extended = bound_args;
        extended.extend(new_args);
        let new_remaining = needed_arity - provided;
        return Value::ref_val(HeapObj::Partial(PartialApplication {
            func_id,
            upvalues,
            bound_args: extended,
            remaining_arity: new_remaining as u8,
            self_upvalue_idx,
        }));
    }

    // 满 arity：合并 bound_args + new_args[..needed] + upvalues，设 pending_call
    let target_sg = SubGraphId(func_id);
    let call_node_local = NodeId(node.0.wrapping_sub(frame.node_offset));
    let upvalues_len = upvalues.len();
    let mut args: Vec<Value> = Vec::with_capacity(bound_args.len() + needed_arity + upvalues_len);
    args.extend(bound_args);
    args.extend(new_args.iter().take(needed_arity).cloned());
    args.extend(upvalues);

    // 递归闭包：将自身引用注入到 self_upvalue_idx 对应的 upvalue slot
    if self_upvalue_idx >= 0 {
        let upvalues_start = args.len() - upvalues_len;
        let self_idx = upvalues_start + self_upvalue_idx as usize;
        args[self_idx] = callable_val.clone();
    }

    frame.pending = Some(Pending::Call(PendingCall {
        target_sg,
        args,
        call_node_local,
        is_async: false,
        closure_val: Some(callable_val.clone()),
    }));

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
    let async_id = crate::ir::Ir::AsyncHandleId(handle_val.as_i32() as u32);
    frame.pending = Some(Pending::Cancel(async_id));
    Value::VOID
}

/// compute_fn: select 门控节点（idx 43）— 检查所有分支事件源，选第一个就绪的。
///
/// compute_fn 无法访问 Engine 的 timer_runtime，因此这里只标记
/// `pending_select_wait`，由 `run_ready_nodes` 检查就绪状态（它能访问 Engine 全部状态）。
pub fn compute_select_gate(frame: &mut Frame, node: NodeId) -> Value {
    let graph = frame.graph.clone();
    // 校验 gate 节点确实绑定了 SelectInfo
    let _ = graph.select_infos[node.0 as usize]
        .as_ref()
        .expect("select gate node has no SelectInfo");
    let gate_local = NodeId(node.0.wrapping_sub(frame.node_offset));
    frame.pending = Some(Pending::SelectWait(gate_local));
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
    if n.input_count == 0 {
        return Value::VOID;
    }
    frame.get_value_by_global(inputs[n.input_count as usize - 1])
}

/// compute_writeback（idx 49）：赋值外层变量，通过 root_frame_ptr 写回函数根帧。
///
/// inputs[0] = 值来源（当前帧内节点），writeback_targets[node] = 外层全局 NodeId。
/// 非阻塞：compute_fn 内直接完成写入，无 pending、无 Engine 层消费。
///
/// 三条回写路径（按优先级）：
/// 1. parent_frame_ptr 链：同函数闭包调用，写入最近的包含 target 的父帧
/// 2. root_frame_ptr：同函数闭包调用，写入函数根帧（使其他 same_function 调用可见）
/// 3. closure_val Cell：逃逸闭包（跨函数调用，帧链为 null），通过 Cell 的 interior
///    mutability 更新闭包 upvalues，使下次调用能读到最新值
pub fn compute_writeback(frame: &mut Frame, node: NodeId) -> Value {
    let graph = frame.graph.clone();
    let n = &graph.nodes[node.0 as usize];
    if n.input_count == 0 {
        return Value::VOID;
    }
    let val_node = graph.inputs_pool.get(n.inputs_offset, n.input_count)[0];
    let val = frame.get_value_by_global(val_node);
    let target = graph.writeback_targets[node.0 as usize]
        .expect("WriteBack node missing target");
    let consumer_count = graph.downstreams[target.0 as usize].len() as u16;

    // 路径 1：遍历 parent_frame_ptr 链，写入第一个包含 target 的帧（最近的父帧）。
    // SAFETY: parent_frame_ptr 指向同函数帧（setup_frame_chain 设置），
    // caller 帧在 callee 执行期间处于 Suspended 状态，无并发访问。
    let mut written_parent = false;
    let mut ptr = frame.parent_frame_ptr;
    while !ptr.is_null() {
        let f = unsafe { &mut *ptr };
        let local = target.0.wrapping_sub(f.node_offset);
        if (local as usize) < f.value_table.len() {
            f.set_value(NodeId(local), val.clone(), consumer_count);
            written_parent = true;
            break;
        }
        ptr = f.parent_frame_ptr;
    }

    // 路径 2：写入 root_frame_ptr（函数根帧），使同函数闭包调用能从根帧读到最新值。
    if !frame.root_frame_ptr.is_null() {
        let root = unsafe { &mut *frame.root_frame_ptr };
        let local = target.0.wrapping_sub(root.node_offset);
        if (local as usize) < root.value_table.len() {
            root.set_value(NodeId(local), val.clone(), consumer_count);
        } else {
            debug_assert!(false, "writeback target {:?} out of root frame range", target);
        }
    } else if !written_parent {
        // 路径 3：逃逸闭包（帧链为 null）— 通过 closure_val 的 Cell 回写 upvalue。
        // 逃逸闭包跨函数调用时，parent/root 均为 null，无法通过帧链回写。
        // closure_val 中的 upvalues 以 Cell 包装（compute_closure_construct），
        // 通过 Cell::set 持久化修改，使下次调用能读到最新值。
        let mut written_cell = false;
        if let Some(ref closure_val) = frame.closure_val {
            if let Value::Ref(arc) = closure_val {
                let upvalues: &[Value] = match arc.as_ref() {
                    crate::Value::HeapObj::Closure(c) => &c.upvalues,
                    crate::Value::HeapObj::Partial(p) => &p.upvalues,
                    _ => &[],
                };
                if !upvalues.is_empty() {
                    let sg = &frame.graph.subgraphs[frame.subgraph_id.0 as usize];
                    for (i, &outer_node) in sg.upvalue_outer_nodes.iter().enumerate() {
                        if outer_node == target && i < upvalues.len() {
                            if let Some(crate::Value::HeapObj::Cell(cell)) = upvalues[i].heap_obj() {
                                cell.set(val.clone());
                                written_cell = true;
                            }
                            break;
                        }
                    }
                }
            }
        }
        // 路径 4：非逃逸闭包的根帧场景（顶层函数内的赋值），写入当前帧
        if !written_cell {
            let local = target.0.wrapping_sub(frame.node_offset);
            if (local as usize) < frame.value_table.len() {
                frame.set_value(NodeId(local), val.clone(), consumer_count);
            } else {
                debug_assert!(false, "writeback target {:?} out of current frame range", target);
            }
        }
    }
    val
}


// =========================================================================
// TimerRuntime / AsyncJoinRuntime — 图外运行时
// =========================================================================

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
    pub fn start(&mut self, duration: std::time::Duration) -> crate::ir::Ir::TimerId {
        let id = crate::ir::Ir::TimerId(self.timers.len() as u32);
        self.timers.push(TimerEntry {
            deadline: std::time::Instant::now() + duration,
            fired: false,
        });
        id
    }
    pub fn check_and_fire(&mut self) -> Vec<crate::ir::Ir::TimerId> {
        let now = std::time::Instant::now();
        let mut fired = Vec::new();
        for (i, t) in self.timers.iter_mut().enumerate() {
            if !t.fired && now >= t.deadline {
                t.fired = true;
                fired.push(crate::ir::Ir::TimerId(i as u32));
            }
        }
        fired
    }
    pub fn is_fired(&self, id: crate::ir::Ir::TimerId) -> bool {
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
    async_id: crate::ir::Ir::AsyncHandleId,
    child_fid: FrameId,
    result: Option<Value>,
}
impl AsyncJoinRuntime {
    pub fn new() -> Self { Self { entries: Vec::new(), next_async_id: 0 } }
    /// 分配新的 async_id（i32 标量值）
    pub fn alloc_id(&mut self) -> crate::ir::Ir::AsyncHandleId {
        assert!(self.next_async_id < u32::MAX, "AsyncHandleId overflow: too many async calls");
        let id = crate::ir::Ir::AsyncHandleId(self.next_async_id);
        self.next_async_id += 1;
        id
    }
    pub fn register(&mut self, async_id: crate::ir::Ir::AsyncHandleId, child_fid: FrameId) {
        self.entries.push(AsyncJoinEntry { async_id, child_fid, result: None });
    }
    /// 原子地分配 async_id 并注册 child_fid（消除 alloc_id + register 的竞态窗口）。
    pub fn alloc_and_register(&mut self, child_fid: FrameId) -> crate::ir::Ir::AsyncHandleId {
        let async_id = crate::ir::Ir::AsyncHandleId(self.next_async_id);
        self.next_async_id += 1;
        self.entries.push(AsyncJoinEntry { async_id, child_fid, result: None });
        async_id
    }
    pub fn find_by_child(&self, child_fid: FrameId) -> Option<crate::ir::Ir::AsyncHandleId> {
        // 仅匹配未完成（result=None）的 entry：帧 ID 会被复用，
        // 已完成的旧 entry 若仍匹配会导致新 async call 的完成事件被错误路由到旧 async_id。
        self.entries
            .iter()
            .find(|e| e.child_fid == child_fid && e.result.is_none())
            .map(|e| e.async_id)
    }
    pub fn find_child_by_async_id(&self, async_id: crate::ir::Ir::AsyncHandleId) -> Option<FrameId> {
        self.entries.iter().find(|e| e.async_id == async_id).map(|e| e.child_fid)
    }
    pub fn try_get_result(&self, async_id: crate::ir::Ir::AsyncHandleId) -> Option<Value> {
        self.entries.iter().find(|e| e.async_id == async_id).and_then(|e| e.result.clone())
    }
    pub fn set_result(&mut self, async_id: crate::ir::Ir::AsyncHandleId, value: Value) {
        if let Some(e) = self.entries.iter_mut().find(|e| e.async_id == async_id) {
            e.result = Some(value);
        }
    }
    /// 清理已完成且 result 已被读取的 entry，释放内存。
    /// 注意：AsyncHandleId 是 alloc_id 分配的递增值，不是 entries 索引，
    /// 所以移除 entry 不影响 ID 有效性。
    pub fn cleanup_consumed(&mut self, consumed_ids: &[crate::ir::Ir::AsyncHandleId]) {
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
// SIMD/rayon 批量化调度 — 模块级宏 + 自由函数
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
) -> bool {
    use crate::Value::{ScalarTag, BinOp, CmpOp, UnaryOp};
    let _ = (BinOp::Add, CmpOp::Eq, UnaryOp::Neg); // 抑制 unused import

    if locals.is_empty() { return false; }

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
                _ => return false, // F16/F128/Bool/Char → 不支持，回退到单节点路径
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
                _ => return false, // F16/F128/Bool/Char → 不支持，回退到单节点路径
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
                _ => return false, // F16/F128/F32/F64/Bool/Char → 不支持，回退到单节点路径
            }
        }
    }

    // 通知所有批处理节点的下游
    for &lid in locals {
        let gid = NodeId(lid.0 + node_start.0);
        notify_downstream(frame, graph, lid, gid, node_start);
    }
    true
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
        let batch_info = graph.batch_infos[gid.0 as usize];
        if let Some(info) = batch_info {
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
            let processed = process_batch_group(frame, graph, &locals, NodeId(node_start), info);
            if processed {
                batch_done = true;
            } else {
                // 批处理不支持此类型，节点回退到单节点路径
                for lid in locals {
                    rest.push(lid);
                }
            }
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
// 帧操作辅助函数（纯函数，不依赖 Engine 状态）
// =========================================================================

/// 将 ConstValue 转换为 Value（不使用 arena，直接构造）。
fn alloc_const_value(cv: ConstValue) -> Value {
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
        ConstValue::Char(c) => Value::char_val(char_from_u32_or_nul(c)),
        ConstValue::Null => Value::NULL,
        ConstValue::Void => Value::VOID,
        ConstValue::Str(s) => {
            use crate::Value::{HeapObj, GlueStr};
            Value::ref_val(HeapObj::Str(GlueStr::new(s)))
        }
    }
}

/// 帧节点初始化：设置 node_offset + pending_inputs + 预填充 Const + Gate 入就绪队列。
fn prepare_frame_nodes(frame: &mut Frame, graph: &DataFlowGraph) {
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

    // 1. 初始化 pending_inputs（select Gate→0；其他节点按实际 in-frame 输入计数）
    for i in 0..node_count {
        if is_nested((offset + i) as u32) {
            frame.pending_inputs[i] = PENDING_EXTERNAL;
        } else {
            let graph_node = &graph.nodes[offset + i];
            if graph_node.kind == NodeKind::EventSource {
                frame.pending_inputs[i] = PENDING_EXTERNAL;
            } else if graph_node.kind == NodeKind::Gate
                && graph.select_infos[offset + i].is_some()
            {
                frame.pending_inputs[i] = 0;
            } else {
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
                let handle = alloc_const_value(cv);
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

/// 通知下游节点：减 pending_inputs，归零则入就绪队列（含边界检查 + 槽级 RC）。
fn notify_downstream(
    frame: &mut Frame,
    graph: &DataFlowGraph,
    producer_local: NodeId,
    producer_graph: NodeId,
    node_start: NodeId,
) {
    let downstreams: Vec<NodeId> = graph.downstreams[producer_graph.0 as usize].clone();
    let pending_len = frame.pending_inputs.len();
    for ds_graph_id in downstreams {
        let ds_local_id = NodeId(ds_graph_id.0.wrapping_sub(node_start.0));
        // 边界检查：跳过跨子图下游
        if ds_local_id.0 as usize >= pending_len {
            continue;
        }

        let pidx = producer_local.0 as usize;
        // 消费 producer 的引用计数，但不清除 ready 标记。
        // ready 标记的语义是"此节点已产出值，不需要重新执行"。
        // 清除 ready 会导致节点变成 pending_inputs=0 && ready=false 状态，
        // 当上游被重新触发时，节点会被重新推入 ready_queue 并重复执行，
        // 造成指数级爆炸（尤其影响 call/closure_call 节点）。
        // 值保留在 value_table 中，直到帧结束（帧 drop 时自动释放）
        // 或被 reset_node_ready/reset_node_pending 显式重置（循环体复用场景）。
        let _still_has_consumers = frame.value_table.consume(pidx);

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

/// 尾调用图跳转：复用当前帧执行目标子图（帧池零分配）。
fn switch_subgraph(frame: &mut Frame, graph: &DataFlowGraph, target_sg: SubGraphId, args: &[Value]) {
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

    // 清空 value_table（prepare_frame_nodes 不做此操作）
    frame.value_table.reset_all();
    frame.ready_queue.clear();
    frame.control_signal = ControlSignal::None;
    frame.pending = None;
    frame.body_frame_id = None;
    frame.defer_stack.clear();
    frame.select_timers.clear();
    frame.root_frame_ptr = std::ptr::null_mut();
    frame.parent_frame_ptr = std::ptr::null_mut();
    frame.state = FrameState::Ready;
    frame.suspend_state = SuspendState::NotSuspended;
    frame.suspend_event = None;
    // caller 保持不变：返回值直达原始调用方的 call 节点

    // prepare_frame_nodes：设置 node_offset + pending_inputs + Const 预填充
    prepare_frame_nodes(frame, graph);

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
fn extract_child_return(child: &Frame, graph: &DataFlowGraph) -> Value {
    match &child.control_signal {
        ControlSignal::Return(v) => v.clone(),
        ControlSignal::Break | ControlSignal::Continue => Value::VOID,
        ControlSignal::None => {
            let sg = &graph.subgraphs[child.subgraph_id.0 as usize];
            // node_offset = 子图 node_range.0（同函数分支和跨函数调用均如此）
            let return_local = NodeId(sg.return_node.0.wrapping_sub(child.node_offset));
            child.get_value(return_local)
        }
    }
}

// =========================================================================
// LockStrategy — 编译期锁策略（单线程 RefCell vs 多线程 ParkingMutex）
// =========================================================================

/// 锁策略：编译期决定字段包装方式（单线程 RefCell vs 多线程 ParkingMutex）
pub trait LockStrategy: 'static {
    type Mutex<T>: Lockable<T>;
}

/// 可锁定 trait：提供 lock() 方法返回 guard
pub trait Lockable<T> {
    type Guard<'a>: DerefMut<Target = T>
    where
        Self: 'a;
    fn lock(&self) -> Self::Guard<'_>;
}

// 单线程策略：RefCell（borrow flag，~2ns，无系统调用）
pub struct Single;
impl LockStrategy for Single {
    type Mutex<T> = RefCell<T>;
}
impl<T> Lockable<T> for RefCell<T> {
    type Guard<'a>
        = RefMut<'a, T>
    where
        T: 'a;
    fn lock(&self) -> Self::Guard<'_> {
        self.borrow_mut()
    }
}

// 多线程策略：ParkingMutex（CAS，无竞争时 ~10ns）
pub struct Multi;
impl LockStrategy for Multi {
    type Mutex<T> = ParkingMutex<T>;
}
impl<T> Lockable<T> for ParkingMutex<T> {
    type Guard<'a>
        = ParkingMutexGuard<'a, T>
    where
        T: 'a;
    fn lock(&self) -> Self::Guard<'_> {
        self.lock()
    }
}

/// 帧队列抽象：Single 用 RefCell<VecDeque>，Multi 用 DequeWorker
pub enum QueueHandle<'a> {
    Single(&'a RefCell<std::collections::VecDeque<FrameId>>),
    Multi(&'a DequeWorker<FrameId>),
}
impl QueueHandle<'_> {
    pub fn push(&self, fid: FrameId) {
        match self {
            Self::Single(q) => q.borrow_mut().push_back(fid),
            Self::Multi(q) => q.push(fid),
        }
    }
}

// =========================================================================
// Engine<S> — 统一执行引擎（泛型锁策略）
// =========================================================================

/// 统一引擎：字段类型由 S 决定，业务逻辑只写一份
pub struct Engine<S: LockStrategy> {
    pub graph: Arc<DataFlowGraph>,
    pub frames: S::Mutex<HashMap<FrameId, Box<Frame>>>,
    pub next_frame_id: S::Mutex<FrameId>,
    pub arena: S::Mutex<ValueArena>,
    pub timer_runtime: S::Mutex<TimerRuntime>,
    pub async_join_runtime: S::Mutex<AsyncJoinRuntime>,
    pub event_waiters: S::Mutex<Vec<(crate::ir::Ir::RuntimeEvent, FrameId)>>,
    pub pending_completions:
        S::Mutex<HashMap<FrameId, (crate::ir::Ir::NodeId, Value, crate::ir::Ir::ControlSignal)>>,
    pub result: S::Mutex<Option<Value>>,
    /// 单线程队列（Multi 模式为 None）
    pub ready_frames: Option<RefCell<std::collections::VecDeque<FrameId>>>,
    /// 多线程调度（Single 模式为 None）
    pub global_queue: Option<Injector<FrameId>>,
    pub wakeup: Option<(ParkingMutex<()>, Condvar)>,
    pub active_count: Option<ParkingMutex<usize>>,
    _strategy: std::marker::PhantomData<S>,
}

// Safety: Frame 含裸指针（root_frame_ptr/parent_frame_ptr），但所有可变字段都在
// ParkingMutex 保护下，同一时刻只有一个线程访问每个字段。
unsafe impl Send for Engine<Multi> {}
unsafe impl Sync for Engine<Multi> {}

// =========================================================================
// impl<S: LockStrategy> Engine<S> — 合并后的统一方法
// =========================================================================

impl<S: LockStrategy> Engine<S> {
    /// 分配帧 id
    fn alloc_frame_id(&self) -> FrameId {
        let mut next = self.next_frame_id.lock();
        let id = *next;
        assert!(next.0 < u32::MAX, "FrameId overflow: too many frames allocated");
        next.0 += 1;
        id
    }

    /// 初始化帧：分配 + 预填充。返回 FrameId（帧已插入 frames）。
    fn init_frame(&self, subgraph_id: SubGraphId) -> FrameId {
        let (node_start, node_end) = self.graph.subgraphs[subgraph_id.0 as usize].node_range;
        let node_count = (node_end.0 - node_start.0) as usize;
        let fid = self.alloc_frame_id();
        let mut frame = Frame::new(fid, subgraph_id, node_count, self.graph.clone());
        self.prepare_frame(&mut frame);
        self.frames.lock().insert(fid, Box::new(frame));
        fid
    }

    /// 帧节点初始化：重置 + 预填充。
    fn prepare_frame(&self, frame: &mut Frame) {
        // 重置帧状态（帧复用时必须重置，避免旧值残留）
        frame.value_table.reset_all();
        frame.ready_queue.clear();
        frame.control_signal = ControlSignal::None;
        frame.pending = None;
        // 以下用 prepare_frame_nodes 设置 node_offset + pending_inputs + Const 预填充
        prepare_frame_nodes(frame, &self.graph);
    }

    /// 执行帧内所有就绪节点，直到就绪队列空或帧挂起。
    fn run_frame_nodes(&self, frame: &mut Frame, fid: FrameId, queue: &QueueHandle<'_>) {
        let graph = frame.graph.clone();

        let mut iter_guard: u64 = 0;
        loop {
        iter_guard += 1;
        if iter_guard > 500000 {
            return;
        }
            // 检查控制信号（return/break/continue 已触发）
            if !matches!(frame.control_signal, ControlSignal::None) {
                break;
            }
            // 检查帧是否被取消
            if frame.state == FrameState::Cancelling {
                break;
            }
            // 检查帧是否挂起
            if frame.state == FrameState::Suspended {
                return;
            }

            // SIMD/rayon 批量化
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
            } else if graph.safe_op_flags[graph_node_id.0 as usize] {
                let inputs = graph.inputs_pool.get(node.inputs_offset, node.input_count);
                if !inputs.is_empty() && matches!(frame.get_value_by_global(inputs[0]), Value::Null) {
                    Value::Null
                } else {
                    let compute_fn = graph.compute_fns[node.compute_fn.0 as usize];
                    compute_fn(frame, graph_node_id)
                }
            } else {
                let compute_fn = graph.compute_fns[node.compute_fn.0 as usize];
                compute_fn(frame, graph_node_id)
            };

            // vtable 动态分派
            if frame.pending.is_none() {
                if let Some(method_idx) = graph.vtable_call_methods[graph_node_id.0 as usize] {
                    let n = &graph.nodes[graph_node_id.0 as usize];
                    let inputs = graph.inputs_pool.get(n.inputs_offset, n.input_count);
                    let recv_val = frame.get_value_by_global(inputs[0]);

                    let (target_sg, upvalues): (crate::ir::Ir::SubGraphId, Vec<Value>) = match recv_val
                        .heap_obj()
                    {
                        Some(crate::Value::HeapObj::TraitVal(tv)) => {
                            let idx = method_idx as usize;
                            match tv.method_values.get(idx).and_then(|v| v.heap_obj()) {
                                Some(crate::Value::HeapObj::Closure(c)) => {
                                    (crate::ir::Ir::SubGraphId(c.func_id), c.upvalues.clone())
                                }
                                _ => panic!("vtable method_idx {} is not a Closure", method_idx),
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
                    frame.pending = Some(Pending::Call(PendingCall {
                        target_sg,
                        args,
                        call_node_local,
                        is_async: false,
                        closure_val: None,
                    }));
                }
            }

            // 统一消费 pending
            let pending = frame.pending.take();
            if let Some(pending) = pending {
                match pending {
                    crate::ir::Ir::Pending::Call(pending) => {
                        // 尾调用图跳转
                        let graph_call_id = NodeId(pending.call_node_local.0 + frame.node_offset);
                        if graph.tail_call_flags[graph_call_id.0 as usize] {
                            // 尾调用传播：从 frames 取出 caller 帧并 switch
                            let caller = frame.caller;
                            let propagate_to_parent =
                                if let Some((caller_fid, call_node)) = caller {
                                    let frames = self.frames.lock();
                                    if let Some(caller_frame) = frames.get(&caller_fid) {
                                        let caller_sg_id = caller_frame.subgraph_id;
                                        let caller_loop_kind =
                                            graph.subgraphs[caller_sg_id.0 as usize].loop_kind;
                                        let caller_has_caller = caller_frame.caller.is_some();
                                        let caller_offset = caller_frame.node_offset;
                                        let caller_graph_node =
                                            NodeId(call_node.0 + caller_offset);
                                        let caller_is_gate = graph.nodes[caller_graph_node.0
                                            as usize]
                                            .kind
                                            == NodeKind::Gate;
                                        caller_is_gate
                                            && caller_loop_kind != crate::ir::Ir::LoopKind::LoopBody
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
                                    let mut frames = self.frames.lock();
                                    frames.remove(&caller_fid).and_then(|cf| cf.caller)
                                };
                                self.event_waiters.lock().retain(|(_, f)| *f != caller_fid);
                                self.pending_completions.lock().remove(&caller_fid);
                                frame.caller = orig_caller;
                                switch_subgraph(
                                    frame,
                                    &graph,
                                    pending.target_sg,
                                    &pending.args,
                                );
                            } else {
                                switch_subgraph(
                                    frame,
                                    &graph,
                                    pending.target_sg,
                                    &pending.args,
                                );
                            }
                            continue;
                        }

                        // LoopBody 帧复用（从 Engine 版本移植）
                        let target_loop_kind =
                            graph.subgraphs[pending.target_sg.0 as usize].loop_kind;
                        let child_fid = if target_loop_kind
                            == crate::ir::Ir::LoopKind::LoopBody
                        {
                            if let Some(bfid) = frame.body_frame_id {
                                // 复用 body_sg 帧：注入参数 + 入就绪队列
                                let target_sg =
                                    &graph.subgraphs[pending.target_sg.0 as usize];
                                let param_count = target_sg.param_count as usize;
                                let mut body_frame = self.frames.lock().remove(&bfid);
                                if let Some(bf) = body_frame.as_mut() {
                                    // 使用 bf.node_offset 计算参数的本地索引：
                                    // 同函数分支帧的 node_offset 是父函数的 node_start，
                                    // 参数在值表中的位置 = branch_start - parent_start + i。
                                    // 跨函数调用时 param_local_offset=0，与原逻辑一致。
                                    let parent_start = bf.node_offset;
                                    let branch_start = target_sg.node_range.0 .0;
                                    let param_local_offset =
                                        (branch_start.wrapping_sub(parent_start)) as usize;
                                    for (i, arg) in
                                        pending.args.iter().enumerate().take(param_count)
                                    {
                                        let local_id =
                                            NodeId((param_local_offset + i) as u32);
                                        let gid = (branch_start as usize) + i;
                                        let consumer_count =
                                            graph.downstreams[gid].len() as u16;
                                        bf.set_value(local_id, arg.clone(), consumer_count);
                                        bf.push_ready(local_id);
                                    }
                                    bf.caller = Some((fid, pending.call_node_local));
                                    bf.parent_frame_ptr = std::ptr::null_mut();
                                    bf.state = FrameState::Ready;
                                }
                                if let Some(bf) = body_frame {
                                    self.frames.lock().insert(bfid, bf);
                                }
                                bfid
                            } else {
                                // 首次创建 body_sg 帧
                                let bfid = self.start_subgraph(
                                    fid,
                                    pending.call_node_local,
                                    pending.target_sg,
                                    &pending.args,
                                    frame,
                                    pending.closure_val.clone(),
                                );
                                frame.body_frame_id = Some(bfid);
                                bfid
                            }
                        } else {
                            // 非 LoopBody：正常 start_subgraph
                            self.start_subgraph(
                                fid,
                                pending.call_node_local,
                                pending.target_sg,
                                &pending.args,
                                frame,
                                pending.closure_val.clone(),
                            )
                        };

                        // 子帧入队
                        queue.push(child_fid);

                        if pending.is_async {
                            // async call：当前帧不挂起，call 节点写 AsyncHandle + 通知下游
                            let async_id = self.async_join_runtime.lock().alloc_id();
                            let async_handle = Value::i32(async_id.0 as i32);
                            self.async_join_runtime.lock().register(async_id, child_fid);

                            let node_start = frame.node_offset;
                            let graph_node_id =
                                NodeId(pending.call_node_local.0 + node_start);
                            let consumer_count =
                                graph.downstreams[graph_node_id.0 as usize].len() as u16;
                            frame.set_value(
                                pending.call_node_local,
                                async_handle,
                                consumer_count,
                            );
                            notify_downstream(
                                frame,
                                &graph,
                                pending.call_node_local,
                                graph_node_id,
                                NodeId(node_start),
                            );
                            continue;
                        } else {
                            // sync call：当前帧挂起等 SubgraphComplete 事件
                            self.event_waiters.lock().push((
                                RuntimeEvent::SubgraphComplete(child_fid),
                                fid,
                            ));
                            frame.state = FrameState::Suspended;
                            frame.suspend_state = SuspendState::WaitingSubgraph(child_fid);
                            frame.suspend_event =
                                Some(RuntimeEvent::SubgraphComplete(child_fid));
                            return;
                        }
                    }

                    crate::ir::Ir::Pending::ChannelNotify(ch_id) => {
                        self.on_event_arrived(
                            RuntimeEvent::ChannelReady(ch_id),
                            Value::VOID,
                            queue,
                        );
                    }

                    crate::ir::Ir::Pending::Await(pending) => {
                        let (event, ready_value) = self.resolve_and_check_await(&pending);

                        if let Some(value) = ready_value {
                            let node_start = frame.node_offset;
                            let graph_node_id =
                                NodeId(pending.await_node_local.0 + node_start);
                            let consumer_count =
                                graph.downstreams[graph_node_id.0 as usize].len() as u16;
                            frame.set_value(pending.await_node_local, value, consumer_count);
                            notify_downstream(
                                frame,
                                &graph,
                                pending.await_node_local,
                                graph_node_id,
                                NodeId(node_start),
                            );
                            continue;
                        } else {
                            self.event_waiters.lock().push((event, fid));
                            frame.state = FrameState::Suspended;
                            frame.suspend_state =
                                SuspendState::WaitingEvent(pending.await_node_local);
                            frame.suspend_event = Some(event);
                            return;
                        }
                    }

                    crate::ir::Ir::Pending::Cancel(async_id) => {
                        let child_fid = self
                            .async_join_runtime
                            .lock()
                            .find_child_by_async_id(async_id);
                        if let Some(child_fid) = child_fid {
                            self.cancel_frame(child_fid, queue);
                        }
                        let consumer_count =
                            graph.downstreams[graph_node_id.0 as usize].len() as u16;
                        frame.set_value(local_id, Value::VOID, consumer_count);
                        notify_downstream(
                            frame,
                            &graph,
                            local_id,
                            graph_node_id,
                            NodeId(node_start),
                        );
                        continue;
                    }

                    crate::ir::Ir::Pending::SelectWait(gate_local) => {
                        let info = graph.select_infos[graph_node_id.0 as usize].clone();

                        if let Some(info) = info {
                            let mut ready_branch: Option<SubGraphId> = None;
                            for (branch_idx, branch) in info.branches.iter().enumerate() {
                                let event_val =
                                    frame.get_value_by_global(branch.event_source_node);
                                let is_ready = match branch.event_kind {
                                    EventSourceKind::Channel => {
                                        event_val
                                            .heap_obj()
                                            .and_then(|h| h.channel())
                                            .map_or(false, |ch| ch.has_data() || ch.is_closed())
                                    }
                                    EventSourceKind::Timer => {
                                        let timer_id = {
                                            if let Some((_, tid)) = frame
                                                .select_timers
                                                .iter()
                                                .find(|(idx, _)| *idx == branch_idx)
                                            {
                                                *tid
                                            } else {
                                                let duration_ms = event_val.as_i32();
                                                let tid = self.timer_runtime.lock().start(
                                                    std::time::Duration::from_millis(
                                                        duration_ms as u64,
                                                    ),
                                                );
                                                frame.select_timers.push((branch_idx, tid));
                                                tid
                                            }
                                        };
                                        self.timer_runtime.lock().is_fired(timer_id)
                                    }
                                    _ => false,
                                };
                                if is_ready {
                                    ready_branch = Some(branch.subgraph_id);
                                    break;
                                }
                            }

                            if let Some(sg_id) = ready_branch {
                                let child_fid =
                                    self.start_subgraph(fid, gate_local, sg_id, &[], frame, None);
                                queue.push(child_fid);
                                self.event_waiters.lock().push((
                                    RuntimeEvent::SubgraphComplete(child_fid),
                                    fid,
                                ));
                                frame.state = FrameState::Suspended;
                                frame.suspend_state =
                                    SuspendState::WaitingSubgraph(child_fid);
                                frame.suspend_event =
                                    Some(RuntimeEvent::SubgraphComplete(child_fid));
                                return;
                            } else {
                                for (branch_idx, branch) in info.branches.iter().enumerate() {
                                    let event_val = frame
                                        .get_value_by_global(branch.event_source_node);
                                    let event = match branch.event_kind {
                                        EventSourceKind::Channel => {
                                            if let Some(ch) = event_val
                                                .heap_obj()
                                                .and_then(|h| h.channel())
                                            {
                                                RuntimeEvent::ChannelReady(
                                                    crate::ir::Ir::ChannelId(ch.id()),
                                                )
                                            } else {
                                                continue;
                                            }
                                        }
                                        EventSourceKind::Timer => {
                                            let timer_id = frame
                                                .select_timers
                                                .iter()
                                                .find(|(idx, _)| *idx == branch_idx)
                                                .map(|(_, tid)| *tid)
                                                .expect(
                                                    "select timer should be started above",
                                                );
                                            RuntimeEvent::TimerFired(timer_id)
                                        }
                                        _ => continue,
                                    };
                                    self.event_waiters.lock().push((event, fid));
                                }
                                frame.state = FrameState::Suspended;
                                frame.suspend_state =
                                    SuspendState::WaitingEvent(gate_local);
                                frame.suspend_event = None;
                                return;
                            }
                        }
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
            notify_downstream(frame, &graph, local_id, graph_node_id, NodeId(node_start));
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
                let defer_fid = self.init_frame(entry.body_subgraph);
                let mut defer_frame = self.frames.lock().remove(&defer_fid);
                if let Some(df) = defer_frame.as_deref_mut() {
                    self.run_frame_nodes(df, defer_fid, queue);
                }
                if let Some(df) = defer_frame {
                    if df.state != FrameState::Completed {
                        self.frames.lock().insert(defer_fid, df);
                    }
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
            let defer_fid = self.init_frame(entry.body_subgraph);
            let mut defer_frame = self.frames.lock().remove(&defer_fid);
            if let Some(df) = defer_frame.as_deref_mut() {
                self.run_frame_nodes(df, defer_fid, queue);
            }
            if let Some(df) = defer_frame {
                if df.state != FrameState::Completed {
                    self.frames.lock().insert(defer_fid, df);
                }
            }
        }

        // 标记帧完成
        frame.state = FrameState::Completed;
    }

    /// 启动子图：创建子帧 + 参数注入 + 绑定 caller。
    /// 同函数分支子图（if-else/match arm）：值表扩展到父函数大小，复制父帧值，
    /// 使分支节点可直接通过 get_value_by_global 访问外层变量（无需帧链指针）。
    fn start_subgraph(
        &self,
        caller_fid: FrameId,
        call_node: NodeId,
        subgraph_id: SubGraphId,
        args: &[Value],
        parent_frame: &Frame,
        closure_val: Option<Value>,
    ) -> FrameId {
        let child_fid = self.alloc_frame_id();
        let parent_sg = &self.graph.subgraphs[parent_frame.subgraph_id.0 as usize];
        let child_sg = &self.graph.subgraphs[subgraph_id.0 as usize];
        let same_function = parent_sg.function_id == child_sg.function_id;

        if same_function {
            // 同函数分支：值表扩展到父帧大小，复制父帧值。
            // 使用父帧的 node_offset/value_table.len() 而非 parent_sg.node_range，
            // 因为嵌套闭包帧的布局由祖父帧决定（如 outer 帧的 node_offset 是 main 的
            // node_start，而非 outer 子图的 node_range.0），使用 subgraph.node_range
            // 会导致值表索引错位、节点被误标记为 ready 从而跳过 compute_fn。
            let parent_start = parent_frame.node_offset;
            let parent_node_count = parent_frame.value_table.len();
            let (branch_start, _branch_end) = child_sg.node_range;
            let branch_param_count = child_sg.param_count as usize;

            let mut child = Frame::new(child_fid, subgraph_id, parent_node_count, self.graph.clone());
            child.node_offset = parent_start;

            // 复制父帧已就绪的值（refcount 设 0 = 永不回收，帧结束时统一释放）
            // 跳过 child_sg 范围内的节点：递归调用时 child_sg 是函数体子图，
            // 分支内节点（如 n-1）的旧计算结果不能复制，否则子帧不会重新计算，
            // 导致递归参数不递减（fact(n-1) 反复传入相同的旧 n-1 值）。
            for i in 0..parent_node_count {
                let gid = (parent_start as usize + i) as u32;
                let in_child = gid >= branch_start.0 && gid < child_sg.node_range.1 .0;
                if in_child {
                    continue;
                }
                if parent_frame.value_table.ready[i] {
                    child.value_table.values[i] = parent_frame.value_table.values[i].clone();
                    child.value_table.ready[i] = true;
                    child.value_table.refcounts[i] = 0;
                }
            }

            // 收集分支内嵌套子图范围
            let nested_ranges: Vec<(u32, u32)> = self.graph.subgraphs.iter()
                .filter(|sg| sg.id != subgraph_id
                    && sg.node_range.0 .0 >= branch_start.0
                    && sg.node_range.1 .0 <= child_sg.node_range.1 .0)
                .map(|sg| (sg.node_range.0 .0, sg.node_range.1 .0))
                .collect();
            let is_nested = |gid: u32| nested_ranges.iter().any(|&(s, e)| gid >= s && gid < e);

            // 设置 pending_inputs：分支节点按实际未就绪输入计数，非分支节点标记 EXTERNAL
            for i in 0..parent_node_count {
                let gid = (parent_start as usize + i) as u32;
                let in_branch = gid >= branch_start.0 && gid < child_sg.node_range.1 .0;
                if !in_branch || is_nested(gid) {
                    child.pending_inputs[i] = PENDING_EXTERNAL;
                    continue;
                }
                let node = &self.graph.nodes[gid as usize];
                if node.kind == NodeKind::EventSource {
                    child.pending_inputs[i] = PENDING_EXTERNAL;
                } else if node.kind == NodeKind::Gate && self.graph.select_infos[gid as usize].is_some() {
                    child.pending_inputs[i] = 0;
                } else {
                    // Gate（非 select）和普通节点统一：按实际 in-frame 未就绪输入计数
                    let inputs = self.graph.inputs_pool.get(node.inputs_offset, node.input_count);
                    let mut pending = 0u8;
                    for &inp in inputs {
                        let il = inp.0.wrapping_sub(parent_start) as usize;
                        if il < parent_node_count {
                            if !child.value_table.ready[il] { pending += 1; }
                        } else { pending += 1; }
                    }
                    child.pending_inputs[i] = pending;
                }
            }

            // 预填充分支内 Const 节点
            for i in 0..parent_node_count {
                let gid = (parent_start as usize + i) as u32;
                let in_branch = gid >= branch_start.0 && gid < child_sg.node_range.1 .0;
                if !in_branch || is_nested(gid) { continue; }
                if self.graph.nodes[gid as usize].kind == NodeKind::Const {
                    if let Some(cv) = self.graph.const_values[gid as usize] {
                        let handle = alloc_const_value(cv);
                        let cc = self.graph.downstreams[gid as usize].len() as u16;
                        child.set_value(NodeId(i as u32), handle, cc);
                        child.push_ready(NodeId(i as u32));
                    }
                }
            }

            // 参数注入（local 索引 = branch_start - parent_start + i）
            // 实际参数注入调用方传入的 arg 值；
            // upvalue 参数注入当前父帧值（引用捕获语义），使 same_function 调用
            // 能看到外层变量的最新值（而非闭包构造时的快照）。
            let param_local_offset = branch_start.0.wrapping_sub(parent_start) as usize;
            let actual_param_count = branch_param_count
                .saturating_sub(child_sg.upvalue_count as usize);
            // 实际参数
            for (i, arg) in args.iter().enumerate().take(actual_param_count) {
                let lid = NodeId((param_local_offset + i) as u32);
                let gid = branch_start.0 as usize + i;
                let cc = self.graph.downstreams[gid].len() as u16;
                child.set_value(lid, arg.clone(), cc);
                child.push_ready(lid);
            }
            // upvalue 参数：优先从父帧读取（引用捕获语义，使 same_function 调用
            // 能看到外层变量的最新值），父帧无此值时回退到 args 中的 Cell 解包值
            // （逃逸闭包场景：upvalue 来自已销毁的帧，如循环体局部变量）。
            for (i, &outer_node) in child_sg.upvalue_outer_nodes.iter().enumerate() {
                let arg_idx = actual_param_count + i;
                if arg_idx >= branch_param_count { break; }
                let lid = NodeId((param_local_offset + arg_idx) as u32);
                let gid = branch_start.0 as usize + arg_idx;
                let cc = self.graph.downstreams[gid].len() as u16;
                // 直接检查父帧是否就绪：get_value_by_global 在 pending_inputs=0
                // 且未就绪时会返回未初始化的值表内容（非 NULL），不能用 is_null 判断。
                let parent_local = outer_node.0.wrapping_sub(parent_frame.node_offset);
                let parent_ready = (parent_local as usize) < parent_frame.value_table.len()
                    && parent_frame.value_table.ready[parent_local as usize];
                let val = if parent_ready {
                    parent_frame.get_value_by_global(outer_node)
                } else if arg_idx < args.len() {
                    args[arg_idx].clone()
                } else {
                    parent_frame.get_value_by_global(outer_node)
                };
                child.set_value(lid, val, cc);
                child.push_ready(lid);
            }

            // 分支内 0-input 非 Const 非 Param 节点入队
            for i in 0..parent_node_count {
                let gid = (parent_start as usize + i) as u32;
                let in_branch = gid >= branch_start.0 && gid < child_sg.node_range.1 .0;
                if !in_branch || is_nested(gid) { continue; }
                let local_in_branch = (gid - branch_start.0) as usize;
                if local_in_branch < branch_param_count { continue; }
                if self.graph.nodes[gid as usize].kind == NodeKind::Const { continue; }
                if child.pending_inputs[i] == 0 && !child.value_table.ready[i] {
                    child.push_ready(NodeId(i as u32));
                }
            }

            child.caller = Some((caller_fid, call_node));

            // 帧链指针在 process_frame 的 setup_frame_chain 中设置
            child.root_frame_ptr = std::ptr::null_mut();
            child.parent_frame_ptr = std::ptr::null_mut();
            child.closure_val = closure_val;

            self.frames.lock().insert(child_fid, Box::new(child));
            child_fid
        } else {
            // 跨函数调用：原有逻辑
            let (node_start, node_end) = child_sg.node_range;
            let node_count = (node_end.0 - node_start.0) as usize;
            let offset = node_start.0 as usize;

            let mut child = Frame::new(child_fid, subgraph_id, node_count, self.graph.clone());
            self.prepare_frame(&mut child);

            let param_count = child_sg.param_count as usize;
            for (i, arg) in args.iter().enumerate().take(param_count) {
                let local_id = NodeId(i as u32);
                let consumer_count = self.graph.downstreams[offset + i].len() as u16;
                child.set_value(local_id, arg.clone(), consumer_count);
                child.push_ready(local_id);
            }

            child.caller = Some((caller_fid, call_node));
            child.root_frame_ptr = std::ptr::null_mut();
            child.parent_frame_ptr = std::ptr::null_mut();
            child.closure_val = closure_val;

            self.frames.lock().insert(child_fid, Box::new(child));
            child_fid
        }
    }

    /// 子图完成后：回写返回值到调用方 + 唤醒调用方。
    /// 含 LoopBody 完成检测 + pending_completions 竞态处理。
    fn complete_and_wake_caller(&self, child_frame: Frame, queue: &QueueHandle<'_>) {
        // LoopBody 完成检测（从 Engine 版本移植）
        let child_sg_id = child_frame.subgraph_id;
        let child_loop_kind = self.graph.subgraphs[child_sg_id.0 as usize].loop_kind;
        if child_loop_kind == crate::ir::Ir::LoopKind::LoopBody {
            let child_signal = child_frame.control_signal.clone();
            let (loop_fid, _call_node) = child_frame
                .caller
                .expect("LoopBody frame missing caller");
            match child_signal {
                ControlSignal::Break | ControlSignal::Return(_) => {
                    // break/return → 循环退出
                    let mut loop_frame = self.frames.lock().remove(&loop_fid);
                    if let Some(lf) = loop_frame.as_deref_mut() {
                        lf.body_frame_id = None;
                        lf.control_signal = child_signal;
                    }
                    // 递归处理 loop_frame（loop_kind 是 While/Loop/For，非 LoopBody）
                    if let Some(lf) = loop_frame {
                        self.complete_and_wake_caller(*lf, queue);
                    }
                    // child_frame (body) 已 drop，不放回
                    return;
                }
                ControlSignal::Continue | ControlSignal::None => {
                    // continue/正常完成 → 循环重置（帧复用）
                    let mut loop_frame = self.frames.lock().remove(&loop_fid);
                    let mut child = child_frame; // 取得所有权以便修改
                    if let Some(lf) = loop_frame.as_deref_mut() {
                        self.reset_loop_iteration(lf, loop_fid, &mut child);
                    }
                    if let Some(lf) = loop_frame {
                        self.frames.lock().insert(loop_fid, lf);
                        queue.push(loop_fid);
                    }
                    // body 帧已重置，放回 HashMap（不入队）。
                    // body 的重新执行只应由 loop 帧在 cond 为真时通过
                    // 帧复用路径（start_subgraph / queue.push）触发。
                    // 若在此入队，会导致 body 双重执行 + 循环退出后
                    // stale caller 引用（loop 帧已 drop）。
                    let body_id = child.id;
                    self.frames.lock().insert(body_id, Box::new(child));
                    return;
                }
            }
        }

        // 非 LoopBody：回写返回值 + 唤醒 caller（含 pending_completions 竞态处理）
        let return_value = extract_child_return(&child_frame, &self.graph);
        let child_signal = child_frame.control_signal.clone();
        let caller = child_frame.caller;
        // child_frame 在此之后 drop

        if let Some((caller_fid, call_node)) = caller {
            let mut caller_frame_opt = self.frames.lock().remove(&caller_fid);
            if caller_frame_opt.is_none() {
                // 父帧尚未 insert 回 HashMap，存储完成信息等待重试
                self.pending_completions.lock().insert(
                    caller_fid,
                    (call_node, return_value, child_signal),
                );
                return;
            }
            if let Some(caller_frame) = caller_frame_opt.as_deref_mut() {
                // 使用 caller_frame.node_offset 而非 subgraph.node_range.0：
                // 同函数分支帧的 node_offset 是父函数的 node_start，
                // 而 subgraph.node_range.0 是分支子图的 node_start，两者不同。
                // 用错会导致 call_graph_id 偏移错误 → notify_downstream 找不到下游
                // → 下游节点 ready 标记永远不被设置 → 帧挂起。
                let caller_offset = NodeId(caller_frame.node_offset);
                let call_graph_id = NodeId(call_node.0 + caller_offset.0);
                let consumer_count =
                    self.graph.downstreams[call_graph_id.0 as usize].len() as u16;

                caller_frame.set_value(call_node, return_value, consumer_count);
                caller_frame.state = FrameState::Ready;
                caller_frame.suspend_state = SuspendState::NotSuspended;
                caller_frame.suspend_event = None;

                // Gate 分支子图的控制信号传播
                let is_gate =
                    self.graph.nodes[call_graph_id.0 as usize].kind == crate::ir::Ir::NodeKind::Gate;
                if is_gate && !matches!(child_signal, ControlSignal::None) {
                    caller_frame.control_signal = child_signal;
                }

                notify_downstream(
                    caller_frame,
                    &self.graph,
                    call_node,
                    call_graph_id,
                    caller_offset,
                );
            }
            if let Some(caller_frame) = caller_frame_opt {
                self.frames.lock().insert(caller_fid, caller_frame);
                queue.push(caller_fid);
            }
        }
        // 子帧已完成，由调用方负责 drop（不放回 frames）
    }

    /// 循环迭代重置：body_sg 完成后重置循环帧 + 复用 body_sg 帧。
    /// 从 Engine 版本移植，改为 &self + &mut Frame 参数
    fn reset_loop_iteration(
        &self,
        loop_frame: &mut Frame,
        loop_fid: FrameId,
        body_frame: &mut Frame,
    ) {
        let loop_sg_id = loop_frame.subgraph_id;
        let (loop_kind, cond_node, return_node, iter_next_node) = {
            let sg = &self.graph.subgraphs[loop_sg_id.0 as usize];
            (sg.loop_kind, sg.cond_node, sg.return_node, sg.iter_next_node)
        };
        // 使用 loop_frame.node_offset 而非 subgraph.node_range.0（同函数分支帧修正）
        let loop_offset = loop_frame.node_offset;

        // 1. For 循环：额外重置 iter_next_node
        if loop_kind == crate::ir::Ir::LoopKind::For {
            if let Some(next_node) = iter_next_node {
                let next_local = NodeId(next_node.0.wrapping_sub(loop_offset));
                Self::reset_node_ready(loop_frame, next_local);
                loop_frame.push_ready(next_local);
            }
        }

        // 2. 重置 cond_node
        if let Some(cond_node) = cond_node {
            let cond_local = NodeId(cond_node.0.wrapping_sub(loop_offset));
            if loop_kind == crate::ir::Ir::LoopKind::For {
                Self::reset_node_pending(loop_frame, cond_local, 1);
            } else {
                Self::reset_node_ready(loop_frame, cond_local);
                // Const cond_node 重新预填充
                if self.graph.nodes[cond_node.0 as usize].kind == crate::ir::Ir::NodeKind::Const {
                    if let Some(cv) = self.graph.const_values[cond_node.0 as usize] {
                        let handle = alloc_const_value(cv);
                        let consumer_count =
                            self.graph.downstreams[cond_node.0 as usize].len() as u16;
                        loop_frame.set_value(cond_local, handle, consumer_count);
                    }
                }
                loop_frame.push_ready(cond_local);
            }
        }

        // 3. 重置 Gate 节点（pending=1，等 cond notify）
        let gate_local = NodeId(return_node.0.wrapping_sub(loop_offset));
        Self::reset_node_pending(loop_frame, gate_local, 1);

        // 4. 重置 body_sg 帧（复用）
        body_frame.value_table.reset_all();
        body_frame.ready_queue.clear();
        body_frame.control_signal = ControlSignal::None;
        body_frame.pending = None;
        prepare_frame_nodes(body_frame, &self.graph);
        // body_sg 帧重新绑定 caller
        body_frame.caller =
            Some((loop_fid, NodeId(return_node.0.wrapping_sub(loop_offset))));
        // 帧链指针设为 null（HashMap 地址不稳定）
        body_frame.root_frame_ptr = std::ptr::null_mut();
        body_frame.parent_frame_ptr = std::ptr::null_mut();

        // 5. 重置循环帧状态
        loop_frame.control_signal = ControlSignal::None;
        loop_frame.state = FrameState::Ready;
        loop_frame.suspend_state = SuspendState::NotSuspended;
        loop_frame.suspend_event = None;
        loop_frame.pending = None;
    }

    /// 重置节点为就绪状态（pending=0，清值，不入队）。关联函数。
    fn reset_node_ready(frame: &mut Frame, node_local: NodeId) {
        let i = node_local.0 as usize;
        if i < frame.pending_inputs.len() {
            frame.pending_inputs[i] = 0;
        }
        if i < frame.value_table.len() {
            frame.value_table.reset_slot(i);
        }
    }

    /// 重置节点为待定状态（pending=N，清值）。关联函数。
    fn reset_node_pending(frame: &mut Frame, node_local: NodeId, pending: u8) {
        let i = node_local.0 as usize;
        if i < frame.pending_inputs.len() {
            frame.pending_inputs[i] = pending;
        }
        if i < frame.value_table.len() {
            frame.value_table.reset_slot(i);
        }
    }

    /// 解析 await 事件源 + 检查就绪。
    fn resolve_and_check_await(
        &self,
        pending: &crate::ir::Ir::PendingAwait,
    ) -> (RuntimeEvent, Option<Value>) {
        use crate::ir::Ir::EventSourceKind;
        match pending.event_kind {
            EventSourceKind::AsyncJoin => {
                let async_id = crate::ir::Ir::AsyncHandleId(pending.event_obj.as_i32() as u32);
                let event = RuntimeEvent::AsyncJoin(async_id);
                let val = self.async_join_runtime.lock().try_get_result(async_id);
                (event, val)
            }
            EventSourceKind::Channel => {
                let ch = pending
                    .event_obj
                    .heap_obj()
                    .and_then(|h| h.channel())
                    .expect("await on non-channel value");
                let v = ch.recv().or_else(|| if ch.is_closed() { Some(Value::Null) } else { None });
                let event = RuntimeEvent::ChannelReady(crate::ir::Ir::ChannelId(ch.id()));
                (event, v)
            }
            EventSourceKind::Timer => {
                let duration_ns = match pending.event_obj.heap_obj() {
                    Some(crate::Value::HeapObj::Record(r)) => {
                        r.find_field(TIMER_DURATION_NS_FIELD)
                            .map(|v| v.as_i64())
                            .expect("timer event record missing duration_ns field")
                    }
                    _ => pending.event_obj.as_i64(),
                };
                let timer_id = self
                    .timer_runtime
                    .lock()
                    .start(std::time::Duration::from_nanos(duration_ns as u64));
                let event = RuntimeEvent::TimerFired(timer_id);
                let fired = self.timer_runtime.lock().is_fired(timer_id);
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

    /// 事件到达：注入值到等待帧 + 唤醒。
    fn on_event_arrived(&self, event: RuntimeEvent, value: Value, queue: &QueueHandle<'_>) {
        // 找等待该事件的帧（短临界区）
        let waiters: Vec<FrameId> = {
            let mut event_waiters = self.event_waiters.lock();
            let waiters: Vec<FrameId> = event_waiters
                .iter()
                .filter(|(e, _)| *e == event)
                .map(|(_, fid)| *fid)
                .collect();
            event_waiters.retain(|(_, fid)| !waiters.contains(fid));
            waiters
        };

        for fid in waiters {
            // 取出帧（保持 Box 不 unbox 以维持地址稳定）
            let mut frame_box = {
                let mut frames = self.frames.lock();
                match frames.remove(&fid) {
                    Some(b) => b,
                    None => continue, // 帧正被其他 worker 处理，跳过
                }
            };
            let frame: &mut Frame = &mut *frame_box;

            let await_node = match frame.suspend_state {
                SuspendState::WaitingEvent(node) => node,
                _ => {
                    // 非事件等待帧：放回 + 跳过
                    self.frames.lock().insert(fid, frame_box);
                    continue;
                }
            };

            let node_offset = frame.node_offset;
            let await_graph_id = NodeId(await_node.0 + node_offset);

            // select 帧（gate 节点有 SelectInfo）：重新 push gate 节点，不注入值
            let is_select = self.graph.select_infos[await_graph_id.0 as usize].is_some();
            if is_select {
                frame.state = FrameState::Ready;
                frame.suspend_state = SuspendState::NotSuspended;
                frame.suspend_event = None;
                frame.push_ready(await_node);
            } else {
                // 普通 await 帧：注入事件值到 await 节点
                let consumer_count =
                    self.graph.downstreams[await_graph_id.0 as usize].len() as u16;
                frame.set_value(await_node, value.clone(), consumer_count);
                frame.state = FrameState::Ready;
                frame.suspend_state = SuspendState::NotSuspended;
                frame.suspend_event = None;
                notify_downstream(
                    frame,
                    &self.graph,
                    await_node,
                    await_graph_id,
                    NodeId(node_offset),
                );
            }

            // 放回帧 + 入队（同一个 Box，地址不变）
            self.frames.lock().insert(fid, frame_box);
            queue.push(fid);
        }
    }

    /// 取消帧：Suspended → Cancelling + 入就绪队列。
    fn cancel_frame(&self, frame_id: FrameId, queue: &QueueHandle<'_>) {
        let mut frame_box = {
            let mut frames = self.frames.lock();
            match frames.remove(&frame_id) {
                Some(b) => b,
                None => return, // 帧正被其他 worker 处理，跳过
            }
        };
        let frame: &mut Frame = &mut *frame_box;

        if frame.state != FrameState::Suspended {
            self.frames.lock().insert(frame_id, frame_box);
            return;
        }

        // 移除事件等待注册
        if let Some(event) = frame.suspend_event {
            self.event_waiters
                .lock()
                .retain(|(e, fid)| !(*e == event && *fid == frame_id));
        } else {
            // select 帧：移除该帧所有事件等待
            self.event_waiters
                .lock()
                .retain(|(_, fid)| *fid != frame_id);
        }

        frame.state = FrameState::Cancelling;
        frame.suspend_state = SuspendState::NotSuspended;
        frame.suspend_event = None;

        self.frames.lock().insert(frame_id, frame_box);
        queue.push(frame_id);
    }

    /// 检查 timer 事件
    fn check_timers(&self, queue: &QueueHandle<'_>) {
        let fired_timers = self.timer_runtime.lock().check_and_fire();
        for tid in fired_timers {
            self.on_event_arrived(RuntimeEvent::TimerFired(tid), Value::VOID, queue);
        }
    }

    /// 设置帧链指针：从 HashMap 中查找 caller 链，设置 parent_frame_ptr/root_frame_ptr。
    ///
    /// 必须在帧从 HashMap remove 后、执行前调用（此时所有父帧仍在 HashMap 中，
    /// Box<Frame> 的堆地址稳定，即使 HashMap rehash 也不会移动）。
    ///
    /// 同函数子图（if-else/match arm/loop body）：parent_frame_ptr 指向直接调用方帧，
    /// root_frame_ptr 指向函数根帧（沿 caller 链向上查找同函数的最远帧）。
    /// 跨函数调用：两个指针均为 null（不允许跨函数访问外层变量）。
    ///
    /// 如果 caller 帧不在 HashMap 中（正在被其他 worker 执行），保持已有指针不变
    /// （start_subgraph 已在创建时设置了初始指针）。
    fn setup_frame_chain(&self, frame: &mut Frame) {
        let Some((caller_fid, _)) = frame.caller else {
            return; // 顶层帧，无父帧
        };

        let frames = self.frames.lock();
        let Some(caller_box) = frames.get(&caller_fid) else {
            return; // caller 不在 HashMap 中（正在执行），保持已有指针
        };

        let frame_fn_id = self.graph.subgraphs[frame.subgraph_id.0 as usize].function_id;
        let caller_fn_id =
            self.graph.subgraphs[caller_box.subgraph_id.0 as usize].function_id;

        // 跨函数调用：不设置帧链指针
        if caller_fn_id != frame_fn_id {
            return;
        }

        let caller_ptr = caller_box.as_ref() as *const Frame as *mut Frame;
        frame.parent_frame_ptr = caller_ptr;

        // root_frame_ptr：沿 caller 链向上查找同函数的最远帧
        let mut root_ptr = caller_ptr;
        let mut current_box = caller_box;
        loop {
            match current_box.caller {
                Some((grandparent_fid, _)) => {
                    match frames.get(&grandparent_fid) {
                        Some(gp_box) => {
                            let gp_fn_id =
                                self.graph.subgraphs[gp_box.subgraph_id.0 as usize].function_id;
                            if gp_fn_id != frame_fn_id {
                                break; // 跨函数边界
                            }
                            root_ptr = gp_box.as_ref() as *const Frame as *mut Frame;
                            current_box = gp_box;
                        }
                        None => break, // 祖父帧不在 HashMap 中
                    }
                }
                None => break, // 到达同函数链顶
            }
        }
        frame.root_frame_ptr = root_ptr;
    }

    /// 处理一帧：timer 检查 + run_frame_nodes + 状态转换。
    /// 返回 ()，结果通过 self.result.lock() 传递
    fn process_frame(&self, fid: FrameId, queue: &QueueHandle<'_>) {
        // 检查 timer 事件
        self.check_timers(queue);

        // 取出帧（保持 Box 不 unbox：堆地址在 remove/insert 周期中保持稳定，
        // 使其他帧持有的 parent_frame_ptr/root_frame_ptr 不会悬挂）
        let mut frame_box = match self.frames.lock().remove(&fid) {
            Some(b) => b,
            None => return,
        };
        let frame: &mut Frame = &mut *frame_box;

        // 设置帧链指针：从 HashMap 中查找 caller 链，设置 parent_frame_ptr/root_frame_ptr。
        // 此时所有父帧仍在 HashMap 中（Box 地址稳定）。
        self.setup_frame_chain(frame);

        // 执行帧就绪节点（无锁）
        self.run_frame_nodes(frame, fid, queue);

        // 处理帧状态
        let state = frame.state;
        let has_caller = frame.caller.is_some();

        match state {
            FrameState::Suspended => {
                let event = frame.suspend_event;
                // 检查 pending_completions（子帧先完成但父帧尚未 insert 的竞态）
                let pending = self.pending_completions.lock().remove(&fid);
                if let Some((call_node, return_value, child_signal)) = pending {
                    // 有 pending completion：直接消费完成事件
                    if let Some(e) = event {
                        self.event_waiters
                            .lock()
                            .retain(|(we, wf)| !(*we == e && *wf == fid));
                    } else {
                        self.event_waiters
                            .lock()
                            .retain(|(_, wf)| *wf != fid);
                    }
                    let _ = child_signal;
                    // 使用 frame.node_offset 而非 subgraph.node_range.0（同函数分支帧修正）
                    let caller_offset = NodeId(frame.node_offset);
                    let call_graph_id = NodeId(call_node.0 + caller_offset.0);
                    let consumer_count =
                        self.graph.downstreams[call_graph_id.0 as usize].len() as u16;
                    frame.set_value(call_node, return_value, consumer_count);
                    frame.state = FrameState::Ready;
                    frame.suspend_state = SuspendState::NotSuspended;
                    frame.suspend_event = None;
                    notify_downstream(
                        frame,
                        &self.graph,
                        call_node,
                        call_graph_id,
                        caller_offset,
                    );
                    // 放回同一个 Box（地址不变）
                    self.frames.lock().insert(fid, frame_box);
                    queue.push(fid);
                } else {
                    self.frames.lock().insert(fid, frame_box);
                }
            }
            FrameState::Completed => {
                if has_caller {
                    // 区分 sync call vs async call 子帧完成
                    let async_id = self.async_join_runtime.lock().find_by_child(fid);
                    if let Some(async_id) = async_id {
                        // async 子帧完成：设置 result + 触发 AsyncJoin 事件
                        let return_value =
                            extract_child_return(frame, &self.graph);
                        self.async_join_runtime
                            .lock()
                            .set_result(async_id, return_value.clone());
                        // frame_box drop（不放回）
                        self.on_event_arrived(
                            RuntimeEvent::AsyncJoin(async_id),
                            return_value,
                            queue,
                        );
                    } else {
                        // sync 子帧完成：清理 waiter + 回写 + 唤醒调用方
                        self.event_waiters.lock().retain(|(e, _)| {
                            !matches!(e, RuntimeEvent::SubgraphComplete(c) if *c == fid)
                        });
                        // 帧被消费：unbox 传给 complete_and_wake_caller
                        self.complete_and_wake_caller(*frame_box, queue);
                    }
                } else {
                    // 顶层帧完成：返回结果
                    let ret = extract_child_return(frame, &self.graph);
                    *self.result.lock() = Some(ret);
                }
            }
            FrameState::Failed => {
                if has_caller {
                    // Failed 子帧（cancel 后）：清理 waiter + 唤醒调用方
                    self.event_waiters.lock().retain(|(e, _)| {
                        !matches!(e, RuntimeEvent::SubgraphComplete(c) if *c == fid)
                    });
                    self.complete_and_wake_caller(*frame_box, queue);
                } else {
                    // 顶层帧 Failed：返回 NULL
                    *self.result.lock() = Some(Value::NULL);
                }
            }
            _ => {
                // Ready（控制信号触发但未挂起）：放回 + 重新入队
                self.frames.lock().insert(fid, frame_box);
                queue.push(fid);
            }
        }
    }
}

// =========================================================================
// impl Engine<Single> — 单线程模式
// =========================================================================

impl Engine<Single> {
    /// 创建单线程 Engine（用 RefCell 包装所有字段）
    fn new_single(graph: DataFlowGraph) -> Self {
        let graph = Arc::new(graph);
        Self {
            graph: graph.clone(),
            frames: RefCell::new(HashMap::new()),
            next_frame_id: RefCell::new(FrameId(0)),
            arena: RefCell::new(ValueArena::new()),
            timer_runtime: RefCell::new(TimerRuntime::new()),
            async_join_runtime: RefCell::new(AsyncJoinRuntime::new()),
            event_waiters: RefCell::new(Vec::new()),
            pending_completions: RefCell::new(HashMap::new()),
            result: RefCell::new(None),
            ready_frames: Some(RefCell::new(std::collections::VecDeque::new())),
            global_queue: None,
            wakeup: None,
            active_count: None,
            _strategy: std::marker::PhantomData,
        }
    }

    /// 单线程事件循环（替代 run_event_loop + run_entry）
    fn run_single(&self) -> Value {
        let entry_sg = self.graph.entry_subgraph.expect("no entry subgraph");
        let fid = self.init_frame(entry_sg);
        let rq = self.ready_frames.as_ref().unwrap();
        rq.borrow_mut().push_back(fid);

        let mut loop_guard: u64 = 0;
        loop {
            loop_guard += 1;
            if loop_guard > 20000000 {
                panic!("event loop stuck: guard={}", loop_guard);
            }
            let queue = QueueHandle::Single(rq);
            let fid = match rq.borrow_mut().pop_front() {
                Some(f) => f,
                None => {
                    // 队列空时检查 timer（可能触发事件唤醒挂起帧）
                    self.check_timers(&queue);
                    let ew = self.event_waiters.lock();
                    if ew.is_empty() {
                        panic!(
                            "event loop exhausted: no ready frames and no pending events"
                        );
                    }
                    drop(ew);
                    std::thread::yield_now();
                    continue;
                }
            };
            self.process_frame(fid, &queue);
            if let Some(result) = self.result.lock().take() {
                return result;
            }
        }
    }
}

// =========================================================================
// impl Engine<Multi> — 多 worker 模式
// =========================================================================

impl Engine<Multi> {
    /// 创建多线程 Engine（用 ParkingMutex 包装所有字段）
    fn new_multi(graph: DataFlowGraph, num_workers: usize) -> Self {
        let graph = Arc::new(graph);
        Self {
            graph: graph.clone(),
            frames: ParkingMutex::new(HashMap::new()),
            next_frame_id: ParkingMutex::new(FrameId(0)),
            arena: ParkingMutex::new(ValueArena::new()),
            timer_runtime: ParkingMutex::new(TimerRuntime::new()),
            async_join_runtime: ParkingMutex::new(AsyncJoinRuntime::new()),
            event_waiters: ParkingMutex::new(Vec::new()),
            pending_completions: ParkingMutex::new(HashMap::new()),
            result: ParkingMutex::new(None),
            ready_frames: None,
            global_queue: Some(Injector::new()),
            wakeup: Some((ParkingMutex::new(()), Condvar::new())),
            active_count: Some(ParkingMutex::new(num_workers)),
            _strategy: std::marker::PhantomData,
        }
    }

    /// 多 worker 模式执行入口子图（替代 run_multi_worker）
    fn run_multi(self: Arc<Self>) -> Value {
        let entry_sg = self.graph.entry_subgraph.expect("no entry subgraph");
        let entry_fid = self.init_frame(entry_sg);

        let num_workers = *self.active_count.as_ref().unwrap().lock();
        let mut local_queues: Vec<DequeWorker<FrameId>> = Vec::with_capacity(num_workers);
        let mut stealers: Vec<Stealer<FrameId>> = Vec::with_capacity(num_workers);
        for _ in 0..num_workers {
            let w = DequeWorker::new_lifo();
            stealers.push(w.stealer());
            local_queues.push(w);
        }

        self.global_queue.as_ref().unwrap().push(entry_fid);

        std::thread::scope(|s| {
            for (worker_id, local_queue) in local_queues.into_iter().enumerate() {
                let shared = self.clone();
                let stealers = stealers.clone();
                s.spawn(move || {
                    worker_main(worker_id, local_queue, stealers, shared);
                });
            }
        });

        self.result
            .lock()
            .take()
            .expect("no result produced: all workers exited without completion")
    }
}

// =========================================================================
// work-stealing worker 主循环（自由函数，供 run_multi 使用）
// =========================================================================

/// Worker 主循环：pop_local → try_steal → try_global → park。
fn worker_main(
    worker_id: usize,
    local_queue: DequeWorker<FrameId>,
    stealers: Vec<Stealer<FrameId>>,
    shared: Arc<Engine<Multi>>,
) {
    let mut steal_seed: u64 = worker_id as u64 ^ GOLDEN_RATIO_64;

    loop {
        // 结果已产生：退出
        if shared.result.lock().is_some() {
            return;
        }

        // 1. pop_local（LIFO，缓存友好）
        if let Some(fid) = local_queue.pop() {
            let queue = QueueHandle::Multi(&local_queue);
            shared.process_frame(fid, &queue);
            {
                let _g = shared.wakeup.as_ref().unwrap().0.lock();
                shared.wakeup.as_ref().unwrap().1.notify_all();
            }
            continue;
        }

        // 2. try_steal（随机 victim，FIFO 窃取）
        if let Some(fid) = try_steal(&stealers, worker_id, &mut steal_seed) {
            let queue = QueueHandle::Multi(&local_queue);
            shared.process_frame(fid, &queue);
            {
                let _g = shared.wakeup.as_ref().unwrap().0.lock();
                shared.wakeup.as_ref().unwrap().1.notify_all();
            }
            continue;
        }

        // 3. try_global（全局注入队列）
        if let Some(fid) = shared.global_queue.as_ref().unwrap().steal().success() {
            let queue = QueueHandle::Multi(&local_queue);
            shared.process_frame(fid, &queue);
            {
                let _g = shared.wakeup.as_ref().unwrap().0.lock();
                shared.wakeup.as_ref().unwrap().1.notify_all();
            }
            continue;
        }

        // 4. 无工作：减少活跃计数，检查是否全部空闲
        {
            let mut active = shared.active_count.as_ref().unwrap().lock();
            *active -= 1;
            if *active == 0 {
                drop(active);
                {
                    let _g = shared.wakeup.as_ref().unwrap().0.lock();
                    shared.wakeup.as_ref().unwrap().1.notify_all();
                }
                return;
            }
        }

        // 5. park（等待唤醒，避免 busy-wait）
        {
            let mut guard = shared.wakeup.as_ref().unwrap().0.lock();
            if shared.result.lock().is_some() {
                let mut active = shared.active_count.as_ref().unwrap().lock();
                *active += 1;
                return;
            }
            if !local_queue.is_empty() || !shared.global_queue.as_ref().unwrap().is_empty() {
                let mut active = shared.active_count.as_ref().unwrap().lock();
                *active += 1;
                continue;
            }
            let park_timeout = std::time::Duration::from_millis(10);
            shared.wakeup.as_ref().unwrap().1.wait_for(&mut guard, park_timeout);
        }
        {
            let mut active = shared.active_count.as_ref().unwrap().lock();
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

// =========================================================================
// EngineRef — 统一工厂（根据 workers 数决定编译期策略）
// =========================================================================

/// 统一工厂：根据 workers 数决定编译期策略
pub enum EngineRef {
    Single(Engine<Single>),
    Multi(Arc<Engine<Multi>>),
}

impl EngineRef {
    /// 创建引擎：workers <= 1 用单线程，> 1 用多 worker
    pub fn new(graph: DataFlowGraph, workers: usize) -> Self {
        if workers <= 1 {
            Self::Single(Engine::<Single>::new_single(graph))
        } else {
            Self::Multi(Arc::new(Engine::<Multi>::new_multi(graph, workers)))
        }
    }

    /// 运行引擎，返回结果值
    pub fn run(self) -> Value {
        match self {
            Self::Single(e) => e.run_single(),
            Self::Multi(e) => Engine::<Multi>::run_multi(e),
        }
    }
}
