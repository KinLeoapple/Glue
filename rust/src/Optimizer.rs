//! Optimizer.rs — IR 后优化器
//!
//! 对 IrBuilder 生成的 DataFlowGraph 做固定点迭代的图级优化。
//! Pass 管线：ConstFold → CSE → CopyProp → DCE（→ BranchPrune → EscapeElim 待接入）。
//! 节点变换采用"标记 + 重定向 + 晚期压缩重建"策略，Engine 侧零改动。
//! 详见 docs/superpowers/plans/2026-08-04-ir-optimizer.md

use crate::Ir::{ConstValue, ComputeFnId, DataFlowGraph, Node, NodeId, NodeKind};
use pastey::paste;
use rustc_hash::{FxHashMap, FxHashSet};

// =========================================================================
// ConstValue 提取器 — 类型安全地从 ConstValue 提取原始值
// =========================================================================

macro_rules! impl_cv_extract {
    ($cv:ident, $rust:ty, $name:ident) => {
        fn $name(cv: &ConstValue) -> Option<$rust> {
            match cv { ConstValue::$cv(v) => Some(*v), _ => None }
        }
    };
}
impl_cv_extract!(I8, i8, cv_i8);
impl_cv_extract!(I16, i16, cv_i16);
impl_cv_extract!(I32, i32, cv_i32);
impl_cv_extract!(I64, i64, cv_i64);
impl_cv_extract!(I128, i128, cv_i128);
impl_cv_extract!(U8, u8, cv_u8);
impl_cv_extract!(U16, u16, cv_u16);
impl_cv_extract!(U32, u32, cv_u32);
impl_cv_extract!(U64, u64, cv_u64);
impl_cv_extract!(U128, u128, cv_u128);
impl_cv_extract!(Isize, isize, cv_isize);
impl_cv_extract!(Usize, usize, cv_usize);
impl_cv_extract!(F32, f32, cv_f32);
impl_cv_extract!(F64, f64, cv_f64);
impl_cv_extract!(Bool, bool, cv_bool);

/// 从 args 提取两个同类型值。
fn two<T>(args: &[ConstValue], extract: fn(&ConstValue) -> Option<T>) -> Option<(T, T)> {
    Some((extract(args.get(0)?)?, extract(args.get(1)?)?))
}

// =========================================================================
// try_fold — 常量折叠分派
// =========================================================================

/// 尝试对给定 compute_fn 和常量参数执行编译期求值。
/// 返回 None 表示无法折叠（类型不匹配或非可折叠 op）。
pub fn try_fold(cf: ComputeFnId, args: &[ConstValue]) -> Option<ConstValue> {
    use crate::Value as V;
    match cf.0 {
        // ── Legacy i32 算术 (1,3,5,6,7) ──
        1  => { let (a, b) = two(args, cv_i32)?; Some(ConstValue::I32(V::arith_add_i32(a, b))) }
        3  => { let (a, b) = two(args, cv_i32)?; Some(ConstValue::I32(V::arith_mul_i32(a, b))) }
        5  => { let (a, b) = two(args, cv_i32)?; Some(ConstValue::I32(V::arith_sub_i32(a, b))) }
        6  => { let (a, b) = two(args, cv_i32)?; Some(ConstValue::I32(V::arith_div_i32(a, b))) }
        7  => { let (a, b) = two(args, cv_i32)?; Some(ConstValue::I32(V::arith_mod_i32(a, b))) }
        // ── Legacy i32 比较 (4,8,9,10,11,12) → bool ──
        4  => { let (a, b) = two(args, cv_i32)?; Some(ConstValue::Bool(a <= b)) }
        8  => { let (a, b) = two(args, cv_i32)?; Some(ConstValue::Bool(a == b)) }
        9  => { let (a, b) = two(args, cv_i32)?; Some(ConstValue::Bool(a != b)) }
        10 => { let (a, b) = two(args, cv_i32)?; Some(ConstValue::Bool(a < b)) }
        11 => { let (a, b) = two(args, cv_i32)?; Some(ConstValue::Bool(a > b)) }
        12 => { let (a, b) = two(args, cv_i32)?; Some(ConstValue::Bool(a >= b)) }
        // ── Legacy f64 算术 (2,13,14,15) ──
        2  => { let (a, b) = two(args, cv_f64)?; Some(ConstValue::F64(V::arith_add_f64(a, b))) }
        13 => { let (a, b) = two(args, cv_f64)?; Some(ConstValue::F64(V::arith_sub_f64(a, b))) }
        14 => { let (a, b) = two(args, cv_f64)?; Some(ConstValue::F64(V::arith_mul_f64(a, b))) }
        15 => { let (a, b) = two(args, cv_f64)?; Some(ConstValue::F64(V::arith_div_f64(a, b))) }
        // ── Legacy f64 比较 (16-21) → bool ──
        16 => { let (a, b) = two(args, cv_f64)?; Some(ConstValue::Bool(a == b)) }
        17 => { let (a, b) = two(args, cv_f64)?; Some(ConstValue::Bool(a != b)) }
        18 => { let (a, b) = two(args, cv_f64)?; Some(ConstValue::Bool(a < b)) }
        19 => { let (a, b) = two(args, cv_f64)?; Some(ConstValue::Bool(a > b)) }
        20 => { let (a, b) = two(args, cv_f64)?; Some(ConstValue::Bool(a <= b)) }
        21 => { let (a, b) = two(args, cv_f64)?; Some(ConstValue::Bool(a >= b)) }
        // ── Legacy bool (22,23,24,27) ──
        22 => { let (a, b) = two(args, cv_bool)?; Some(ConstValue::Bool(V::arith_and_bool(a, b))) }
        23 => { let (a, b) = two(args, cv_bool)?; Some(ConstValue::Bool(V::arith_or_bool(a, b))) }
        24 => { let a = cv_bool(args.get(0)?)?; Some(ConstValue::Bool(V::arith_not_bool(a))) }
        27 => { let (a, b) = two(args, cv_bool)?; Some(ConstValue::Bool(a == b)) }
        // ── Legacy neg (25,26) ──
        25 => { let a = cv_i32(args.get(0)?)?; Some(ConstValue::I32(V::arith_neg_i32(a))) }
        26 => { let a = cv_f64(args.get(0)?)?; Some(ConstValue::F64(V::arith_neg_f64(a))) }

        // ── i64 算术 + 比较 (50-61) ──
        50 => { let (a, b) = two(args, cv_i64)?; Some(ConstValue::I64(V::arith_add_i64(a, b))) }
        51 => { let (a, b) = two(args, cv_i64)?; Some(ConstValue::I64(V::arith_sub_i64(a, b))) }
        52 => { let (a, b) = two(args, cv_i64)?; Some(ConstValue::I64(V::arith_mul_i64(a, b))) }
        53 => { let (a, b) = two(args, cv_i64)?; Some(ConstValue::I64(V::arith_div_i64(a, b))) }
        54 => { let (a, b) = two(args, cv_i64)?; Some(ConstValue::I64(V::arith_mod_i64(a, b))) }
        55 => { let (a, b) = two(args, cv_i64)?; Some(ConstValue::Bool(a == b)) }
        56 => { let (a, b) = two(args, cv_i64)?; Some(ConstValue::Bool(a != b)) }
        57 => { let (a, b) = two(args, cv_i64)?; Some(ConstValue::Bool(a < b)) }
        58 => { let (a, b) = two(args, cv_i64)?; Some(ConstValue::Bool(a > b)) }
        59 => { let (a, b) = two(args, cv_i64)?; Some(ConstValue::Bool(a <= b)) }
        60 => { let (a, b) = two(args, cv_i64)?; Some(ConstValue::Bool(a >= b)) }
        61 => { let a = cv_i64(args.get(0)?)?; Some(ConstValue::I64(V::arith_neg_i64(a))) }
        // ── bitnot (62-63, 76) ──
        62 => { let a = cv_i32(args.get(0)?)?; Some(ConstValue::I32(V::arith_bitnot_i32(a))) }
        63 => { let a = cv_i64(args.get(0)?)?; Some(ConstValue::I64(V::arith_bitnot_i64(a))) }
        76 => { let a = cv_i128(args.get(0)?)?; Some(ConstValue::I128(V::arith_bitnot_i128(a))) }

        // ── i128 算术 + 比较 (64-75) ──
        64 => { let (a, b) = two(args, cv_i128)?; Some(ConstValue::I128(V::arith_add_i128(a, b))) }
        65 => { let (a, b) = two(args, cv_i128)?; Some(ConstValue::I128(V::arith_sub_i128(a, b))) }
        66 => { let (a, b) = two(args, cv_i128)?; Some(ConstValue::I128(V::arith_mul_i128(a, b))) }
        67 => { let (a, b) = two(args, cv_i128)?; Some(ConstValue::I128(V::arith_div_i128(a, b))) }
        68 => { let (a, b) = two(args, cv_i128)?; Some(ConstValue::I128(V::arith_mod_i128(a, b))) }
        69 => { let (a, b) = two(args, cv_i128)?; Some(ConstValue::Bool(a == b)) }
        70 => { let (a, b) = two(args, cv_i128)?; Some(ConstValue::Bool(a != b)) }
        71 => { let (a, b) = two(args, cv_i128)?; Some(ConstValue::Bool(a < b)) }
        72 => { let (a, b) = two(args, cv_i128)?; Some(ConstValue::Bool(a > b)) }
        73 => { let (a, b) = two(args, cv_i128)?; Some(ConstValue::Bool(a <= b)) }
        74 => { let (a, b) = two(args, cv_i128)?; Some(ConstValue::Bool(a >= b)) }
        75 => { let a = cv_i128(args.get(0)?)?; Some(ConstValue::I128(V::arith_neg_i128(a))) }

        // ── 位运算 i32 (77-79) ──
        77 => { let (a, b) = two(args, cv_i32)?; Some(ConstValue::I32(V::arith_bitand_i32(a, b))) }
        78 => { let (a, b) = two(args, cv_i32)?; Some(ConstValue::I32(V::arith_bitor_i32(a, b))) }
        79 => { let (a, b) = two(args, cv_i32)?; Some(ConstValue::I32(V::arith_bitxor_i32(a, b))) }
        // ── 位运算 i64 (80-82) ──
        80 => { let (a, b) = two(args, cv_i64)?; Some(ConstValue::I64(V::arith_bitand_i64(a, b))) }
        81 => { let (a, b) = two(args, cv_i64)?; Some(ConstValue::I64(V::arith_bitor_i64(a, b))) }
        82 => { let (a, b) = two(args, cv_i64)?; Some(ConstValue::I64(V::arith_bitxor_i64(a, b))) }
        // ── 位运算 i128 (83-85) ──
        83 => { let (a, b) = two(args, cv_i128)?; Some(ConstValue::I128(V::arith_bitand_i128(a, b))) }
        84 => { let (a, b) = two(args, cv_i128)?; Some(ConstValue::I128(V::arith_bitor_i128(a, b))) }
        85 => { let (a, b) = two(args, cv_i128)?; Some(ConstValue::I128(V::arith_bitxor_i128(a, b))) }
        // ── 移位 i32 (86-87)：移位量为 i32 ──
        86 => { let a = cv_i32(args.get(0)?)?; let s = cv_i32(args.get(1)?)?; Some(ConstValue::I32(V::arith_shl_i32(a, s))) }
        87 => { let a = cv_i32(args.get(0)?)?; let s = cv_i32(args.get(1)?)?; Some(ConstValue::I32(V::arith_shr_i32(a, s))) }
        // ── 移位 i64 (88-89) ──
        88 => { let a = cv_i64(args.get(0)?)?; let s = cv_i32(args.get(1)?)?; Some(ConstValue::I64(V::arith_shl_i64(a, s))) }
        89 => { let a = cv_i64(args.get(0)?)?; let s = cv_i32(args.get(1)?)?; Some(ConstValue::I64(V::arith_shr_i64(a, s))) }
        // ── 移位 i128 (90-91) ──
        90 => { let a = cv_i128(args.get(0)?)?; let s = cv_i32(args.get(1)?)?; Some(ConstValue::I128(V::arith_shl_i128(a, s))) }
        91 => { let a = cv_i128(args.get(0)?)?; let s = cv_i32(args.get(1)?)?; Some(ConstValue::I128(V::arith_shr_i128(a, s))) }

        // ── 全基本类型算术（92-259）──
        id if id >= 92 && id <= 259 => fold_basic_range(id, args),

        _ => None,
    }
}

/// 整数类型 12 运算折叠宏。
macro_rules! fold_int_arith {
    ($args:expr, $op:expr, $cv:ident, $ext:ident, $ty:ident) => { paste! {
        match $op {
            0 => { let (a, b) = two($args, $ext)?; Some(ConstValue::$cv(crate::Value::[<arith_add_$ty>](a, b))) }
            1 => { let (a, b) = two($args, $ext)?; Some(ConstValue::$cv(crate::Value::[<arith_sub_$ty>](a, b))) }
            2 => { let (a, b) = two($args, $ext)?; Some(ConstValue::$cv(crate::Value::[<arith_mul_$ty>](a, b))) }
            3 => { let (a, b) = two($args, $ext)?; Some(ConstValue::$cv(crate::Value::[<arith_div_$ty>](a, b))) }
            4 => { let (a, b) = two($args, $ext)?; Some(ConstValue::$cv(crate::Value::[<arith_mod_$ty>](a, b))) }
            5 => { let (a, b) = two($args, $ext)?; Some(ConstValue::$cv(crate::Value::[<arith_bitand_$ty>](a, b))) }
            6 => { let (a, b) = two($args, $ext)?; Some(ConstValue::$cv(crate::Value::[<arith_bitor_$ty>](a, b))) }
            7 => { let (a, b) = two($args, $ext)?; Some(ConstValue::$cv(crate::Value::[<arith_bitxor_$ty>](a, b))) }
            8 => { let a = $ext($args.get(0)?)?; let s = cv_i32($args.get(1)?)?; Some(ConstValue::$cv(crate::Value::[<arith_shl_$ty>](a, s))) }
            9 => { let a = $ext($args.get(0)?)?; let s = cv_i32($args.get(1)?)?; Some(ConstValue::$cv(crate::Value::[<arith_shr_$ty>](a, s))) }
            10 => { let a = $ext($args.get(0)?)?; Some(ConstValue::$cv(crate::Value::[<arith_neg_$ty>](a))) }
            11 => { let a = $ext($args.get(0)?)?; Some(ConstValue::$cv(crate::Value::[<arith_bitnot_$ty>](a))) }
            _ => None,
        }
    }};
}

/// 浮点类型 6 运算折叠宏。
macro_rules! fold_float_arith {
    ($args:expr, $op:expr, $cv:ident, $ext:ident, $ty:ident) => { paste! {
        match $op {
            0 => { let (a, b) = two($args, $ext)?; Some(ConstValue::$cv(crate::Value::[<arith_add_$ty>](a, b))) }
            1 => { let (a, b) = two($args, $ext)?; Some(ConstValue::$cv(crate::Value::[<arith_sub_$ty>](a, b))) }
            2 => { let (a, b) = two($args, $ext)?; Some(ConstValue::$cv(crate::Value::[<arith_mul_$ty>](a, b))) }
            3 => { let (a, b) = two($args, $ext)?; Some(ConstValue::$cv(crate::Value::[<arith_div_$ty>](a, b))) }
            4 => { let (a, b) = two($args, $ext)?; Some(ConstValue::$cv(crate::Value::[<arith_mod_$ty>](a, b))) }
            5 => { let a = $ext($args.get(0)?)?; Some(ConstValue::$cv(crate::Value::[<arith_neg_$ty>](a))) }
            _ => None,
        }
    }};
}

/// 基本类型算术折叠（92-259）。
/// 整数 12 类型 × 12 运算（92-235），浮点 4 类型 × 6 运算（236-259）。
/// f16/f128 无 ConstValue 变体，跳过（返回 None）。
fn fold_basic_range(id: u32, args: &[ConstValue]) -> Option<ConstValue> {
    if id <= 235 {
        // 整数：12 类型 × 12 运算（92-235）
        let offset = id - 92;
        let type_idx = (offset / 12) as usize;
        let op_idx = (offset % 12) as usize;
        // op: 0=add 1=sub 2=mul 3=div 4=mod 5=bitand 6=bitor 7=bitxor 8=shl 9=shr 10=neg 11=bitnot
        match type_idx {
            0 => return fold_int_arith!(args, op_idx, I8, cv_i8, i8),
            1 => return fold_int_arith!(args, op_idx, I16, cv_i16, i16),
            2 => return fold_int_arith!(args, op_idx, I32, cv_i32, i32),
            3 => return fold_int_arith!(args, op_idx, I64, cv_i64, i64),
            4 => return fold_int_arith!(args, op_idx, I128, cv_i128, i128),
            5 => return fold_int_arith!(args, op_idx, U8, cv_u8, u8),
            6 => return fold_int_arith!(args, op_idx, U16, cv_u16, u16),
            7 => return fold_int_arith!(args, op_idx, U32, cv_u32, u32),
            8 => return fold_int_arith!(args, op_idx, U64, cv_u64, u64),
            9 => return fold_int_arith!(args, op_idx, U128, cv_u128, u128),
            10 => return fold_int_arith!(args, op_idx, Isize, cv_isize, isize),
            11 => return fold_int_arith!(args, op_idx, Usize, cv_usize, usize),
            _ => return None,
        }
    } else {
        // 浮点：4 类型 × 6 运算（236-259）
        let offset = id - 236;
        let type_idx = (offset / 6) as usize;
        let op_idx = (offset % 6) as usize;
        // op: 0=add 1=sub 2=mul 3=div 4=mod 5=neg
        // f16(type_idx=0) 和 f128(type_idx=3) 无 ConstValue 变体
        match type_idx {
            1 => return fold_float_arith!(args, op_idx, F32, cv_f32, f32),
            2 => return fold_float_arith!(args, op_idx, F64, cv_f64, f64),
            _ => return None,
        }
    }
}

// =========================================================================
// OptimizerContext — 优化期变换记录
// =========================================================================

/// 优化期累积的变换：dead 集与 redirect 映射。
/// 固定点收敛后由 DataFlowGraph::rebuild 消费，一次性重建图。
#[derive(Default)]
pub struct OptimizerContext {
    /// 死节点集（DCE 标记）
    pub dead: FxHashSet<NodeId>,
    /// 重定向映射：old_node_id → new_node_id（CSE/CopyProp 产生）
    pub redirect: FxHashMap<NodeId, NodeId>,
    /// ConstFold 是否修改了节点（直接修改原节点，不产生 redirect）
    pub mutated: bool,
    /// ConstFold 本轮折叠的节点数（调试用）
    pub cf_folded_count: usize,
}

impl OptimizerContext {
    /// 递归解析重定向到最终目标。
    #[inline]
    pub fn resolve(&self, id: NodeId) -> NodeId {
        let mut cur = id;
        while let Some(&next) = self.redirect.get(&cur) {
            cur = next;
        }
        cur
    }

    /// 节点是否存活（未死且未被重定向消除）。
    #[inline]
    pub fn is_live(&self, id: NodeId) -> bool {
        !self.dead.contains(&id) && !self.redirect.contains_key(&id)
    }

    /// 本轮是否有变换。
    #[inline]
    pub fn has_changes(&self) -> bool {
        self.mutated || !self.dead.is_empty() || !self.redirect.is_empty()
    }
}

/// 检查节点是否有副作用（不可被 CSE/CopyProp/DCE 消除或重定向）。
fn has_side_effect(graph: &DataFlowGraph, idx: usize) -> bool {
    graph.writeback_targets.get(idx).map_or(false, |o| o.is_some())
    || graph.field_set_names.get(idx).map_or(false, |o| o.is_some())
    || graph.global_store_slots.get(idx).map_or(false, |o| o.is_some())
    || graph.control_signal_nodes.get(idx).map_or(false, |o| o.is_some())
    || graph.ffi_call_names.get(idx).map_or(false, |o| o.is_some())
    || graph.tail_call_flags.get(idx).copied().unwrap_or(false)
}

/// 收集所有 writeback 目标节点 ID。
/// 这些节点的运行时值会被 writeback 覆盖，不可作为 CSE 合并目标或 ConstFold 常量源。
fn collect_writeback_targets(graph: &DataFlowGraph) -> FxHashSet<NodeId> {
    let mut set = FxHashSet::default();
    for opt_wt in &graph.writeback_targets {
        if let Some(wt) = opt_wt {
            set.insert(*wt);
        }
    }
    set
}

// =========================================================================
// compute_live_set — 反向可达性分析
// =========================================================================

/// 计算活跃节点集：从所有子图的 return_node/cond_node/iter_next_node 反向遍历 inputs。
/// 使用 ctx.resolve 解析重定向，确保 redirected 节点的 inputs 不被遍历。
/// 同时遍历 per-node 元数据中的 NodeId 引用（gate_branches/select_infos/writeback_targets）。
pub fn compute_live_set(graph: &DataFlowGraph, ctx: &OptimizerContext) -> FxHashSet<NodeId> {
    let mut live: FxHashSet<NodeId> = FxHashSet::default();
    let mut stack: Vec<NodeId> = Vec::new();

    // 辅助：resolve + insert + push
    let add = |id: NodeId, live: &mut FxHashSet<NodeId>, stack: &mut Vec<NodeId>| {
        let r = ctx.resolve(id);
        if live.insert(r) { stack.push(r); }
    };

    // 种子：所有子图的 return_node + entry_node + cond_node + iter_next_node
    for sg in &graph.subgraphs {
        for &raw in &[sg.return_node, sg.entry_node] {
            add(raw, &mut live, &mut stack);
        }
        if let Some(c) = sg.cond_node { add(c, &mut live, &mut stack); }
        if let Some(n) = sg.iter_next_node { add(n, &mut live, &mut stack); }
        // defer_table: trigger_node + captured_inputs
        for entry in &sg.defer_table {
            add(entry.trigger_node, &mut live, &mut stack);
            for &cap in &entry.captured_inputs { add(cap, &mut live, &mut stack); }
        }
        // event_source_decls: node
        for decl in &sg.event_source_decls {
            add(decl.node, &mut live, &mut stack);
        }
    }
    // 事件源声明节点保留
    for opt_n in &graph.await_event_sources {
        if let Some(n) = opt_n { add(*n, &mut live, &mut stack); }
    }
    // 副作用节点保留（不可被 DCE 删除）
    for idx in 0..graph.nodes.len() {
        if has_side_effect(graph, idx) {
            add(NodeId(idx as u32), &mut live, &mut stack);
        }
    }

    while let Some(n) = stack.pop() {
        let idx = n.0 as usize;
        let node = graph.nodes[idx];

        // 1. 遍历 node.inputs
        let inputs = graph.inputs_pool.get(node.inputs_offset, node.input_count);
        for &input in inputs {
            add(input, &mut live, &mut stack);
        }

        // 2. 遍历 per-node 元数据中的 NodeId 引用
        // gate_branches: condition_input + branches params
        if let Some(gb) = graph.gate_branches.get(idx).and_then(|o| o.as_ref()) {
            add(gb.condition_input, &mut live, &mut stack);
            for (_, _, params) in &gb.branches {
                for &p in params { add(p, &mut live, &mut stack); }
            }
        }
        // select_infos: event_source_node
        if let Some(si) = graph.select_infos.get(idx).and_then(|o| o.as_ref()) {
            for sb in &si.branches {
                add(sb.event_source_node, &mut live, &mut stack);
            }
        }
        // writeback_targets
        if let Some(Some(wt)) = graph.writeback_targets.get(idx).map(|o| o.as_ref()) {
            add(*wt, &mut live, &mut stack);
        }
    }
    live
}

// =========================================================================
// Pass: ConstFold — 常量折叠
// =========================================================================

/// ConstFold pass：BinOp/UnOp 全 Const 输入 → 折叠为 Const。
/// 直接修改原节点为 Const（不创建新节点，保持 NodeId 不变，确保在 node_range 内）。
/// 单轮内反复扫描直到无新折叠（链式折叠：A→Const 后 B 依赖 A 也可折叠）。
pub fn pass_const_fold(graph: &mut DataFlowGraph, ctx: &mut OptimizerContext) {
    let node_count = graph.nodes.len();
    let wb_targets = collect_writeback_targets(graph);
    let mut total_folded = 0usize;

    loop {
        let mut folded_this_round: Vec<(usize, ConstValue)> = Vec::new();

        for idx in 0..node_count {
            let id = NodeId(idx as u32);
            if !ctx.is_live(id) { continue; }
            let node = graph.nodes[idx];
            if node.kind == NodeKind::Const { continue; }
            // 副作用节点不可折叠：writeback 目标的输入在运行时会变，
            // 不能用初始常量值替代运行时计算。
            if has_side_effect(graph, idx) { continue; }

            let inputs = graph.inputs_pool.get(node.inputs_offset, node.input_count);
            let mut arg_values: Vec<ConstValue> = Vec::with_capacity(inputs.len());
            let mut all_const = true;
            for &input in inputs {
                let resolved = ctx.resolve(input);
                // writeback 目标的运行时值会变，不可作为常量源
                if wb_targets.contains(&resolved) { all_const = false; break; }
                let ridx = resolved.0 as usize;
                match graph.const_values.get(ridx).and_then(|o| o.as_ref()) {
                    Some(cv) => arg_values.push(cv.clone()),
                    None => { all_const = false; break; }
                }
            }
            if !all_const || arg_values.is_empty() { continue; }

            if let Some(result) = try_fold(node.compute_fn, &arg_values) {
                folded_this_round.push((idx, result));
            }
        }

        if folded_this_round.is_empty() { break; }

        // 直接修改原节点为 Const
        for (idx, cv) in folded_this_round {
            let new_offset = graph.inputs_pool.push(&[]);
            graph.nodes[idx] = Node {
                kind: NodeKind::Const,
                input_count: 0,
                inputs_offset: new_offset,
                compute_fn: ComputeFnId(0),
            };
            graph.const_values[idx] = Some(cv);
        }
        total_folded += 1;
    }

    // ConstFold 直接修改 graph，不设置 ctx.mutated（避免固定点不收敛）
    // 链式折叠已在单轮内完成，无需外层固定点迭代
}

// =========================================================================
// Pass: CSE — 公共子表达式消除
// =========================================================================

/// CSE pass：纯节点 (compute_fn, resolved_inputs) 相同 → 合并。
/// 首个出现者保留，后续 redirect 到首个。
pub fn pass_cse(graph: &DataFlowGraph, ctx: &mut OptimizerContext, pure_set: &FxHashSet<ComputeFnId>) {
    let mut seen: FxHashMap<(ComputeFnId, Vec<NodeId>), NodeId> = FxHashMap::default();
    let wb_targets = collect_writeback_targets(graph);

    for (idx, node) in graph.nodes.iter().enumerate() {
        let id = NodeId(idx as u32);
        if !ctx.is_live(id) { continue; }
        // 跳过已被 redirect 的节点（避免反复产生相同 redirect）
        if ctx.redirect.contains_key(&id) { continue; }
        if !pure_set.contains(&node.compute_fn) { continue; }
        if node.kind == NodeKind::Gate { continue; }
        // 副作用节点不可重定向（writeback/field_set/global_store 等）
        if has_side_effect(graph, idx) { continue; }
        // writeback 目标的运行时值会变，不可作为 CSE 合并目标或源
        if wb_targets.contains(&id) { continue; }

        let inputs = graph.inputs_pool.get(node.inputs_offset, node.input_count);
        let resolved: Vec<NodeId> = inputs.iter().map(|&i| ctx.resolve(i)).collect();
        let key = (node.compute_fn, resolved);
        if let Some(&existing) = seen.get(&key) {
            ctx.redirect.insert(id, existing);
        } else {
            seen.insert(key, id);
        }
    }
}

// =========================================================================
// Pass: CopyProp — 拷贝传播
// =========================================================================

/// 透传 compute_fn 集合：单输入、输出=输入。
/// noop_compute_real(0) 是纯透传。
fn passthrough_set() -> FxHashSet<ComputeFnId> {
    let mut s = FxHashSet::default();
    s.insert(ComputeFnId(0)); // noop_compute_real
    s
}

/// CopyProp pass：透传节点 redirect 到其唯一 input。
pub fn pass_copy_prop(graph: &DataFlowGraph, ctx: &mut OptimizerContext) {
    let passthrough = passthrough_set();
    for (idx, node) in graph.nodes.iter().enumerate() {
        let id = NodeId(idx as u32);
        if !ctx.is_live(id) { continue; }
        // 跳过已被 redirect 的节点（避免反复产生相同 redirect）
        if ctx.redirect.contains_key(&id) { continue; }
        if node.input_count != 1 { continue; }
        if !passthrough.contains(&node.compute_fn) { continue; }
        // 副作用节点不可重定向（writeback/field_set/global_store 等）
        if has_side_effect(graph, idx) { continue; }
        let inputs = graph.inputs_pool.get(node.inputs_offset, node.input_count);
        let src = ctx.resolve(inputs[0]);
        // 避免自环
        if src != id {
            ctx.redirect.insert(id, src);
        }
    }
}

// =========================================================================
// Pass: DCE — 死代码消除
// =========================================================================

/// 收集节点的所有 inputs 和元数据中的 NodeId 引用（resolve 后）。
fn collect_refs(graph: &DataFlowGraph, ctx: &OptimizerContext, idx: usize, out: &mut Vec<NodeId>) {
    let node = graph.nodes[idx];
    let inputs = graph.inputs_pool.get(node.inputs_offset, node.input_count);
    for &input in inputs {
        out.push(ctx.resolve(input));
    }
    if let Some(gb) = graph.gate_branches.get(idx).and_then(|o| o.as_ref()) {
        out.push(ctx.resolve(gb.condition_input));
        for (_, _, params) in &gb.branches {
            for &p in params { out.push(ctx.resolve(p)); }
        }
    }
    if let Some(si) = graph.select_infos.get(idx).and_then(|o| o.as_ref()) {
        for sb in &si.branches {
            out.push(ctx.resolve(sb.event_source_node));
        }
    }
    if let Some(Some(wt)) = graph.writeback_targets.get(idx).map(|o| o.as_ref()) {
        out.push(ctx.resolve(*wt));
    }
}

/// DCE pass：标记不可达的纯计算节点为 dead。
/// 三步策略：
/// 1. 计算live set，标记不在live set中的纯计算节点为dead候选
/// 2. 保留传播：从所有保留节点（非dead、非redirect key）的inputs反向遍历，
///    把被保留节点依赖的dead候选从dead集中移除
/// 3. 处理redirect目标为dead的情况：redirect目标dead则redirect key也dead
pub fn pass_dce(graph: &DataFlowGraph, ctx: &mut OptimizerContext, pure_set: &FxHashSet<ComputeFnId>) {
    let live = compute_live_set(graph, ctx);

    // Step 1: 标记不在live set中的纯计算节点为dead候选
    for (idx, node) in graph.nodes.iter().enumerate() {
        let id = NodeId(idx as u32);
        if live.contains(&id) { continue; }
        if !ctx.is_live(id) { continue; }
        let is_pure_calc = match node.kind {
            NodeKind::BinOp | NodeKind::UnOp | NodeKind::FieldAccess => {
                pure_set.contains(&node.compute_fn)
            }
            NodeKind::Const | NodeKind::Call | NodeKind::Gate
            | NodeKind::Await | NodeKind::EventSource => false,
        };
        if is_pure_calc {
            ctx.dead.insert(id);
        }
    }

    // Step 2: 保留传播 — 从所有保留节点的引用反向遍历，移除可达的dead候选
    // 保留节点 = 非dead、非redirect key 的节点（这些节点会留在graph中）
    // 它们的inputs必须保留，否则rebuild时panic
    let mut preserve_stack: Vec<NodeId> = Vec::new();
    let mut refs_buf: Vec<NodeId> = Vec::new();
    for idx in 0..graph.nodes.len() {
        let id = NodeId(idx as u32);
        if ctx.dead.contains(&id) || ctx.redirect.contains_key(&id) { continue; }
        refs_buf.clear();
        collect_refs(graph, ctx, idx, &mut refs_buf);
        for r in &refs_buf {
            if ctx.dead.remove(r) { preserve_stack.push(*r); }
        }
    }
    while let Some(n) = preserve_stack.pop() {
        refs_buf.clear();
        collect_refs(graph, ctx, n.0 as usize, &mut refs_buf);
        for r in &refs_buf {
            if ctx.dead.remove(r) { preserve_stack.push(*r); }
        }
    }

    // Step 3: 处理redirect目标为dead的情况
    // 如果redirect的resolve目标是dead，redirect key也应加入dead集
    // （否则rebuild时resolve(redirect_key)=dead_target，old_to_new[dead_target]=None → panic）
    loop {
        let mut changed = false;
        let keys: Vec<NodeId> = ctx.redirect.keys().copied().collect();
        for key in keys {
            if ctx.dead.contains(&key) { continue; }
            let target = ctx.resolve(key);
            if ctx.dead.contains(&target) {
                ctx.dead.insert(key);
                changed = true;
            }
        }
        if !changed { break; }
    }
}

// =========================================================================
// 固定点迭代驱动器
// =========================================================================

/// 优化入口：对 graph 执行固定点迭代优化。
/// 顺序：ConstFold → CSE → CopyProp → DCE
/// 循环直到一轮无变换，最后应用晚期重建。
pub fn optimize(graph: &mut DataFlowGraph) {
    let pure_set = crate::Ir::pure_compute_fn_set();
    let no_fold = std::env::var("GLUE_NO_FOLD").is_ok();
    let no_cse = std::env::var("GLUE_NO_CSE").is_ok();
    let no_copy = std::env::var("GLUE_NO_COPY").is_ok();
    let no_dce = std::env::var("GLUE_NO_DCE").is_ok();
    let mut max_iter = 50;

    loop {
        let mut ctx = OptimizerContext::default();
        if !no_fold { pass_const_fold(graph, &mut ctx); }
        if !no_cse  { pass_cse(graph, &mut ctx, &pure_set); }
        if !no_copy { pass_copy_prop(graph, &mut ctx); }
        if !no_dce  { pass_dce(graph, &mut ctx, &pure_set); }

        if !ctx.has_changes() { break; }

        // 应用本轮变换（晚期压缩重建）
        let _old_to_new = graph.rebuild(&ctx.dead, &ctx.redirect);

        max_iter -= 1;
        if max_iter == 0 {
            eprintln!("Optimizer: 达到最大迭代次数，提前终止");
            break;
        }
    }
}
