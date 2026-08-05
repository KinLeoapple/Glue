//! Builder.rs — IR builder (AST + SemaResult -> DataFlowGraph)
//!
//! Split from Ir.rs. Contains IrBuilder struct, all compile_* methods,
//! and build() entry point orchestrating the multi-pass compilation pipeline.
//! Depends on crate::ir::Ir (IR data structures).

use crate::ir::Ir::*;
use std::sync::Arc;


/// 2. 编译每个函数的函数体
/// 3. 计算 fan-out（downstreams）
///
/// 本阶段实现核心 Expr 变体编译（Const/BinOp/Call/FieldAccess/Ident/Block）。
/// 控制流（If/Match/Loop）留到阶段 4。
/// compute_fn 用 noop_compute 占位，Engine 阶段替换为类型特化函数。
pub struct IrBuilder<'a> {
    pub sema: &'a crate::sema::Sema::SemaResult,
    pub module: &'a crate::ast::Ast::Module<'a>,
    /// builtin 模块列表（预编译，函数注册到 func_subgraphs）
    pub builtin_modules: Vec<&'a crate::ast::Ast::Module<'a>>,
    /// 当前正在编译的 builtin 模块（None = 用户模块）
    pub compiling_builtin: Option<&'a crate::ast::Ast::Module<'a>>,
    /// 静态分析报告（仅 entry 模块，None = 未接入分析器）
    /// IrBuilder 在编译 entry 模块时查询报告跳过死代码/死函数，
    /// 执行内联展开和栈分配标记。builtin 模块编译不受影响。
    pub analysis: Option<&'a crate::pass::Analyzer::AnalysisReport>,
    pub graph: DataFlowGraph,
    /// 函数名 → 子图 id 映射（Call 编译时查找绑定 call_target）
    pub func_subgraphs: rustc_hash::FxHashMap<String, SubGraphId>,
    /// 类型方法子图表：(type_id, method_idx) → SubGraphId
    /// type_id = FIRST_DYNAMIC_TYPE_ID + type_def_index，method_idx = 方法在 TypeDefInfo.methods 中的位置
    /// 替代 func_subgraphs 中 "TypeName.method" 字符串键
    pub method_subgraphs: rustc_hash::FxHashMap<(u16, u16), SubGraphId>,
    /// trait 默认方法子图表（单态化）：(type_id, trait_def_idx, method_idx) → SubGraphId
    /// 为每个实现 trait 的类型生成特化子图，使 self 在 body 中有具体类型信息。
    pub trait_default_subgraphs: rustc_hash::FxHashMap<(u16, u16, u16), SubGraphId>,
    /// 当前编译的 trait 默认方法特化版本中 self 的具体类型名。
    /// 为 None 时表示不在 trait 默认方法上下文中。
    /// expr_type_name/expr_type_id 在 sema 查找失败时，若 self_expr_types 有对应 ExprId
    /// （即 expr 是 Ident("self")），返回此类型名，使 self.method() 能静态绑定。
    pub trait_self_type: Option<String>,
    /// 当前正在编译的函数子图 id（defer 注册用）
    pub current_function_sg: Option<SubGraphId>,
    /// 循环上下文栈：栈顶为当前循环的上下文（continue 跳转目标 + For 迭代器节点）
    pub loop_stack: Vec<LoopContext>,
    /// 变量作用域栈：变量名 → 产出该变量值的 NodeId
    pub scope_stack: Vec<rustc_hash::FxHashMap<String, NodeId>>,
    /// 捕获变量作用域栈：每层 lambda 的捕获变量 (name, outer_node) 列表。
    /// 用于 Assignment 判定是否需 WriteBack：捕获变量赋值需写回外层节点。
    pub captured_scopes: Vec<Vec<(String, NodeId)>>,
    /// 被内层 lambda 捕获的本地变量：变量名 → 捕获时的原始节点 ID。
    /// 外层 Assignment 对这些变量赋值时需生成 WriteBack 到原始节点，
    /// 使闭包在 same_function 调用时能从父帧读到最新值（引用捕获语义）。
    pub captured_vars: rustc_hash::FxHashMap<String, NodeId>,
    /// 类型字段作用域栈：构造器/类型名 → 字段名列表（与 scope_stack 平行管理）
    pub type_scope_stack: Vec<rustc_hash::FxHashMap<String, TypeFieldInfo>>,
    /// 当前正在编译的函数的 function_id（用于子图标记，root_frame_ptr 继承判定）
    pub current_function_id: u32,
    /// 当前正在编译的子图的节点起始 NodeId（用于判断变量是否为外层变量）
    pub current_sg_start: u32,
    /// 当前语句块中前一个效果节点（用于让后续效果节点依赖前一个，保证语句顺序）
    pub current_effect: Option<NodeId>,
    /// 当前是否在尾位置（尾调用分析用）。
    /// compile_function 入口设 true，Return value 设 true，
    /// Block trailing 继承，If/Match 分支继承，参数/条件/赋值右侧设 false。
    pub in_tail_position: bool,
    /// 编译期错误列表（未实现特性、找不到函数等，编译结束后可检查）
    pub errors: Vec<String>,
    /// 全局变量名 → slot index 映射（顶层 var/val 声明，跨函数共享）
    pub global_var_slots: rustc_hash::FxHashMap<String, u32>,
    /// 顶层 var/val 声明语句列表（在 entry 函数编译时注入初始化代码）
    /// 元素：(模块索引, StmtId)，None = entry 模块，Some(i) = builtin_modules[i]
    pub top_level_var_decls: Vec<(Option<usize>, crate::ast::Ast::StmtId)>,
}

// =========================================================================
// 内置构造/方法/cast 分派注册表（数据驱动，消除方法名/类型名特判分支）
// =========================================================================

/// cast 转换对注册表：不遵循默认 `__cast_{S}_to_{T}` 命名规则的转换对。
/// 新增转换对只需追加一行，无需改编译分支。
const SPECIAL_CAST_PAIRS: &[(&str, &str, &str)] = &[
    // (source, target, mangled_fn)
    ("u8[]", "str", "__cast_bytes_to_str"),
    ("bytes", "str", "__cast_bytes_to_str"),
    ("char", "str", "__cast_char_to_str"),
];

/// 解析 cast 函数名：先查特殊转换对注册表，未命中则按默认命名规则生成。
fn cast_mangled_name(source: &str, target: &str) -> String {
    for &(s, t, fn_name) in SPECIAL_CAST_PAIRS {
        if s == source && t == target {
            return fn_name.to_string();
        }
    }
    format!("__cast_{}_to_{}", source, target)
}

/// 内置构造器的降级策略。
///
/// 新增内置构造器只需在 `BUILTIN_CTORS` 追加一行，无需新增 if 分支。
enum BuiltinCtorLower {
    /// Ok(val)：单节点 compute_throw_ok（idx 44）
    Ok,
    /// Err(...)：内层 record_construct + 外层 throw_err 包装（idx 45）
    Err,
    /// channel(capacity)：单节点 compute_channel_create（idx 283）
    Channel,
}

/// 内置构造器分派表：构造器名 → 降级策略。
const BUILTIN_CTORS: &[(&str, BuiltinCtorLower)] = &[
    ("Ok", BuiltinCtorLower::Ok),
    ("Err", BuiltinCtorLower::Err),
    ("channel", BuiltinCtorLower::Channel),
];

impl<'a> IrBuilder<'a> {
    /// 创建构建器。
    pub fn new(sema: &'a crate::sema::Sema::SemaResult, module: &'a crate::ast::Ast::Module<'a>) -> Self {
        Self {
            sema,
            module,
            builtin_modules: Vec::new(),
            compiling_builtin: None,
            analysis: None,
            graph: DataFlowGraph::new(),
            func_subgraphs: rustc_hash::FxHashMap::default(),
            method_subgraphs: rustc_hash::FxHashMap::default(),
            trait_default_subgraphs: rustc_hash::FxHashMap::default(),
            trait_self_type: None,
            current_function_sg: None,
            loop_stack: Vec::new(),
            scope_stack: Vec::new(),
            captured_scopes: Vec::new(),
            captured_vars: rustc_hash::FxHashMap::default(),
            current_function_id: 0,
            current_sg_start: 0,
            current_effect: None,
            in_tail_position: false,
            errors: Vec::new(),
            global_var_slots: rustc_hash::FxHashMap::default(),
            top_level_var_decls: Vec::new(),
            type_scope_stack: Vec::new(),
        }
    }

    /// 设置 builtin 模块列表（builder 风格，链式调用）。
    pub fn with_builtins(
        mut self,
        modules: Vec<&'a crate::ast::Ast::Module<'a>>,
    ) -> Self {
        self.builtin_modules = modules;
        self
    }

    /// 注入静态分析报告（builder 风格，链式调用）。
    /// 报告仅对 entry 模块有效，IrBuilder 编译 entry 模块时查询报告
    /// 跳过死代码/死函数，执行内联与栈分配标记。
    pub fn with_analysis(
        mut self,
        analysis: &'a crate::pass::Analyzer::AnalysisReport,
    ) -> Self {
        self.analysis = Some(analysis);
        self
    }

    /// 当前是否在编译 entry 模块（而非 builtin）。
    /// 分析报告仅覆盖 entry 模块，builtin 编译不查询报告。
    #[inline]
    fn is_compiling_entry(&self) -> bool {
        self.compiling_builtin.is_none()
    }

    /// 查询语句是否为死代码（仅在编译 entry 模块时查询）。
    #[inline]
    fn is_dead_stmt(&self, stmt_id: crate::ast::Ast::StmtId) -> bool {
        self.is_compiling_entry()
            && self.analysis.map_or(false, |r| r.dead_code.dead_stmts.contains(&stmt_id))
    }

    /// 查询函数是否为死函数（仅在编译 entry 模块时查询）。
    /// FuncId = entry 模块 declarations 索引。
    #[inline]
    fn is_dead_func(&self, decl_idx: usize) -> bool {
        self.is_compiling_entry()
            && self.analysis.map_or(false, |r| r.dead_func.dead.contains(&crate::pass::Analyzer::FuncId(decl_idx as u32)))
    }

    /// 查询表达式是否为内联候选的调用点。
    /// 返回被调函数的 FuncId，IrBuilder 应展开其 body 而非 launch 子图。
    #[inline]
    fn inline_target(&self, expr_id: crate::ast::Ast::ExprId) -> Option<crate::pass::Analyzer::FuncId> {
        if !self.is_compiling_entry() {
            return None;
        }
        let report = self.analysis?;
        report.inline.expansions.get(&expr_id).copied()
    }

    /// 查询表达式是否标记为栈分配。
    #[inline]
    fn should_stack_alloc(&self, expr_id: crate::ast::Ast::ExprId) -> bool {
        self.is_compiling_entry()
            && self.analysis.map_or(false, |r| r.stack_alloc.candidates.contains(&expr_id))
    }

    /// 返回当前正在编译的模块（builtin 优先，否则用户模块）。
    fn current_module(&self) -> &'a crate::ast::Ast::Module<'a> {
        self.compiling_builtin.unwrap_or(self.module)
    }

    /// 进入新作用域（变量和类型字段同步 push）。
    fn enter_scope(&mut self) {
        self.scope_stack.push(rustc_hash::FxHashMap::default());
        self.type_scope_stack.push(rustc_hash::FxHashMap::default());
    }

    /// 退出作用域（变量和类型字段同步 pop）。
    fn exit_scope(&mut self) {
        self.scope_stack.pop();
        self.type_scope_stack.pop();
    }

    /// 在当前作用域注册类型字段信息（构造器名/类型名 → TypeFieldInfo）。
    fn bind_type_fields(&mut self, name: &str, info: TypeFieldInfo) {
        if let Some(scope) = self.type_scope_stack.last_mut() {
            scope.insert(name.to_string(), info);
        }
    }

    /// 从作用域栈逐层查找类型字段信息（构造器名或类型名）。
    fn lookup_type_fields(&self, name: &str) -> Option<TypeFieldInfo> {
        for scope in self.type_scope_stack.iter().rev() {
            if let Some(info) = scope.get(name) {
                return Some(info.clone());
            }
        }
        None
    }

    /// 绑定变量名到 NodeId（当前作用域）。
    fn bind_var(&mut self, name: &str, node_id: NodeId) {
        if let Some(scope) = self.scope_stack.last_mut() {
            scope.insert(name.to_string(), node_id);
        }
    }

    /// 查找变量绑定的 NodeId（从内到外查）。
    fn lookup_var(&self, name: &str) -> Option<NodeId> {
        for scope in self.scope_stack.iter().rev() {
            if let Some(&node_id) = scope.get(name) {
                return Some(node_id);
            }
        }
        // 全局变量：返回 None，由调用方通过 is_global_var + global_var_slots 处理
        None
    }

    /// 检查名称是否为全局变量，返回 slot index。
    fn lookup_global_var(&self, name: &str) -> Option<u32> {
        self.global_var_slots.get(name).copied()
    }

    /// 编译全局变量读取节点（compute_global_load, idx 270）。
    /// 无输入，运行时从 global_var_storage[slot] 读取。
    fn compile_global_load(&mut self, slot: u32) -> NodeId {
        // 追加 current_effect 作为隐式依赖输入，确保 load 在前序 global_store 完成后才执行。
        // compute_global_load 不读取输入值，此 input 仅用于调度器排序。
        let (input_count, inputs_offset) = match self.current_effect {
            Some(eff) => (1, self.graph.inputs_pool.push(&[eff])),
            None => (0, self.graph.inputs_pool.push(&[])),
        };
        let node = self.graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count,
            inputs_offset,
            compute_fn: CF_GLOBAL_LOAD,
        });
        self.graph.set_global_load_slot(node, slot);
        node
    }

    /// 编译全局变量写入节点（compute_global_store, idx 271）。
    /// inputs[0] = 值来源节点，运行时写入 global_var_storage[slot]。
    fn compile_global_store(&mut self, val_node: NodeId, slot: u32) -> NodeId {
        let inputs_offset = self.graph.inputs_pool.push(&[val_node]);
        let node = self.graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: 1,
            inputs_offset,
            compute_fn: CF_GLOBAL_STORE,
        });
        self.graph.set_global_store_slot(node, slot);
        node
    }

    /// 判断 NodeId 是否在当前子图范围内（非外层变量）。
    fn is_in_current_subgraph(&self, node: NodeId) -> bool {
        node.0 >= self.current_sg_start
    }

    /// 编译 WriteBack 节点：赋值外层变量，通过 root_frame_ptr 写回函数根帧。
    /// 返回 WriteBack 节点的 NodeId。
    fn compile_writeback_node(&mut self, val_node: NodeId, target_outer: NodeId) -> NodeId {
        let wb_off = self.graph.inputs_pool.push(&[val_node]);
        let wb_node = self.graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: 1,
            inputs_offset: wb_off,
            compute_fn: CF_WRITEBACK, // compute_writeback
        });
        self.graph.set_writeback_target(wb_node, target_outer);
        wb_node
    }

    /// CompoundAssignOp → 对应二元运算的 ComputeFnId。
    ///
    /// 通过 arith_base 按具体类型查表，算术运算用 offset 0-4，
    /// 位运算用 offset 5-9（仅整数）。
    fn compound_assign_op_to_compute_fn(
        &mut self,
        op: crate::ast::Ast::CompoundAssignOp,
        target_expr: crate::ast::Ast::ExprId,
    ) -> ComputeFnId {
        use crate::ast::Ast::CompoundAssignOp;
        let ty = self.expr_type_name(target_expr).unwrap_or("i32");
        let is_float = crate::Value::ScalarTag::from_name(ty).and_then(scalar_meta).map(|m| m.is_float).unwrap_or(false);
        let base = Self::arith_base(ty).unwrap_or(CF_ADD_I32_FULL.0); // 回退 i32
        // 整数 offset: add(0) sub(1) mul(2) div(3) mod(4) bitand(5) bitor(6) bitxor(7) shl(8) shr(9)
        // 浮点 offset: add(0) sub(1) mul(2) div(3) mod(4) neg(5)
        let offset = match op {
            CompoundAssignOp::AddAssign => 0,
            CompoundAssignOp::SubAssign => 1,
            CompoundAssignOp::MulAssign => 2,
            CompoundAssignOp::DivAssign => 3,
            CompoundAssignOp::ModAssign => 4,
            // 位运算仅整数支持；浮点走到这里表示 sema 未拦截，回退到 i32 路径
            CompoundAssignOp::BitAndAssign if !is_float => 5,
            CompoundAssignOp::BitOrAssign if !is_float => 6,
            CompoundAssignOp::BitXorAssign if !is_float => 7,
            CompoundAssignOp::ShlAssign if !is_float => 8,
            CompoundAssignOp::ShrAssign if !is_float => 9,
            // 浮点不应出现位运算；若出现则回退 noop
            _ => return CF_NOOP,
        };
        ComputeFnId(base + offset)
    }

    /// 注册占位子图（节点范围待编译后填充）。
    pub fn register_subgraph_placeholder(
        &mut self,
        _name: &str,
        param_count: u8,
        is_async: bool,
    ) -> SubGraphId {
        let id = SubGraphId(self.graph.subgraphs.len() as u32);
        let sg = SubGraph {
            id,
            node_range: (NodeId(0), NodeId(0)),
            param_count,
            entry_node: NodeId(0),
            return_node: NodeId(0),
            has_suspend: is_async,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: id.0,
            iter_next_node: None,
            upvalue_count: 0,
            upvalue_outer_nodes: Vec::new(),
        };
        self.graph.subgraphs.push(sg);
        id
    }

    /// 编译表达式为 Node，返回其 NodeId。
    pub fn compile_expr(&mut self, expr_id: crate::ast::Ast::ExprId) -> NodeId {
        let spanned = self.current_module().arena.expr(expr_id);
        let expr = &spanned.node;
        match expr {
            // 常量
            crate::ast::Ast::Expr::IntLit { .. }
            | crate::ast::Ast::Expr::FloatLit { .. }
            | crate::ast::Ast::Expr::BoolLit(_)
            | crate::ast::Ast::Expr::CharLit(_)
            | crate::ast::Ast::Expr::StrLit(_)
            | crate::ast::Ast::Expr::NullLit
            | crate::ast::Ast::Expr::VoidLit => self.compile_const_with_value(expr_id),

            // 变量引用
            crate::ast::Ast::Expr::Ident(name) => match self.lookup_var(name) {
                Some(node_id) => {
                    // 当 current_effect 存在时，创建 CF_SEQ 依赖节点确保变量读取在前序副作用完成后执行。
                    // 这防止表达式在 while/loop 等子图的 WriteBack 更新变量值之前读取旧值。
                    // 与 compile_global_load 的 current_effect 依赖机制一致。
                    match self.current_effect {
                        Some(eff) => self.chain_effects(Some(eff), node_id),
                        None => node_id,
                    }
                }
                None => match self.lookup_global_var(name) {
                    Some(slot) => self.compile_global_load(slot),
                    None => {
                        // nullary ADT/类型构造器检测：当 Ident 既非局部变量也非全局变量，
                        // 检查是否为无参构造器（如 `Lt`/`Leaf`/`Red`），编译为无参构造节点。
                        // 有参构造器（field_names 非空）不在此处理（应走 Call 路径带参数）。
                        // Newtype 总有 inner 值，不可能是 nullary。
                        let tf_info = self.lookup_constructor_field_names(name)
                            .or_else(|| self.lookup_type_field_names(name));
                        match tf_info {
                            Some(info) if info.field_names.is_empty() && info.kind != RecordLitKind::Newtype => {
                                let inputs_offset = self.graph.inputs_pool.push(&[]);
                                let node = self.graph.add_node(Node {
                                    kind: NodeKind::BinOp,
                                    input_count: 0,
                                    inputs_offset,
                                    compute_fn: CF_RECORD_CONSTRUCT, // record_construct
                                });
                                self.graph.set_record_lit_info(node, RecordLitInfo {
                                    type_name: info.type_name.clone(),
                                    field_names: Vec::new(),
                                    constructor: name.to_string(),
                                    kind: info.kind,
                                });
                                node
                            }
                            _ => self.compile_const(),
                        }
                    }
                },
            },

            // 二元运算
            crate::ast::Ast::Expr::Binary { op, lhs, rhs } => {
                self.compile_binary(*op, *lhs, *rhs)
            }

            // 函数调用
            crate::ast::Ast::Expr::Call { callee, args, type_args } => {
                // __cast_to<T>(x) / __cast_try_to<T>(x)：根据源/目标类型映射到具体 cast 函数
                if let crate::ast::Ast::Expr::Ident(name) = &self.current_module().arena.expr(*callee).node {
                    if matches!(*name, "__cast_to" | "__cast_try_to") {
                        return self.compile_cast_call(*name, args, type_args.as_deref());
                    }
                }
                self.compile_call(expr_id, *callee, args)
            }
            crate::ast::Ast::Expr::MethodCall { recv, method, args, .. } => {
                self.compile_method_call(*recv, method, args)
            }

            // 字段访问
            crate::ast::Ast::Expr::FieldAccess { recv, field } => {
                self.compile_field_access(expr_id, *recv, field)
            }
            // 安全字段访问 recv?.field：编译为普通字段访问 + safe 标记
            crate::ast::Ast::Expr::SafeAccess { recv, field } => {
                let node = self.compile_field_access(expr_id, *recv, field);
                self.graph.set_safe_op(node);
                node
            }
            crate::ast::Ast::Expr::Index { recv, index } => self.compile_index(*recv, *index),

            // Block 表达式
            crate::ast::Ast::Expr::Block { stmts, trailing } => self.compile_block(stmts, trailing),

            // If 表达式 → Gate 节点 + 分支子图
            crate::ast::Ast::Expr::If {
                cond,
                then_branch,
                else_branch,
            } => self.compile_if(*cond, *then_branch, *else_branch),

            // Match 表达式 → Gate 链
            crate::ast::Ast::Expr::Match { scrutinee, arms } => {
                self.compile_match(*scrutinee, arms)
            }

            // 记录构造
            crate::ast::Ast::Expr::RecordLit(fields) => self.compile_record_lit(expr_id, fields),

            // Lambda 表达式 → 闭包子图 + 闭包构造节点
            crate::ast::Ast::Expr::Lambda { params, body, is_async, .. } => {
                let body_expr = match body {
                    crate::ast::Ast::LambdaBody::Block(e) | crate::ast::Ast::LambdaBody::Expression(e) => *e,
                };
                self.compile_lambda(params, body_expr, *is_async, None)
            }

            // 数组构造
            crate::ast::Ast::Expr::ArrayLit { elements, .. } => {
                self.compile_array_lit(expr_id, elements)
            }

            // 赋值表达式：target = value
            // 用于 defer body 等表达式上下文中的赋值。
            // 与 Stmt::Assignment 的 Ident 逻辑保持一致：
            //   捕获变量 → WriteBack；外层变量 → WriteBack；全局变量 → global_store；本地 → bind_var
            crate::ast::Ast::Expr::Assign { target, value } => {
                let raw_val = self.compile_subexpr(*value);
                let val_node = self.chain_effects(self.current_effect, raw_val);
                let target_expr = &self.current_module().arena.expr(*target).node;
                match target_expr {
                    crate::ast::Ast::Expr::Ident(name) => {
                        let captured_source = self.captured_scopes.iter().rev()
                            .find_map(|scope| scope.iter()
                                .find(|(n, _)| n.as_str() == *name)
                                .map(|(_, node)| *node));
                        if let Some(source) = captured_source {
                            let wb_node = self.compile_writeback_node(val_node, source);
                            self.bind_var(name, val_node);
                            self.current_effect = Some(wb_node);
                        } else if let Some(outer_node) = self.lookup_var(name) {
                            if !self.is_in_current_subgraph(outer_node) {
                                let wb_node = self.compile_writeback_node(val_node, outer_node);
                                self.bind_var(name, val_node);
                                self.current_effect = Some(wb_node);
                            } else if let Some(&captured_node) = self.captured_vars.get(*name) {
                                let wb_node = self.compile_writeback_node(val_node, captured_node);
                                self.bind_var(name, val_node);
                                self.current_effect = Some(wb_node);
                            } else {
                                self.bind_var(name, val_node);
                            }
                        } else if let Some(slot) = self.lookup_global_var(name) {
                            let store_node = self.compile_global_store(val_node, slot);
                            self.current_effect = Some(store_node);
                        } else {
                            self.bind_var(name, val_node);
                        }
                    }
                    crate::ast::Ast::Expr::FieldAccess { recv: obj, field } => {
                        let obj_node = self.compile_subexpr(*obj);
                        let off = self.graph.inputs_pool.push(&[obj_node, val_node]);
                        let set_node = self.graph.add_node(Node {
                            kind: NodeKind::BinOp,
                            input_count: 2,
                            inputs_offset: off,
                            compute_fn: CF_RECORD_FIELD_SET, // record_field_set
                        });
                        self.graph.set_field_set_name(set_node, field.to_string());
                    }
                    // recv?.field = value：obj 为 null 时跳过赋值
                    crate::ast::Ast::Expr::SafeAccess { recv: obj, field } => {
                        let obj_node = self.compile_subexpr(*obj);
                        let off = self.graph.inputs_pool.push(&[obj_node, val_node]);
                        let set_node = self.graph.add_node(Node {
                            kind: NodeKind::BinOp,
                            input_count: 2,
                            inputs_offset: off,
                            compute_fn: CF_RECORD_FIELD_SET, // record_field_set
                        });
                        self.graph.set_field_set_name(set_node, field.to_string());
                        self.graph.set_safe_op(set_node);
                    }
                    // `*ref = value` → compute_deref_write(282)
                    crate::ast::Ast::Expr::Deref(ref_inner) => {
                        let ref_node = self.compile_subexpr(*ref_inner);
                        let off = self.graph.inputs_pool.push(&[ref_node, val_node]);
                        let _write_node = self.graph.add_node(Node {
                            kind: NodeKind::BinOp,
                            input_count: 2,
                            inputs_offset: off,
                            compute_fn: CF_DEREF_WRITE, // compute_deref_write
                        });
                    }
                    _ => {}
                }
                self.compile_void_const()
            }

            // 复合赋值：target op= value
            crate::ast::Ast::Expr::CompoundAssign { op, target, value } => {
                let val_node = self.compile_subexpr(*value);
                let target_expr = &self.current_module().arena.expr(*target).node;
                let bin_compute = self.compound_assign_op_to_compute_fn(*op, *target);
                match target_expr {
                    crate::ast::Ast::Expr::Ident(name) => {
                        let cur_node = self
                            .lookup_var(name)
                            .unwrap_or_else(|| self.compile_placeholder());
                        let off = self.graph.inputs_pool.push(&[cur_node, val_node]);
                        let result_node = self.graph.add_node(Node {
                            kind: NodeKind::BinOp,
                            input_count: 2,
                            inputs_offset: off,
                            compute_fn: bin_compute,
                        });
                        self.bind_var(name, result_node);
                        result_node
                    }
                    crate::ast::Ast::Expr::FieldAccess { recv: obj, field }
                    | crate::ast::Ast::Expr::SafeAccess { recv: obj, field } => {
                        let obj_node = self.compile_subexpr(*obj);
                        // 读当前字段值
                        let get_off = self.graph.inputs_pool.push(&[obj_node]);
                        let get_node = self.graph.add_node(Node {
                            kind: NodeKind::FieldAccess,
                            input_count: 1,
                            inputs_offset: get_off,
                            compute_fn: CF_RECORD_FIELD_GET, // record_field_get
                        });
                        // 运算
                        let bin_off = self.graph.inputs_pool.push(&[get_node, val_node]);
                        let result_node = self.graph.add_node(Node {
                            kind: NodeKind::BinOp,
                            input_count: 2,
                            inputs_offset: bin_off,
                            compute_fn: bin_compute,
                        });
                        // 写回
                        let set_off = self.graph.inputs_pool.push(&[obj_node, result_node]);
                        let set_node = self.graph.add_node(Node {
                            kind: NodeKind::BinOp,
                            input_count: 2,
                            inputs_offset: set_off,
                            compute_fn: CF_RECORD_FIELD_SET, // record_field_set
                        });
                        self.graph.set_field_set_name(set_node, field.to_string());
                        result_node
                    }
                    // `*ref op= value` → 读 Cell + 运算 + 写回 Cell
                    crate::ast::Ast::Expr::Deref(ref_inner) => {
                        let ref_node = self.compile_subexpr(*ref_inner);
                        // 读当前值：compute_deref_read(281)
                        let read_off = self.graph.inputs_pool.push(&[ref_node]);
                        let read_node = self.graph.add_node(Node {
                            kind: NodeKind::UnOp,
                            input_count: 1,
                            inputs_offset: read_off,
                            compute_fn: CF_DEREF_READ,
                        });
                        // 运算
                        let bin_off = self.graph.inputs_pool.push(&[read_node, val_node]);
                        let result_node = self.graph.add_node(Node {
                            kind: NodeKind::BinOp,
                            input_count: 2,
                            inputs_offset: bin_off,
                            compute_fn: bin_compute,
                        });
                        // 写回 Cell：compute_deref_write(282)
                        let write_off = self.graph.inputs_pool.push(&[ref_node, result_node]);
                        let _write_node = self.graph.add_node(Node {
                            kind: NodeKind::BinOp,
                            input_count: 2,
                            inputs_offset: write_off,
                            compute_fn: CF_DEREF_WRITE,
                        });
                        result_node
                    }
                    _ => self.compile_void_const(),
                }
            }

            // select 表达式 → Gate 节点（compute_select_gate）+ 每分支独立子图
            crate::ast::Ast::Expr::Select(arms) => self.compile_select(arms),

            // `?` 运算符（Propagate）：解包 Throw，Err 时提前返回
            crate::ast::Ast::Expr::Propagate(inner) => {
                let inner_node = self.compile_subexpr(*inner);
                let inputs_offset = self.graph.inputs_pool.push(&[inner_node]);
                let n = self.graph.add_node(Node {
                    kind: NodeKind::UnOp,
                    input_count: 1,
                    inputs_offset,
                    compute_fn: CF_PROPAGATE, // compute_propagate
                });
                n
            }

            // 一元运算：!（逻辑非）、-（算术取负）、~（按位取反）
            crate::ast::Ast::Expr::Unary { op, operand } => {
                let operand_node = self.compile_subexpr(*operand);
                let inputs_offset = self.graph.inputs_pool.push(&[operand_node]);
                let compute_fn = self.select_unary_compute_fn(*op, *operand);
                let node = self.graph.add_node(Node {
                    kind: NodeKind::UnOp,
                    input_count: 1,
                    inputs_offset,
                    compute_fn,
                });
                // 编译期标记 SIMD 批量化：Neg/BitNot + 标量类型
                if let Some(info) = self.unary_batch_info(*op, *operand) {
                    self.graph.set_batch_info(node, info);
                }
                node
            }

            // 字符串插值："text {expr} more {expr}" → 链式 str_concat
            crate::ast::Ast::Expr::StrInterp(parts) => {
                self.compile_str_interp(parts)
            }

            // 取引用 `&expr` → compute_ref_of(280)：标量包装进 Cell，堆对象共享 Arc
            crate::ast::Ast::Expr::RefOf(inner) => {
                let inner_node = self.compile_subexpr(*inner);
                let inputs_offset = self.graph.inputs_pool.push(&[inner_node]);
                self.graph.add_node(Node {
                    kind: NodeKind::UnOp,
                    input_count: 1,
                    inputs_offset,
                    compute_fn: CF_REF_OF,
                })
            }

            // 解引用读取 `*ref` → compute_deref_read(281)：Cell 返回内部值，其他 Ref 透传
            crate::ast::Ast::Expr::Deref(inner) => {
                let inner_node = self.compile_subexpr(*inner);
                let inputs_offset = self.graph.inputs_pool.push(&[inner_node]);
                self.graph.add_node(Node {
                    kind: NodeKind::UnOp,
                    input_count: 1,
                    inputs_offset,
                    compute_fn: CF_DEREF_READ,
                })
            }

            // 非空断言 `expr!` → compute_non_null_assert(279)：Null panic，非 Null 透传
            crate::ast::Ast::Expr::NonNullAssert(inner) => {
                let inner_node = self.compile_subexpr(*inner);
                let inputs_offset = self.graph.inputs_pool.push(&[inner_node]);
                self.graph.add_node(Node {
                    kind: NodeKind::UnOp,
                    input_count: 1,
                    inputs_offset,
                    compute_fn: CF_NON_NULL_ASSERT,
                })
            }

            // Elvis：lhs ?: rhs → compute_elvis（idx 265）
            crate::ast::Ast::Expr::Elvis { lhs, rhs } => {
                let lhs_node = self.compile_subexpr(*lhs);
                let rhs_node = self.compile_subexpr(*rhs);
                let inputs_offset = self.graph.inputs_pool.push(&[lhs_node, rhs_node]);
                self.graph.add_node(Node {
                    kind: NodeKind::BinOp,
                    input_count: 2,
                    inputs_offset,
                    compute_fn: CF_ELVIS, // compute_elvis
                })
            }

            // 安全方法调用 recv?.method(args)：编译为普通方法调用 + safe 标记
            crate::ast::Ast::Expr::SafeMethodCall { recv, method, args, .. } => {
                let node = self.compile_method_call(*recv, method, args);
                self.graph.set_safe_op(node);
                node
            }

            // 记录扩展 `(...base, field: value, ...)` → base + updates 输入节点 + RecordExtendInfo
            crate::ast::Ast::Expr::RecordExtend { base, updates } => {
                self.compile_record_extend(*base, updates)
            }

            // 原子构造 `atomic expr` → 单输入节点包装为 AtomicValue
            crate::ast::Ast::Expr::Atomic(operand) => self.compile_atomic(*operand),

            // inline_trait 表达式 → 每方法编译子图 + TraitValue 构造节点
            crate::ast::Ast::Expr::InlineTrait(methods) => self.compile_inline_trait(expr_id, methods),

            // lazy 表达式 → thunk 子图 + LazyValue 构造节点
            crate::ast::Ast::Expr::Lazy(operand) => self.compile_lazy(expr_id, *operand),

            // 切片 `recv[start..end]` / `recv[start..=end]` → 三输入节点 + inclusive 标志
            crate::ast::Ast::Expr::Slice { recv, start, end, inclusive } => {
                self.compile_slice(*recv, *start, *end, *inclusive)
            }
        }
    }

    /// 编译子表达式（非尾位置）。
    ///
    /// 操作数、函数参数、if 条件、字段访问基础值等子表达式的值会被父表达式
    /// 消费而非直接作为函数返回值，因此一律不在尾位置：编译前关闭
    /// in_tail_position，编译后恢复。这样子表达式内的 Call 不会被误标为
    /// 尾调用（否则 switch_subgraph 帧复用会切走当前帧，破坏父表达式对其余
    /// 子表达式/运算节点的执行，如 fib(n-1)+fib(n-2) 中 fib(n-1) 误标尾调用
    /// 会导致 fib(n-2) 与加法节点永不执行）。
    fn compile_subexpr(&mut self, expr_id: crate::ast::Ast::ExprId) -> NodeId {
        let prev_tail = self.in_tail_position;
        self.in_tail_position = false;
        let node = self.compile_expr(expr_id);
        self.in_tail_position = prev_tail;
        node
    }

    /// 编译常量表达式（无输入）。
    fn compile_const(&mut self) -> NodeId {
        let inputs_offset = self.graph.inputs_pool.push(&[]);
        self.graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset,
            compute_fn: CF_NOOP,
        })
    }

    /// 编译 void 常量节点（return/break/continue 无值时用）。
    fn compile_void_const(&mut self) -> NodeId {
        let inputs_offset = self.graph.inputs_pool.push(&[]);
        let n = self.graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset,
            compute_fn: CF_NOOP,
        });
        self.graph.const_values[n.0 as usize] = Some(ConstValue::Void);
        n
    }

    /// 编译带原始值的常量表达式，填充 const_values。
    fn compile_const_with_value(&mut self, expr_id: crate::ast::Ast::ExprId) -> NodeId {
        let inputs_offset = self.graph.inputs_pool.push(&[]);
        let node_id = self.graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset,
            compute_fn: CF_NOOP,
        });
        let const_val = self.parse_const_value(expr_id);
        self.graph.const_values[node_id.0 as usize] = const_val;
        node_id
    }

    /// 从 AST 表达式解析常量值。
    fn parse_const_value(&self, expr_id: crate::ast::Ast::ExprId) -> Option<ConstValue> {
        let spanned = self.current_module().arena.expr(expr_id);
        match &spanned.node {
            crate::ast::Ast::Expr::IntLit { raw, suffix } => {
                // suffix 优先；无 suffix 时参考 sema 推断的类型选择对应整数 ConstValue，
                // 确保字面量的运行时 tag 与上下文类型一致
                let ty = suffix
                    .map(|s| s.to_string())
                    .or_else(|| self.expr_type_name(expr_id).map(|s| s.to_string()));
                // 解析整数：支持 0x/0o/0b 前缀（Rust from_str_radix 语义）
                let parse_int = |raw: &str| -> Option<i128> {
                    let s = raw
                        .strip_prefix("0x").map(|s| (s, 16))
                        .or_else(|| raw.strip_prefix("0o").map(|s| (s, 8)))
                        .or_else(|| raw.strip_prefix("0b").map(|s| (s, 2)))
                        .unwrap_or((raw, 10));
                    i128::from_str_radix(s.0, s.1).ok()
                };
                match ty.as_deref() {
                    Some("i8") => parse_int(raw).and_then(|v| i8::try_from(v).ok()).map(ConstValue::I8),
                    Some("i16") => parse_int(raw).and_then(|v| i16::try_from(v).ok()).map(ConstValue::I16),
                    Some("i32") => parse_int(raw).and_then(|v| i32::try_from(v).ok()).map(ConstValue::I32),
                    Some("i64") => parse_int(raw).and_then(|v| i64::try_from(v).ok()).map(ConstValue::I64),
                    Some("i128") => parse_int(raw).map(ConstValue::I128),
                    Some("u8") => parse_int(raw).and_then(|v| u8::try_from(v).ok()).map(ConstValue::U8),
                    Some("u16") => parse_int(raw).and_then(|v| u16::try_from(v).ok()).map(ConstValue::U16),
                    Some("u32") => parse_int(raw).and_then(|v| u32::try_from(v).ok()).map(ConstValue::U32),
                    Some("u64") => parse_int(raw).and_then(|v| u64::try_from(v).ok()).map(ConstValue::U64),
                    Some("u128") => parse_int(raw).map(|v| v as u128).map(ConstValue::U128),
                    Some("isize") => parse_int(raw).and_then(|v| isize::try_from(v).ok()).map(ConstValue::Isize),
                    Some("usize") => parse_int(raw).and_then(|v| usize::try_from(v).ok()).map(ConstValue::Usize),
                    _ => parse_int(raw).and_then(|v| i32::try_from(v).ok()).map(ConstValue::I32),
                }
            }
            crate::ast::Ast::Expr::FloatLit { raw, suffix } => match suffix {
                None | Some("f64") => raw.parse::<f64>().ok().map(ConstValue::F64),
                Some("f32") => raw.parse::<f32>().ok().map(ConstValue::F32),
                _ => raw.parse::<f64>().ok().map(ConstValue::F64),
            },
            crate::ast::Ast::Expr::BoolLit(b) => Some(ConstValue::Bool(*b)),
            crate::ast::Ast::Expr::CharLit(c) => Some(ConstValue::Char(*c)),
            crate::ast::Ast::Expr::StrLit(s) => {
                let static_s: &'static str = Box::leak(s.to_string().into_boxed_str());
                Some(ConstValue::Str(static_s))
            }
            crate::ast::Ast::Expr::NullLit => Some(ConstValue::Null),
            crate::ast::Ast::Expr::VoidLit => Some(ConstValue::Void),
            _ => None,
        }
    }

    /// 编译占位节点（本阶段未实现的 Expr 变体）。
    fn compile_placeholder(&mut self) -> NodeId {
        let inputs_offset = self.graph.inputs_pool.push(&[]);
        self.graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset,
            compute_fn: CF_NOOP,
        })
    }

    /// 编译 If 表达式为 Gate 节点 + 两个分支子图。
    ///
    /// cond 编译为条件节点，then/else 各编译为独立子图。
    /// Gate 节点的 condition_input 指向 cond 节点，branches 携带分支子图 id。
    /// 分支子图无参数（闭包变量捕获留到后续阶段）。
    fn compile_if(
        &mut self,
        cond: crate::ast::Ast::ExprId,
        then_branch: crate::ast::Ast::ExprId,
        else_branch: Option<crate::ast::Ast::ExprId>,
    ) -> NodeId {
        // 条件不在尾位置：其值仅供 Gate 选择分支，而非直接返回。
        // 分支结果表达式则继承当前尾位置（if 表达式的值=选中分支的值）。
        let cond_node = self.compile_subexpr(cond);
        let (then_sg, then_inputs) = self.compile_branch_subgraph(then_branch);
        let (else_sg, else_inputs) = match else_branch {
            Some(e) => self.compile_branch_subgraph(e),
            None => (self.compile_void_subgraph(), Vec::new()),
        };
        // Gate 依赖 cond_node（条件值）和 current_effect（effect 链前序副作用），
        // 确保 Gate 在前序语句（如 println）完成后才执行。
        let gate_inputs: Vec<NodeId> = match self.current_effect {
            Some(eff) => vec![cond_node, eff],
            None => vec![cond_node],
        };
        let inputs_offset = self.graph.inputs_pool.push(&gate_inputs);
        let gate_node = self.graph.add_node(Node {
            kind: NodeKind::Gate,
            input_count: gate_inputs.len() as u8,
            inputs_offset,
            compute_fn: CF_GATE_LAUNCH,
        });
        self.graph.set_gate_branches(
            gate_node,
            GateBranches {
                condition_input: cond_node,
                branches: vec![
                    (true, then_sg, then_inputs),
                    (false, else_sg, else_inputs),
                ],
            },
        );
        gate_node
    }

    /// 编译分支表达式为子图（If 的 then/else 分支、Match arm body、Defer body）。
    ///
    /// 分支子图在独立子帧中执行，无法直接访问父帧的值表。
    /// 因此需要捕获分支表达式中的自由变量（引用外层作用域的标识符）：
    /// 1. 收集表达式中的所有标识符
    /// 2. 过滤出在当前作用域栈中已绑定的（即外层变量）
    /// 3. 在子图开头创建捕获节点（Const 占位），运行时由 Gate/defer 注入值
    /// 4. 将捕获名绑定到捕获节点，使编译体引用捕获节点而非外层节点
    ///
    /// 返回 (子图 id, 捕获的外层节点列表)。
    /// 调用方将外层节点列表作为 GateBranches.branch_inputs 传递，
    /// Gate 节点在启动子图时通过 start_subgraph 注入捕获值。
    fn compile_branch_subgraph(&mut self, expr: crate::ast::Ast::ExprId) -> (SubGraphId, Vec<NodeId>) {
        let node_start = self.graph.nodes.len() as u32;

        // 帧链穿透（root_frame_ptr）使分支子图可直接引用外层节点，
        // 无需 capture 机制（不创建局部副本，赋值通过 WriteBack 写回根帧）。
        // branch_inputs 为空：Gate 不注入参数，分支内节点通过 get_value_by_global
        // 帧链回溯读取外层变量。
        self.enter_scope();
        let prev_sg_start = self.current_sg_start;
        self.current_sg_start = node_start;

        let return_node = self.compile_expr(expr);
        self.current_sg_start = prev_sg_start;
        self.exit_scope();

        let node_end = self.graph.nodes.len() as u32;
        let sg_id = SubGraphId(self.graph.subgraphs.len() as u32);
        self.graph.add_subgraph(SubGraph {
            id: sg_id,
            node_range: (NodeId(node_start), NodeId(node_end)),
            param_count: 0,
            entry_node: NodeId(node_start),
            return_node,
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: self.current_function_id,
            iter_next_node: None,
            upvalue_count: 0,
            upvalue_outer_nodes: Vec::new(),
        });
        (sg_id, Vec::new())
    }

    /// 编译 void 子图（无 else 分支时用）。
    fn compile_void_subgraph(&mut self) -> SubGraphId {
        let inputs_offset = self.graph.inputs_pool.push(&[]);
        let node = self.graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset,
            compute_fn: CF_NOOP,
        });
        self.graph.const_values[node.0 as usize] = Some(ConstValue::Void);
        let sg_id = SubGraphId(self.graph.subgraphs.len() as u32);
        self.graph.add_subgraph(SubGraph {
            id: sg_id,
            node_range: (node, NodeId(node.0 + 1)),
            param_count: 0,
            entry_node: node,
            return_node: node,
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: self.current_function_id,
            iter_next_node: None,
            upvalue_count: 0,
            upvalue_outer_nodes: Vec::new(),
        });
        sg_id
    }

    /// 编译 select 表达式。
    ///
    /// 每个 SelectArm 编译为独立子图（含事件源检查 + body）。
    /// Gate 节点（compute_select_gate）选第一个就绪分支：有就绪分支 → 启动该分支子图；
    /// 无就绪分支 → 帧挂起，注册所有事件源等待，任一事件到达时唤醒重新检查。
    fn compile_select(&mut self, arms: &[crate::ast::Ast::SelectArm<'_>]) -> NodeId {
        let mut branches = Vec::with_capacity(arms.len());

        for arm in arms {
            let (event_kind, event_source_node, body_expr) = match arm {
                crate::ast::Ast::SelectArm::Receive { channel_expr, body, .. } => {
                    // channel_expr 形如 `ch.recv()`：编译时需取 recv 的 receiver（channel 值），
                    // 而非整个方法调用（recv() 返回接收的值，非 channel 本身）。
                    let ch_node = match &self.current_module().arena.expr(*channel_expr).node {
                        crate::ast::Ast::Expr::MethodCall { recv, method, .. } if *method == "recv" => {
                            self.compile_subexpr(*recv)
                        }
                        _ => self.compile_subexpr(*channel_expr),
                    };
                    (EventSourceKind::Channel, ch_node, *body)
                }
                crate::ast::Ast::SelectArm::Timeout { duration, body } => {
                    let dur_node = self.compile_subexpr(*duration);
                    (EventSourceKind::Timer, dur_node, *body)
                }
            };

            // 为每个分支创建子图：先注册占位（node_range 待编译后回填）
            let node_start = self.graph.nodes.len() as u32;
            let sg_id = SubGraphId(self.graph.subgraphs.len() as u32);
            self.graph.add_subgraph(SubGraph {
                id: sg_id,
                node_range: (NodeId(node_start), NodeId(node_start)),
                param_count: 0,
                entry_node: NodeId(node_start),
                return_node: NodeId(node_start),
                has_suspend: true,
                event_source_decls: Vec::new(),
                defer_table: Vec::new(),
            loop_kind: LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: self.current_function_id,
            iter_next_node: None,
            upvalue_count: 0,
            upvalue_outer_nodes: Vec::new(),
            });

            let prev_sg = self.current_function_sg;
            self.current_function_sg = Some(sg_id);
            self.enter_scope();

            // 编译 body（body 中的变量绑定在子图作用域内）
            let result_node = self.compile_expr(body_expr);

            self.exit_scope();
            self.current_function_sg = prev_sg;

            let node_end = self.graph.nodes.len() as u32;
            let sg = &mut self.graph.subgraphs[sg_id.0 as usize];
            sg.node_range = (NodeId(node_start), NodeId(node_end));
            sg.return_node = result_node;

            branches.push(SelectBranch {
                subgraph_id: sg_id,
                event_kind,
                event_source_node,
            });
        }

        // 创建 Gate 节点（select 的核心：选第一个就绪分支）
        // Gate 依赖所有分支的 event_source_node + current_effect，
        // 确保在所有事件源（channel/timer）求值完成后才检查就绪状态。
        let mut gate_inputs: Vec<NodeId> = branches.iter().map(|b| b.event_source_node).collect();
        if let Some(eff) = self.current_effect {
            gate_inputs.push(eff);
        }
        let gate_off = self.graph.inputs_pool.push(&gate_inputs);
        let gate_node = self.graph.add_node(Node {
            kind: NodeKind::Gate,
            input_count: gate_inputs.len() as u8,
            inputs_offset: gate_off,
            compute_fn: CF_SELECT_GATE, // compute_select_gate
        });
        self.graph.set_select_info(gate_node, SelectInfo { branches });

        gate_node
    }

    /// 编译 Lambda 表达式为闭包子图 + 闭包构造节点。
    ///
    /// 追加参数模型：捕获变量追加到子图参数列表末尾。
    /// - 子图 param_count = lambda 参数数 + 捕获变量数
    /// - 子图前 N 个节点 = lambda 参数节点，后续 = 捕获 upvalue 参数节点
    /// - 当前作用域创建闭包构造节点（compute_fn 40），inputs = 捕获值节点
    /// - Lambda 表达式的值 = 闭包构造节点（运行时产出 Closure 堆对象）
    fn compile_lambda(
        &mut self,
        params: &[crate::ast::Ast::Param<'_>],
        body_expr: crate::ast::Ast::ExprId,
        is_async: bool,
        fn_name: Option<&str>,
    ) -> NodeId {
        // 1. 自由变量分析：收集 body 中引用的外层变量（排除 lambda 自身参数）
        let param_names: rustc_hash::FxHashSet<&str> =
            params.iter().map(|p| p.name).collect();
        let mut ident_names: Vec<String> = Vec::new();
        self.collect_free_idents_expr(body_expr, &mut ident_names);
        let mut captured: Vec<(String, NodeId)> = Vec::new();

        // 自引用检测：命名函数在 body 中引用自身 → 作为 upvalue 占位
        // 运行时 compute_closure_call 将闭包值注入该 slot，支持递归调用
        let self_upvalue_idx = if let Some(fname) = fn_name {
            if !param_names.contains(fname)
                && ident_names.iter().any(|n| n == fname)
            {
                let void_node = self.compile_void_const();
                let idx = captured.len();
                captured.push((fname.to_string(), void_node));
                idx as i32
            } else {
                -1
            }
        } else {
            -1
        };

        for ident in &ident_names {
            if param_names.contains(ident.as_str()) {
                continue;
            }
            // 跳过自引用名（已作为占位 upvalue 添加）
            if Some(ident.as_str()) == fn_name && self_upvalue_idx >= 0 {
                continue;
            }
            if let Some(node) = self.lookup_var(ident) {
                if !captured.iter().any(|(n, _)| n == ident) {
                    // 如果变量已被外层 lambda 捕获，使用外层的原始节点。
                    // 这确保 WriteBack target 指向最外层定义节点（根帧），
                    // 而非中间 lambda 的 upvalue 参数节点（中间帧拷贝）。
                    let outer_node = self.captured_scopes.iter().rev()
                        .find_map(|scope| scope.iter()
                            .find(|(n, _)| n.as_str() == ident.as_str())
                            .map(|(_, node)| *node))
                        .unwrap_or(node);
                    captured.push((ident.clone(), outer_node));
                }
            }
        }

        let param_count = (params.len() + captured.len()) as u8;

        // 2. 注册占位子图（节点范围待编译后填充）
        let sg_id = self.register_subgraph_placeholder("", param_count, is_async);
        let node_start = self.graph.nodes.len() as u32;

        // 3. 进入 lambda 作用域：先创建 lambda 参数节点，再创建捕获 upvalue 参数节点，
        //    全部 bind_var（捕获节点在 lambda 作用域内遮蔽外层同名绑定）
        self.enter_scope();
        for param in params {
            let inputs_offset = self.graph.inputs_pool.push(&[]);
            let param_node = self.graph.add_node(Node {
                kind: NodeKind::Const,
                input_count: 0,
                inputs_offset,
                compute_fn: CF_NOOP,
            });
            self.bind_var(param.name, param_node);
        }
        for (name, _outer_node) in &captured {
            let inputs_offset = self.graph.inputs_pool.push(&[]);
            let upvalue_node = self.graph.add_node(Node {
                kind: NodeKind::Const,
                input_count: 0,
                inputs_offset,
                compute_fn: CF_NOOP,
            });
            self.bind_var(name, upvalue_node);
        }

        // 4. 编译 body 得到返回节点
        //    设置 current_sg_start = node_start 使 is_in_current_subgraph 正确识别
        //    lambda 内节点（含 upvalue 占位节点），避免捕获变量赋值误走本地路径。
        //    重置 current_effect = None 隔离 lambda 体与外层 effect 链，确保
        //    无 trailing 表达式时 block 返回 lambda 内新建的 void_const 而非外层 effect 节点。
        //    压入 captured_scopes 使 Assignment 能识别捕获变量并创建 WriteBack。
        let prev_sg_start = self.current_sg_start;
        self.current_sg_start = node_start;
        let prev_effect = self.current_effect;
        self.current_effect = None;
        // 设置 current_function_sg 使 defer 语句能注册到 lambda 子图的 defer_table。
        // 不设置时 defer body 会丢失（current_function_sg 为 None 或指向外层函数）。
        let prev_func_sg = self.current_function_sg;
        self.current_function_sg = Some(sg_id);
        self.captured_scopes.push(captured.clone());

        let return_node = self.compile_expr(body_expr);

        self.current_sg_start = prev_sg_start;
        self.current_effect = prev_effect;
        self.current_function_sg = prev_func_sg;
        self.captured_scopes.pop();
        self.exit_scope();

        // 5. 更新子图 node_range + return_node + function_id + upvalue 元数据
        // function_id 设为当前函数的 function_id，确保 lambda 子帧与外层函数帧
        // 属于同一 function_id，parent_frame_ptr / root_frame_ptr 能正确链接，
        // 使 lambda 内部分支子图可访问 lambda 帧中的 upvalue 参数节点。
        // upvalue_count + upvalue_outer_nodes 供 start_subgraph 在 same_function
        // 调用时注入当前父帧值（引用捕获语义）。
        let node_end = self.graph.nodes.len() as u32;
        let sg = &mut self.graph.subgraphs[sg_id.0 as usize];
        sg.node_range = (NodeId(node_start), NodeId(node_end));
        sg.entry_node = NodeId(node_start);
        sg.return_node = return_node;
        sg.has_suspend = is_async;
        sg.function_id = self.current_function_id;
        sg.upvalue_count = captured.len() as u8;
        sg.upvalue_outer_nodes = captured.iter().map(|(_, n)| *n).collect();

        // 注册被捕获的变量到 captured_vars：外层 Assignment 对这些变量赋值时
        // 需生成 WriteBack 到原始节点，使 same_function 闭包调用能读到最新值。
        for (name, node) in &captured {
            self.captured_vars.entry(name.clone()).or_insert(*node);
        }

        // 6. 在当前作用域创建闭包构造节点（inputs = 捕获值外层节点，compute_fn 40）
        let upvalue_nodes: Vec<NodeId> = captured.iter().map(|(_, n)| *n).collect();
        let inputs_offset = self.graph.inputs_pool.push(&upvalue_nodes);
        let construct_node = self.graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: upvalue_nodes.len() as u8,
            inputs_offset,
            compute_fn: CF_CLOSURE_CONSTRUCT, // compute_closure_construct
        });
        self.graph.set_closure_info(
            construct_node,
            ClosureInfo {
                subgraph_id: sg_id,
                arity: params.len() as u8,
                self_upvalue_idx,
            },
        );
        construct_node
    }

    /// 编译 inline_trait 表达式：每个方法编译为子图（含 upvalues 捕获），
    /// 构造 TraitValue 构造节点（compute_fn=266），运行时打包多个 Closure。
    ///
    /// 方法子图的编译参考 compile_lambda：自由变量分析 → 占位子图 →
    /// 进入作用域（参数 + upvalues）→ 编译方法体 → 填充 node_range。
    /// 所有方法的 upvalues 依次拼接为构造节点的 inputs。
    fn compile_inline_trait(&mut self, expr_id: crate::ast::Ast::ExprId, methods: &[crate::ast::Ast::MethodDecl<'_>]) -> NodeId {
        // 推断 trait 名（从 sema.expr_types 拿 ConcreteType::TraitObject）
        let trait_name = self.expr_type_name(expr_id)
            .map(|s| s.to_string())
            .unwrap_or_else(|| "Unknown".to_string());

        // 按 trait_def.methods 声明顺序重排 inline_trait 方法，
        // 确保 method_values[i] 对应 trait_def.methods[i]，
        // 使 vtable 能用 method_idx 位置索引分派（Task 10）。
        let method_order: Vec<usize> = if let Some(trait_def) = self.sema.get_trait_def(&trait_name) {
            let mut order: Vec<usize> = (0..methods.len()).collect();
            order.sort_by_key(|&i| {
                trait_def.methods.iter().position(|tm| tm.name.as_ref() == methods[i].name)
                    .unwrap_or(usize::MAX)
            });
            order
        } else {
            (0..methods.len()).collect()
        };

        let mut method_names: Vec<String> = Vec::with_capacity(methods.len());
        let mut method_entries: Vec<TraitMethodEntry> = Vec::with_capacity(methods.len());
        let mut all_upvalue_nodes: Vec<NodeId> = Vec::new();

        for &idx in &method_order {
            let m = &methods[idx];
            let body_expr = match m.body {
                Some(b) => b,
                None => {
                    self.errors.push(format!(
                        "compile_inline_trait: 方法 {} 无方法体（inline_trait 要求所有方法有体）",
                        m.name
                    ));
                    continue;
                }
            };

            // 1. 自由变量分析：收集 body 中引用的外层变量（排除方法自身参数）
            let param_names: rustc_hash::FxHashSet<&str> =
                m.params.iter().map(|p| p.name).collect();
            let mut ident_names: Vec<String> = Vec::new();
            self.collect_free_idents_expr(body_expr, &mut ident_names);
            let mut captured: Vec<(String, NodeId)> = Vec::new();
            for name in &ident_names {
                if param_names.contains(name.as_str()) {
                    continue;
                }
                if let Some(node) = self.lookup_var(name) {
                    if !captured.iter().any(|(n, _)| n == name) {
                        captured.push((name.clone(), node));
                    }
                }
            }

            let param_count = (m.params.len() + captured.len()) as u8;

            // 2. 注册占位子图
            let sg_id = self.register_subgraph_placeholder("", param_count, m.is_async);
            let node_start = self.graph.nodes.len() as u32;

            // 3. 进入方法作用域：参数节点 + upvalue 节点
            self.enter_scope();
            for param in &m.params {
                let inputs_offset = self.graph.inputs_pool.push(&[]);
                let param_node = self.graph.add_node(Node {
                    kind: NodeKind::Const,
                    input_count: 0,
                    inputs_offset,
                    compute_fn: CF_NOOP,
                });
                self.bind_var(param.name, param_node);
            }
            for (name, _outer_node) in &captured {
                let inputs_offset = self.graph.inputs_pool.push(&[]);
                let upvalue_node = self.graph.add_node(Node {
                    kind: NodeKind::Const,
                    input_count: 0,
                    inputs_offset,
                    compute_fn: CF_NOOP,
                });
                self.bind_var(name, upvalue_node);
            }

            // 4. 编译方法体
            //    设置 current_sg_start + 重置 current_effect + 压入 captured_scopes（与 compile_lambda 一致）
            let prev_sg_start = self.current_sg_start;
            self.current_sg_start = node_start;
            let prev_effect = self.current_effect;
            self.current_effect = None;
            self.captured_scopes.push(captured.clone());

            let return_node = self.compile_expr(body_expr);

            self.current_sg_start = prev_sg_start;
            self.current_effect = prev_effect;
            self.captured_scopes.pop();
            self.exit_scope();

            // 5. 填充子图 node_range + upvalue 元数据
            let node_end = self.graph.nodes.len() as u32;
            let sg = &mut self.graph.subgraphs[sg_id.0 as usize];
            sg.node_range = (NodeId(node_start), NodeId(node_end));
            sg.entry_node = NodeId(node_start);
            sg.return_node = return_node;
            sg.has_suspend = m.is_async;
            sg.upvalue_count = captured.len() as u8;
            sg.upvalue_outer_nodes = captured.iter().map(|(_, n)| *n).collect();

            // 6. 收集 upvalue 节点 + 记录方法信息
            let upvalue_count = captured.len() as u8;
            for (_, n) in &captured {
                all_upvalue_nodes.push(*n);
            }
            method_names.push(m.name.to_string());
            method_entries.push(TraitMethodEntry {
                subgraph_id: sg_id,
                arity: m.params.len() as u8,
                upvalue_count,
            });
        }

        // 构造 TraitValue 构造节点（inputs = 所有方法 upvalues 依次拼接）
        let inputs_offset = self.graph.inputs_pool.push(&all_upvalue_nodes);
        let construct_node = self.graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: all_upvalue_nodes.len() as u8,
            inputs_offset,
            compute_fn: CF_TRAIT_CONSTRUCT, // compute_trait_construct
        });
        self.graph.set_trait_construct_info(
            construct_node,
            TraitConstructInfo {
                trait_name,
                method_names,
                methods: method_entries,
            },
        );
        construct_node
    }

    /// 编译 lazy 表达式：operand 编译为无参数 thunk 子图，
    /// 构造 LazyValue 构造节点（compute_fn=267），运行时创建未求值的 LazyValue。
    ///
    /// thunk 子图捕获外层自由变量（与 lambda 相同的捕获机制），
    /// 首次 force 时启动子图计算，结果缓存供后续 force 复用。
    fn compile_lazy(&mut self, expr_id: crate::ast::Ast::ExprId, operand: crate::ast::Ast::ExprId) -> NodeId {
        let _ = expr_id; // trait_name 推断暂不需要，保留参数供未来 force 语义使用
        // 1. 自由变量分析
        let mut ident_names: Vec<String> = Vec::new();
        self.collect_free_idents_expr(operand, &mut ident_names);
        let mut captured: Vec<(String, NodeId)> = Vec::new();
        for name in &ident_names {
            if let Some(node) = self.lookup_var(name) {
                if !captured.iter().any(|(n, _)| n == name) {
                    captured.push((name.clone(), node));
                }
            }
        }

        let param_count = captured.len() as u8;

        // 2. 注册占位子图（thunk：无显式参数，仅 upvalues）
        let sg_id = self.register_subgraph_placeholder("", param_count, false);
        let node_start = self.graph.nodes.len() as u32;

        // 3. 进入 thunk 作用域：upvalue 节点
        self.enter_scope();
        for (name, _outer_node) in &captured {
            let inputs_offset = self.graph.inputs_pool.push(&[]);
            let upvalue_node = self.graph.add_node(Node {
                kind: NodeKind::Const,
                input_count: 0,
                inputs_offset,
                compute_fn: CF_NOOP,
            });
            self.bind_var(name, upvalue_node);
        }

        // 4. 编译 operand 得到返回节点
        let return_node = self.compile_expr(operand);
        self.exit_scope();

        // 5. 填充子图 node_range
        let node_end = self.graph.nodes.len() as u32;
        let sg = &mut self.graph.subgraphs[sg_id.0 as usize];
        sg.node_range = (NodeId(node_start), NodeId(node_end));
        sg.entry_node = NodeId(node_start);
        sg.return_node = return_node;
        sg.has_suspend = false;

        // 6. 构造 LazyValue 构造节点（inputs = upvalues）
        let upvalue_nodes: Vec<NodeId> = captured.iter().map(|(_, n)| *n).collect();
        let inputs_offset = self.graph.inputs_pool.push(&upvalue_nodes);
        let construct_node = self.graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: upvalue_nodes.len() as u8,
            inputs_offset,
            compute_fn: CF_LAZY_CONSTRUCT, // compute_lazy_construct
        });
        self.graph.set_lazy_construct_info(
            construct_node,
            LazyConstructInfo { thunk_sg: sg_id },
        );
        construct_node
    }

    /// 递归收集表达式中的所有 Ident 名称（去重，保留首次出现顺序）。
    ///
    /// 简化版自由变量分析：遍历常见 Expr 变体收集标识符引用，
    /// 由调用方排除 lambda 参数并检查外层作用域绑定。
    fn collect_free_idents_expr(&self, expr_id: crate::ast::Ast::ExprId, names: &mut Vec<String>) {
        use crate::ast::Ast::LambdaBody;
        let spanned = self.current_module().arena.expr(expr_id);
        match &spanned.node {
            crate::ast::Ast::Expr::Ident(name) => {
                if !names.iter().any(|n| n == name) {
                    names.push((*name).to_string());
                }
            }
            crate::ast::Ast::Expr::Binary { lhs, rhs, .. } => {
                self.collect_free_idents_expr(*lhs, names);
                self.collect_free_idents_expr(*rhs, names);
            }
            crate::ast::Ast::Expr::Unary { operand, .. } => {
                self.collect_free_idents_expr(*operand, names);
            }
            crate::ast::Ast::Expr::Call { callee, args, .. } => {
                self.collect_free_idents_expr(*callee, names);
                for &a in args {
                    self.collect_free_idents_expr(a, names);
                }
            }
            crate::ast::Ast::Expr::MethodCall { recv, args, .. } => {
                self.collect_free_idents_expr(*recv, names);
                for &a in args {
                    self.collect_free_idents_expr(a, names);
                }
            }
            crate::ast::Ast::Expr::FieldAccess { recv, .. }
            | crate::ast::Ast::Expr::SafeAccess { recv, .. } => {
                self.collect_free_idents_expr(*recv, names);
            }
            crate::ast::Ast::Expr::Index { recv, index } => {
                self.collect_free_idents_expr(*recv, names);
                self.collect_free_idents_expr(*index, names);
            }
            crate::ast::Ast::Expr::Assign { target, value } => {
                self.collect_free_idents_expr(*target, names);
                self.collect_free_idents_expr(*value, names);
            }
            crate::ast::Ast::Expr::CompoundAssign { target, value, .. } => {
                self.collect_free_idents_expr(*target, names);
                self.collect_free_idents_expr(*value, names);
            }
            crate::ast::Ast::Expr::RecordLit(fields) => {
                for f in fields {
                    self.collect_free_idents_expr(f.value, names);
                }
            }
            crate::ast::Ast::Expr::If {
                cond,
                then_branch,
                else_branch,
            } => {
                self.collect_free_idents_expr(*cond, names);
                self.collect_free_idents_expr(*then_branch, names);
                if let Some(e) = else_branch {
                    self.collect_free_idents_expr(*e, names);
                }
            }
            crate::ast::Ast::Expr::Block { stmts, trailing } => {
                for &s in stmts {
                    self.collect_free_idents_stmt(s, names);
                }
                if let Some(t) = trailing {
                    self.collect_free_idents_expr(*t, names);
                }
            }
            crate::ast::Ast::Expr::Lambda { body, .. } => {
                let inner = match body {
                    LambdaBody::Block(e) | LambdaBody::Expression(e) => *e,
                };
                self.collect_free_idents_expr(inner, names);
            }
            crate::ast::Ast::Expr::Match { scrutinee, arms } => {
                self.collect_free_idents_expr(*scrutinee, names);
                for arm in arms {
                    if let Some(g) = arm.guard {
                        self.collect_free_idents_expr(g, names);
                    }
                    self.collect_free_idents_expr(arm.body, names);
                }
            }
            // 单 operand 表达式：RefOf/Deref/Propagate/NonNullAssert/Atomic/Lazy
            crate::ast::Ast::Expr::RefOf(inner)
            | crate::ast::Ast::Expr::Deref(inner)
            | crate::ast::Ast::Expr::Propagate(inner)
            | crate::ast::Ast::Expr::NonNullAssert(inner)
            | crate::ast::Ast::Expr::Atomic(inner)
            | crate::ast::Ast::Expr::Lazy(inner) => {
                self.collect_free_idents_expr(*inner, names);
            }
            // Elvis：lhs ?: rhs
            crate::ast::Ast::Expr::Elvis { lhs, rhs } => {
                self.collect_free_idents_expr(*lhs, names);
                self.collect_free_idents_expr(*rhs, names);
            }
            // 切片：recv[start..end]（inclusive 不影响 ident 收集）
            crate::ast::Ast::Expr::Slice { recv, start, end, .. } => {
                self.collect_free_idents_expr(*recv, names);
                self.collect_free_idents_expr(*start, names);
                self.collect_free_idents_expr(*end, names);
            }
            // 安全方法调用：recv?.method(args)
            crate::ast::Ast::Expr::SafeMethodCall { recv, args, .. } => {
                self.collect_free_idents_expr(*recv, names);
                for &a in args {
                    self.collect_free_idents_expr(a, names);
                }
            }
            // 记录扩展：{ base with x: 1, ... }
            crate::ast::Ast::Expr::RecordExtend { base, updates } => {
                self.collect_free_idents_expr(*base, names);
                for f in updates {
                    self.collect_free_idents_expr(f.value, names);
                }
            }
            // 数组字面量的 fill 子句：[value, ..count]
            crate::ast::Ast::Expr::ArrayLit { elements, fill } => {
                for &e in elements {
                    self.collect_free_idents_expr(e, names);
                }
                if let Some((v, c)) = fill {
                    self.collect_free_idents_expr(*v, names);
                    self.collect_free_idents_expr(*c, names);
                }
            }
            // 字符串插值：可能含 {expr}
            crate::ast::Ast::Expr::StrInterp(parts) => {
                for part in parts {
                    if let crate::ast::Ast::InterpolationPart::Expression(e) = part {
                        self.collect_free_idents_expr(*e, names);
                    }
                }
            }
            // select 表达式：每分支含 channel_expr/duration + body
            crate::ast::Ast::Expr::Select(arms) => {
                for arm in arms {
                    match arm {
                        crate::ast::Ast::SelectArm::Receive { channel_expr, body, .. } => {
                            self.collect_free_idents_expr(*channel_expr, names);
                            self.collect_free_idents_expr(*body, names);
                        }
                        crate::ast::Ast::SelectArm::Timeout { duration, body } => {
                            self.collect_free_idents_expr(*duration, names);
                            self.collect_free_idents_expr(*body, names);
                        }
                    }
                }
            }
            // inline_trait：方法体内可能引用外层变量
            crate::ast::Ast::Expr::InlineTrait(methods) => {
                for m in methods {
                    if let Some(body_expr) = m.body {
                        self.collect_free_idents_expr(body_expr, names);
                    }
                }
            }
            // 常量/无子表达式变体：IntLit/FloatLit/BoolLit/CharLit/StrLit/NullLit/VoidLit
            _ => {}
        }
    }

    /// 递归收集语句中的 Ident 名称（collect_free_idents_expr 的语句版本）。
    fn collect_free_idents_stmt(&self, stmt_id: crate::ast::Ast::StmtId, names: &mut Vec<String>) {
        let spanned = self.current_module().arena.stmt(stmt_id);
        match &spanned.node {
            crate::ast::Ast::Stmt::ValDecl { value, .. }
            | crate::ast::Ast::Stmt::VarDecl { value, .. } => {
                self.collect_free_idents_expr(*value, names);
            }
            crate::ast::Ast::Stmt::Expression { expr } => {
                self.collect_free_idents_expr(*expr, names);
            }
            crate::ast::Ast::Stmt::Assignment { target, value } => {
                self.collect_free_idents_expr(*target, names);
                self.collect_free_idents_expr(*value, names);
            }
            crate::ast::Ast::Stmt::FieldAssignment { object, value, .. } => {
                self.collect_free_idents_expr(*object, names);
                self.collect_free_idents_expr(*value, names);
            }
            crate::ast::Ast::Stmt::CompoundAssignment { target, value, .. } => {
                self.collect_free_idents_expr(*target, names);
                self.collect_free_idents_expr(*value, names);
            }
            crate::ast::Ast::Stmt::Return { value } => {
                if let Some(v) = value {
                    self.collect_free_idents_expr(*v, names);
                }
            }
            crate::ast::Ast::Stmt::Throw { expr } => {
                self.collect_free_idents_expr(*expr, names);
            }
            crate::ast::Ast::Stmt::For { iterable, body, .. } => {
                self.collect_free_idents_expr(*iterable, names);
                self.collect_free_idents_expr(*body, names);
            }
            crate::ast::Ast::Stmt::While { condition, body } => {
                self.collect_free_idents_expr(*condition, names);
                self.collect_free_idents_expr(*body, names);
            }
            crate::ast::Ast::Stmt::Loop { body } => {
                self.collect_free_idents_expr(*body, names);
            }
            crate::ast::Ast::Stmt::Defer { expr } => {
                self.collect_free_idents_expr(*expr, names);
            }
            crate::ast::Ast::Stmt::Break | crate::ast::Ast::Stmt::Continue => {}
            crate::ast::Ast::Stmt::LocalDecl { decl } => match decl.as_ref() {
                crate::ast::Ast::Decl::FunDecl { body, .. } => {
                    self.collect_free_idents_expr(*body, names);
                }
                _ => {}
            },
        }
    }

    /// 创建序列节点：等待 prev_effect 完成后返回 current_node 的值。
    ///
    /// 用于语句顺序链接：确保 prev_effect 执行完毕后才执行后续依赖 current_node 的节点。
    /// compute_seq (idx 48) 取所有输入，返回最后一个输入的值。
    fn chain_effects(&mut self, prev: Option<NodeId>, current: NodeId) -> NodeId {
        match prev {
            Some(prev_node) => {
                let off = self.graph.inputs_pool.push(&[prev_node, current]);
                self.graph.add_node(Node {
                    kind: NodeKind::BinOp,
                    input_count: 2,
                    inputs_offset: off,
                    compute_fn: CF_SEQ, // compute_seq
                })
            }
            None => current,
        }
    }

    /// 创建指向 `target_sg` 的 Call 节点（无输入依赖，立即就绪）。
    ///
    /// 用于循环的初始调用与 continue 跳转。
    fn compile_recursive_call(&mut self, target_sg: SubGraphId) -> NodeId {
        // 追加 current_effect 作为隐式依赖（与 compile_call 一致），
        // 确保 while/loop 的递归 Call 在前序语句（如数组字面量）完成后才执行。
        // 否则 Call 节点无输入依赖，可能在 arr 值就绪前启动子图帧，
        // 导致帧无法复制 arr 的 Ref 值，循环体内 arr[0] 返回 <non-scalar>。
        let mut inputs: Vec<NodeId> = Vec::new();
        if let Some(eff) = self.current_effect {
            inputs.push(eff);
        }
        let input_count = inputs.len() as u8;
        let inputs_offset = self.graph.inputs_pool.push(&inputs);
        let call_node = self.graph.add_node(Node {
            kind: NodeKind::Call,
            input_count,
            inputs_offset,
            compute_fn: CF_CALL_LAUNCH,
        });
        self.graph.set_call_target(call_node, target_sg);
        call_node
    }

    /// 创建指向 `target_sg` 的 Call 节点，传入指定参数节点。
    fn make_call(&mut self, target_sg: SubGraphId, arg_nodes: &[NodeId]) -> NodeId {
        let inputs_offset = self.graph.inputs_pool.push(arg_nodes);
        let call_node = self.graph.add_node(Node {
            kind: NodeKind::Call,
            input_count: arg_nodes.len() as u8,
            inputs_offset,
            compute_fn: CF_CALL_LAUNCH,
        });
        self.graph.set_call_target(call_node, target_sg);
        call_node
    }

    /// 创建指向函数名的 Call 节点（通过 func_subgraphs 查找目标）。
    fn make_call_by_name(&mut self, name: &str, arg_nodes: &[NodeId]) -> NodeId {
        let inputs_offset = self.graph.inputs_pool.push(arg_nodes);
        let call_node = self.graph.add_node(Node {
            kind: NodeKind::Call,
            input_count: arg_nodes.len() as u8,
            inputs_offset,
            compute_fn: CF_CALL_LAUNCH,
        });
        if let Some(&target_sg) = self.func_subgraphs.get(name) {
            self.graph.set_call_target(call_node, target_sg);
        }
        call_node
    }

    /// 创建 vtable 动态分派 Call 节点（trait 值的方法调用）。
    ///
    /// 与 make_call_by_name 区别：目标子图 id 运行时从 TraitVal 的 vtable 查询，
    /// 而非编译期绑定。用于 For 循环 iterable 是 trait 值（Iterator<T>）时。
    fn make_vtable_call(&mut self, recv_node: NodeId, trait_name: &str, method_name: &str) -> NodeId {
        let inputs_offset = self.graph.inputs_pool.push(&[recv_node]);
        let call_node = self.graph.add_node(Node {
            kind: NodeKind::Call,
            input_count: 1,
            inputs_offset,
            compute_fn: CF_CALL_LAUNCH,
        });
        let method_idx = self.sema.get_trait_def(trait_name)
            .and_then(|td| td.methods.iter().position(|m| m.name.as_ref() == method_name))
            .map(|i| i as u16)
            .unwrap_or(0);
        self.graph.set_vtable_call(call_node, method_idx);
        call_node
    }

    /// 从 Sema 查询表达式的类型信息（用于 For 循环分派决策）。
    /// 返回 (类型名, 是否为 trait 对象)：
    /// - (Some("RangeIterator"), false) → 静态分派 "RangeIterator.next"
    /// - (Some("Iterator"), true) → vtable 动态分派（inline_trait 值）
    /// - (None, false) → 类型推断失败，走 vtable 兜底
    fn lookup_expr_iter_info(&self, expr: crate::ast::Ast::ExprId) -> (Option<String>, bool) {
        let key = crate::sema::Sema::module_expr_key(self.current_module().name, expr.0 as u64);
        if let Some(info) = self.sema.expr_types.get(&key) {
            return (info.type_name.as_deref().map(|s| s.to_string()), info.is_trait_object);
        }
        (None, false)
    }

    /// 注册 For 循环子图（递归子图，param_count=1 接收迭代器）。
    ///
    /// 结构：
    /// - for_sg (param_count=1): 接收迭代器
    ///   - param_0 = 迭代器
    ///   - next_call = Call("Iterator.next", [param_0])  // 返回 T?
    ///   - is_null_node = UnOp(is_null, [next_call])
    ///   - body_sg (param_count=2): 迭代器 + 当前值（bind name, 编译 body, 尾递归 for_sg）
    ///   - void_sg (param_count=0): 退出
    ///   - gate = Gate(is_null_node): true→void_sg(退出), false→body_sg(继续)
    ///
    /// 执行：next() 返回非 null → body_sg 执行后尾递归 for_sg；返回 null → void_sg 退出。
    /// Break 信号终止 body_sg 帧 → Gate 完成 → for_sg 结束。
    /// Continue 编译为 Call(for_sg, [iter_param]) + Return 信号 → 尾递归下一轮。
    fn register_for_subgraph(
        &mut self,
        name: &str,
        body: crate::ast::Ast::ExprId,
        iter_type_name: Option<&str>,
        is_trait_object: bool,
    ) -> SubGraphId {
        let node_start = self.graph.nodes.len() as u32;
        let sg_id = SubGraphId(self.graph.subgraphs.len() as u32);
        // 占位注册（先占 id，便于递归引用）
        self.graph.add_subgraph(SubGraph {
            id: sg_id,
            node_range: (NodeId(node_start), NodeId(node_start)),
            param_count: 1,
            entry_node: NodeId(node_start),
            return_node: NodeId(node_start),
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: self.current_function_id,
            iter_next_node: None,
            upvalue_count: 0,
            upvalue_outer_nodes: Vec::new(),
        });

        // param_0 = 迭代器
        let iter_off = self.graph.inputs_pool.push(&[]);
        let iter_param = self.graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: iter_off,
            compute_fn: CF_NOOP,
        });

        // next_call = Call("{iter_type_name}.next", [iter_param]) → T?
        // 动态分派：is_trait_object=true 时走 vtable（运行时从 TraitVal 查 next）
        // 静态分派：具体类型按类型名 mangled 绑定（如 "ArrayIter.next"）
        // 兜底：类型推断失败（None）走 vtable
        let next_call = if is_trait_object || iter_type_name.is_none() {
            let trait_name = iter_type_name.as_deref().unwrap_or("Iterator");
            self.make_vtable_call(iter_param, trait_name, "next")
        } else {
            let next_method = format!("{}.next", iter_type_name.unwrap());
            self.make_call_by_name(&next_method, &[iter_param])
        };

        // is_null_node = UnOp(is_null, [next_call])
        let is_null_off = self.graph.inputs_pool.push(&[next_call]);
        let is_null_node = self.graph.add_node(Node {
            kind: NodeKind::UnOp,
            input_count: 1,
            inputs_offset: is_null_off,
            compute_fn: CF_IS_NULL, // is_null
        });

        // body_sg (param_count=2: 迭代器 + 当前值)
        // 重置 current_effect = None（同 register_while_subgraph，避免循环体帧
        // reset_loop_iteration 后外部 effect 依赖导致死锁）
        let prev_effect = self.current_effect;
        self.current_effect = None;
        let body_sg = self.compile_for_body_subgraph(body, sg_id, name);

        // void_sg (退出)
        let void_sg = self.compile_void_subgraph();
        self.current_effect = prev_effect;

        // gate = Gate(is_null_node): true→void_sg, false→body_sg(inputs=[iter_param, next_call])
        let gate_off = self.graph.inputs_pool.push(&[is_null_node]);
        let gate_node = self.graph.add_node(Node {
            kind: NodeKind::Gate,
            input_count: 1,
            inputs_offset: gate_off,
            compute_fn: CF_GATE_LAUNCH,
        });
        self.graph.set_gate_branches(
            gate_node,
            GateBranches {
                condition_input: is_null_node,
                branches: vec![
                    (true, void_sg, vec![]),
                    (false, body_sg, vec![iter_param, next_call]),
                ],
            },
        );

        let node_end = self.graph.nodes.len() as u32;
        let sg = &mut self.graph.subgraphs[sg_id.0 as usize];
        sg.node_range = (NodeId(node_start), NodeId(node_end));
        sg.entry_node = NodeId(node_start);
        sg.return_node = gate_node;
        sg.loop_kind = LoopKind::For;
        sg.cond_node = Some(is_null_node);
        sg.iter_next_node = Some(next_call);
        sg_id
    }

    /// 编译 For 循环体子图（param_count=2: 迭代器 + 当前值）。
    ///
    /// - param_0 = 迭代器（尾递归用）
    /// - param_1 = 当前值（绑定到循环变量 name）
    /// - 编译 body，末尾尾递归 Call(for_sg, [param_0])（依赖 body_last 保证顺序）
    fn compile_for_body_subgraph(
        &mut self,
        body: crate::ast::Ast::ExprId,
        for_sg: SubGraphId,
        name: &str,
    ) -> SubGraphId {
        let node_start = self.graph.nodes.len() as u32;

        // param_0 = 迭代器（body_sg 内的节点，由 Gate branch inputs 注入）
        let iter_off = self.graph.inputs_pool.push(&[]);
        let iter_param = self.graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: iter_off,
            compute_fn: CF_NOOP,
        });

        // param_1 = 当前值（绑定到循环变量 name）
        let val_off = self.graph.inputs_pool.push(&[]);
        let val_param = self.graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset: val_off,
            compute_fn: CF_NOOP,
        });

        self.enter_scope();
        self.bind_var(name, val_param);
        self.loop_stack.push(LoopContext {
            sg: for_sg,
            iter_node: Some(iter_param),
        });

        let prev_sg_start = self.current_sg_start;
        self.current_sg_start = node_start;
        let body_last = self.compile_expr(body);
        self.current_sg_start = prev_sg_start;

        self.loop_stack.pop();
        self.exit_scope();

        // 去尾递归：return_node = body_last，帧复用由 Engine 侧 reset_loop_iteration 处理
        let node_end = self.graph.nodes.len() as u32;
        let sg_id = SubGraphId(self.graph.subgraphs.len() as u32);
        self.graph.add_subgraph(SubGraph {
            id: sg_id,
            node_range: (NodeId(node_start), NodeId(node_end)),
            param_count: 2,
            entry_node: NodeId(node_start),
            return_node: body_last,
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: LoopKind::LoopBody,
            loop_parent_sg: Some(for_sg),
            cond_node: None,
            function_id: self.current_function_id,
            iter_next_node: None,
            upvalue_count: 0,
            upvalue_outer_nodes: Vec::new(),
        });
        sg_id
    }

    /// 注册 While 循环子图（递归子图）。
    ///
    /// 结构：
    /// - cond_node = compile_expr(condition)
    /// - gate_node = Gate(cond): true → body_sg(尾递归), false → void_sg(退出)
    /// - body_sg: 编译 body，末尾 Call 回 while_sg（依赖 body 末尾节点保证顺序）
    ///
    /// 执行：cond 为 true 时 body_sg 执行后尾递归 while_sg；false 时 void_sg 退出。
    /// Break 信号终止 body_sg 帧 → while_sg 的 Gate 完成 → 循环结束。
    /// Continue 编译为 Call(while_sg) + Return 信号 → 尾递归下一轮（跳过 body 剩余）。
    fn register_while_subgraph(
        &mut self,
        condition: crate::ast::Ast::ExprId,
        body: crate::ast::Ast::ExprId,
    ) -> SubGraphId {
        let node_start = self.graph.nodes.len() as u32;
        let sg_id = SubGraphId(self.graph.subgraphs.len() as u32);
        // 占位注册（先占 id，便于递归引用）
        self.graph.add_subgraph(SubGraph {
            id: sg_id,
            node_range: (NodeId(node_start), NodeId(node_start)),
            param_count: 0,
            entry_node: NodeId(node_start),
            return_node: NodeId(node_start),
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: self.current_function_id,
            iter_next_node: None,
            upvalue_count: 0,
            upvalue_outer_nodes: Vec::new(),
        });

        // 编译 condition
        // 重置 current_effect = None，避免在循环子图内创建依赖外部 effect 链的 CF_SEQ 节点。
        // 循环体帧经 reset_loop_iteration 后值表被清空，外部 effect 节点不会重新复制，
        // 依赖它们的 CF_SEQ 节点会永久 pending 导致死锁。
        let prev_effect = self.current_effect;
        self.current_effect = None;
        let cond_node = self.compile_subexpr(condition);
        // body 子图（末尾尾递归调用 while_sg）
        let body_sg = self.compile_loop_body_subgraph(body, sg_id);
        // void 子图（false 分支，循环结束）
        let void_sg = self.compile_void_subgraph();
        self.current_effect = prev_effect;

        // Gate 节点：cond true → body_sg, false → void_sg
        let gate_off = self.graph.inputs_pool.push(&[cond_node]);
        let gate_node = self.graph.add_node(Node {
            kind: NodeKind::Gate,
            input_count: 1,
            inputs_offset: gate_off,
            compute_fn: CF_GATE_LAUNCH,
        });
        self.graph.set_gate_branches(
            gate_node,
            GateBranches {
                condition_input: cond_node,
                branches: vec![
                    (true, body_sg, vec![]),
                    (false, void_sg, vec![]),
                ],
            },
        );

        let node_end = self.graph.nodes.len() as u32;
        let sg = &mut self.graph.subgraphs[sg_id.0 as usize];
        sg.node_range = (NodeId(node_start), NodeId(node_end));
        sg.entry_node = NodeId(node_start);
        sg.return_node = gate_node;
        sg.loop_kind = LoopKind::While;
        sg.cond_node = Some(cond_node);
        sg_id
    }

    /// 注册 Loop 循环子图（无 condition，靠 Break 终止）。
    ///
    /// 结构（与 While 统一，cond 恒 true）：
    /// - cond_node = Const(true)
    /// - gate_node = Gate(cond): true → body_sg, false → void_sg(不可达)
    /// - body_sg: 编译 body，不尾递归（Engine 侧帧复用）
    ///
    /// 执行：body 执行后 Engine 侧 reset_loop_iteration 重置 Gate 重新执行；
    /// Break 信号终止 body_sg → Gate 完成 → 循环结束。
    fn register_loop_subgraph(&mut self, body: crate::ast::Ast::ExprId) -> SubGraphId {
        let node_start = self.graph.nodes.len() as u32;
        let sg_id = SubGraphId(self.graph.subgraphs.len() as u32);
        self.graph.add_subgraph(SubGraph {
            id: sg_id,
            node_range: (NodeId(node_start), NodeId(node_start)),
            param_count: 0,
            entry_node: NodeId(node_start),
            return_node: NodeId(node_start),
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: LoopKind::None,
            loop_parent_sg: None,
            cond_node: None,
            function_id: self.current_function_id,
            iter_next_node: None,
            upvalue_count: 0,
            upvalue_outer_nodes: Vec::new(),
        });

        // cond_node = Const(true)（loop 无条件件，恒真）
        let cond_node = self.compile_bool_const(true);
        // 重置 current_effect = None（同 register_while_subgraph，避免循环体帧
        // reset_loop_iteration 后外部 effect 依赖导致死锁）
        let prev_effect = self.current_effect;
        self.current_effect = None;
        // body 子图（不尾递归）
        let body_sg = self.compile_loop_body_subgraph(body, sg_id);
        // void 子图（不可达分支，break 退出时用）
        let void_sg = self.compile_void_subgraph();
        self.current_effect = prev_effect;

        // Gate 节点：cond(true) → body_sg, false → void_sg(不可达)
        let gate_off = self.graph.inputs_pool.push(&[cond_node]);
        let gate_node = self.graph.add_node(Node {
            kind: NodeKind::Gate,
            input_count: 1,
            inputs_offset: gate_off,
            compute_fn: CF_GATE_LAUNCH,
        });
        self.graph.set_gate_branches(
            gate_node,
            GateBranches {
                condition_input: cond_node,
                branches: vec![
                    (true, body_sg, vec![]),
                    (false, void_sg, vec![]),
                ],
            },
        );

        let node_end = self.graph.nodes.len() as u32;
        let sg = &mut self.graph.subgraphs[sg_id.0 as usize];
        sg.node_range = (NodeId(node_start), NodeId(node_end));
        sg.entry_node = NodeId(node_start);
        sg.return_node = gate_node;
        sg.loop_kind = LoopKind::Loop;
        sg.cond_node = Some(cond_node);
        sg_id
    }

    /// 编译循环体子图：编译 body，不尾递归（帧复用由 Engine 侧 reset_loop_iteration 处理）。
    ///
    /// `loop_sg` 为 While 的 while_sg 或 Loop 的 loop_sg。
    /// return_node = body_last（body 末尾节点），Engine 侧检测 LoopBody 完成后重置循环。
    fn compile_loop_body_subgraph(
        &mut self,
        body: crate::ast::Ast::ExprId,
        loop_sg: SubGraphId,
    ) -> SubGraphId {
        let node_start = self.graph.nodes.len() as u32;
        let prev_sg_start = self.current_sg_start;
        self.current_sg_start = node_start;
        // 压入循环上下文（continue 跳转目标，While/Loop 无迭代器参数）
        self.loop_stack.push(LoopContext {
            sg: loop_sg,
            iter_node: None,
        });
        let body_last = self.compile_expr(body);
        self.loop_stack.pop();
        self.current_sg_start = prev_sg_start;
        let node_end = self.graph.nodes.len() as u32;
        let sg_id = SubGraphId(self.graph.subgraphs.len() as u32);
        self.graph.add_subgraph(SubGraph {
            id: sg_id,
            node_range: (NodeId(node_start), NodeId(node_end)),
            param_count: 0,
            entry_node: NodeId(node_start),
            return_node: body_last,
            has_suspend: false,
            event_source_decls: Vec::new(),
            defer_table: Vec::new(),
            loop_kind: LoopKind::LoopBody,
            loop_parent_sg: Some(loop_sg),
            cond_node: None,
            function_id: self.current_function_id,
            iter_next_node: None,
            upvalue_count: 0,
            upvalue_outer_nodes: Vec::new(),
        });
        sg_id
    }

    ///
    /// 每个 arm 编译为一个 Gate：
    /// - 判别节点 = 模式匹配结果（bool），作为 Gate 的 condition_input
    /// - Gate(true) → arm body 子图
    /// - Gate(false) → 下一个 arm 的 Gate 子图（作为 else 分支）
    ///
    /// 链式结构（从最后一个 arm 往前构建）：每个非首个 arm 的 Gate + pattern 包装为独立
    /// 子图（param_count=1，接收 scrutinee 作为参数），作为前一个 arm 的 else 分支。
    ///首个 arm 的 Gate 留在父帧，return_node = 该 Gate。
    ///
    /// scrutinee 通过 Gate 的 branch inputs 逐层注入到 wrap 子图的 param 节点，
    /// 使每个 wrap 子图内的 pattern 判别能访问 scrutinee。
    ///
    /// 两阶段编译：
    /// 1. 从前往后：对每个 arm 编译 pattern 判别 + 变量绑定 + body 子图
    /// 2. 从后往前：构建 Gate else 链，包装 wrap 子图
    ///
    /// 模式变量通过 bind_var 绑定到字段提取节点，body 子图通过帧链穿透访问。
    fn compile_match(
        &mut self,
        scrutinee: crate::ast::Ast::ExprId,
        arms: &[crate::ast::Ast::MatchArm],
    ) -> NodeId {
        // 空 match：返回 void 常量节点，避免 panic
        if arms.is_empty() {
            return self.compile_void_const();
        }

        let scrutinee_node = self.compile_subexpr(scrutinee);
        let n_arms = arms.len();

        // 第一阶段：从前往后编译每个 arm 的 pattern + body
        struct ArmData {
            wrap_start: u32,
            scrutinee_in_frame: NodeId,
            cond_node: NodeId,
            body_sg: SubGraphId,
            body_inputs: Vec<NodeId>,
        }

        let mut arm_data: Vec<ArmData> = Vec::with_capacity(n_arms);

        for (i, arm) in arms.iter().enumerate() {
            let wrap_start = self.graph.nodes.len() as u32;

            // scrutinee 来源：i==0 在父帧直接用 scrutinee_node；i>0 用 param 节点
            let scrutinee_in_frame = if i == 0 {
                scrutinee_node
            } else {
                let off = self.graph.inputs_pool.push(&[]);
                self.graph.add_node(Node {
                    kind: NodeKind::Const,
                    input_count: 0,
                    inputs_offset: off,
                    compute_fn: CF_NOOP,
                })
            };

            // 进入 scope 绑定模式变量
            self.enter_scope();

            // 编译 pattern：生成判别节点 + 绑定变量到字段提取节点
            let pattern_node = self.compile_pattern_match(scrutinee_in_frame, arm.pattern);

            // 守卫条件：pattern_match && guard
            let cond_node = if let Some(guard) = arm.guard {
                let guard_node = self.compile_subexpr(guard);
                self.compile_bool_and(pattern_node, guard_node)
            } else {
                pattern_node
            };

            // 编译 body 子图（模式变量在 scope 中可查找）
            let (body_sg, body_inputs) = self.compile_branch_subgraph(arm.body);

            self.exit_scope();

            arm_data.push(ArmData {
                wrap_start,
                scrutinee_in_frame,
                cond_node,
                body_sg,
                body_inputs,
            });
        }

        // 第二阶段：从后往前构建 Gate else 链
        let mut pending_else_sg: Option<SubGraphId> = None;
        let mut result_gate: Option<NodeId> = None;

        for (i, ad) in arm_data.iter().enumerate().rev() {
            // 所有 arm 都使用 cond_node 作为判别条件。
            // 这确保 Gate 依赖字段提取节点（通过 cond_node 的依赖链），
            // 使变量绑定的字段提取节点在 Gate 之前执行。
            // 最后一个 arm 如果是穷尽匹配（如 _），cond_node 为 true，无额外开销。
            let pattern_node = ad.cond_node;

            // false 分支：有 pending_else（来自 i+1）则用之并传入当前帧的 scrutinee
            let (false_sg, false_inputs) = match pending_else_sg {
                Some(else_sg) => (else_sg, vec![ad.scrutinee_in_frame]),
                None => (self.compile_void_subgraph(), Vec::new()),
            };

            // Gate 依赖 pattern_node（条件值）和 current_effect（effect 链前序副作用）
            let gate_inputs: Vec<NodeId> = match self.current_effect {
                Some(eff) => vec![pattern_node, eff],
                None => vec![pattern_node],
            };
            let gate_off = self.graph.inputs_pool.push(&gate_inputs);
            let gate_node = self.graph.add_node(Node {
                kind: NodeKind::Gate,
                input_count: gate_inputs.len() as u8,
                inputs_offset: gate_off,
                compute_fn: CF_GATE_LAUNCH,
            });
            self.graph.set_gate_branches(
                gate_node,
                GateBranches {
                    condition_input: pattern_node,
                    branches: vec![
                        (true, ad.body_sg, ad.body_inputs.clone()),
                        (false, false_sg, false_inputs),
                    ],
                },
            );

            if i == 0 {
                result_gate = Some(gate_node);
            } else {
                let wrap_end = self.graph.nodes.len() as u32;
                let wrap_sg = SubGraphId(self.graph.subgraphs.len() as u32);
                self.graph.add_subgraph(SubGraph {
                    id: wrap_sg,
                    node_range: (NodeId(ad.wrap_start), NodeId(wrap_end)),
                    param_count: 1,
                    entry_node: NodeId(ad.wrap_start),
                    return_node: gate_node,
                    has_suspend: false,
                    event_source_decls: Vec::new(),
                    defer_table: Vec::new(),
                    loop_kind: LoopKind::None,
                    loop_parent_sg: None,
                    cond_node: None,
                    function_id: self.current_function_id,
                    iter_next_node: None,
                    upvalue_count: 0,
                    upvalue_outer_nodes: Vec::new(),
                });
                pending_else_sg = Some(wrap_sg);
            }
        }

        result_gate.expect("match must have at least one arm")
    }

    /// 编译 bool 常量节点。
    fn compile_bool_const(&mut self, b: bool) -> NodeId {
        let inputs_offset = self.graph.inputs_pool.push(&[]);
        let n = self.graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset,
            compute_fn: CF_NOOP,
        });
        self.graph.const_values[n.0 as usize] = Some(ConstValue::Bool(b));
        n
    }

    /// 编译 bool AND 节点（用于守卫条件 pattern && guard）。
    fn compile_bool_and(&mut self, lhs: NodeId, rhs: NodeId) -> NodeId {
        let off = self.graph.inputs_pool.push(&[lhs, rhs]);
        self.graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: 2,
            inputs_offset: off,
            compute_fn: CF_AND_BOOL, // and_bool
        })
    }

    /// 编译 bool OR 节点（用于或模式 p1 | p2）。
    fn compile_bool_or(&mut self, lhs: NodeId, rhs: NodeId) -> NodeId {
        let off = self.graph.inputs_pool.push(&[lhs, rhs]);
        self.graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: 2,
            inputs_offset: off,
            compute_fn: CF_OR_BOOL, // or_bool
        })
    }

    /// 编译模式匹配判别节点（返回 bool），同时绑定模式变量到字段提取节点。
    ///
    /// 递归处理所有模式类型：
    /// - Wildcard/Variable → const(true)，Variable 绑定变量到 scrutinee
    /// - Literal → eq(scrutinee, lit)，按类型选择 compute_fn
    /// - Constructor → 构造器名判别 + 递归子模式
    /// - Record → 字段提取 + 递归子模式
    /// - OrPattern → left_match || right_match
    /// - Guard → pattern_match && condition
    fn compile_pattern_match(
        &mut self,
        scrutinee_node: NodeId,
        pattern_id: crate::ast::Ast::PatternId,
    ) -> NodeId {
        let pattern = self.current_module().arena.pattern(pattern_id);
        match &pattern.node {
            crate::ast::Ast::Pattern::Wildcard => self.compile_bool_const(true),
            crate::ast::Ast::Pattern::Variable { name } => {
                // 无参 ADT 构造器（如 JNull、Nil）在解析时无法与变量区分，
                // 通过 sema 的 ctor_def_index 判别：若为已知构造器则按 Constructor 编译
                if self.sema.ctor_def_index.contains_key(*name) {
                    self.compile_pattern_constructor(scrutinee_node, name, &[])
                } else {
                    self.bind_var(name, scrutinee_node);
                    self.compile_bool_const(true)
                }
            }
            crate::ast::Ast::Pattern::Literal(pl) => {
                self.compile_pattern_literal_match(scrutinee_node, pl)
            }
            crate::ast::Ast::Pattern::Constructor { name, patterns } => {
                self.compile_pattern_constructor(scrutinee_node, name, patterns)
            }
            crate::ast::Ast::Pattern::Record { fields } => {
                self.compile_pattern_record(scrutinee_node, fields)
            }
            crate::ast::Ast::Pattern::OrPattern { left, right } => {
                let left_match = self.compile_pattern_match(scrutinee_node, *left);
                let right_match = self.compile_pattern_match(scrutinee_node, *right);
                self.compile_bool_or(left_match, right_match)
            }
            crate::ast::Ast::Pattern::Guard { pattern, condition } => {
                let pattern_match = self.compile_pattern_match(scrutinee_node, *pattern);
                let cond_node = self.compile_subexpr(*condition);
                self.compile_bool_and(pattern_match, cond_node)
            }
        }
    }

    /// 编译字面量模式判别节点。
    fn compile_pattern_literal_match(
        &mut self,
        scrutinee_node: NodeId,
        pl: &crate::ast::Ast::PatternLiteral,
    ) -> NodeId {
        match pl {
            crate::ast::Ast::PatternLiteral::Null => {
                // null 判别：compute_is_null（idx 34）
                let off = self.graph.inputs_pool.push(&[scrutinee_node]);
                self.graph.add_node(Node {
                    kind: NodeKind::BinOp,
                    input_count: 1,
                    inputs_offset: off,
                    compute_fn: CF_IS_NULL,
                })
            }
            crate::ast::Ast::PatternLiteral::String(s) => {
                // 字符串判别：compute_pattern_str_eq（idx 276）
                let str_node = self.compile_str_const(s);
                let off = self.graph.inputs_pool.push(&[scrutinee_node, str_node]);
                self.graph.add_node(Node {
                    kind: NodeKind::BinOp,
                    input_count: 2,
                    inputs_offset: off,
                    compute_fn: CF_PATTERN_STR_EQ,
                })
            }
            crate::ast::Ast::PatternLiteral::Int(s) => {
                let lit_node = self.compile_pattern_literal(pl);
                let compute_fn = self.select_literal_eq_fn(s, false);
                let off = self.graph.inputs_pool.push(&[scrutinee_node, lit_node]);
                self.graph.add_node(Node {
                    kind: NodeKind::BinOp,
                    input_count: 2,
                    inputs_offset: off,
                    compute_fn,
                })
            }
            crate::ast::Ast::PatternLiteral::Float(_) => {
                let lit_node = self.compile_pattern_literal(pl);
                let off = self.graph.inputs_pool.push(&[scrutinee_node, lit_node]);
                self.graph.add_node(Node {
                    kind: NodeKind::BinOp,
                    input_count: 2,
                    inputs_offset: off,
                    compute_fn: CF_EQ_F64, // eq_f64
                })
            }
            crate::ast::Ast::PatternLiteral::Bool(_) => {
                let lit_node = self.compile_pattern_literal(pl);
                let off = self.graph.inputs_pool.push(&[scrutinee_node, lit_node]);
                self.graph.add_node(Node {
                    kind: NodeKind::BinOp,
                    input_count: 2,
                    inputs_offset: off,
                    compute_fn: CF_EQ_BOOL, // eq_bool
                })
            }
            crate::ast::Ast::PatternLiteral::Char(_) => {
                let lit_node = self.compile_pattern_literal(pl);
                let off = self.graph.inputs_pool.push(&[scrutinee_node, lit_node]);
                self.graph.add_node(Node {
                    kind: NodeKind::BinOp,
                    input_count: 2,
                    inputs_offset: off,
                    compute_fn: CF_EQ_I32, // eq_i32 (char 存为 i32)
                })
            }
        }
    }

    /// 选择整数字面量相等判别的 compute_fn。
    fn select_literal_eq_fn(&self, s: &str, _is_unsigned: bool) -> ComputeFnId {
        // 检查后缀
        if let Some(suffix) = s.find(|c: char| c.is_ascii_alphabetic()) {
            let suffix_str = &s[suffix..];
            return match suffix_str {
                "i64" | "u64" | "isize" | "usize" => CF_EQ_I64, // eq_i64
                "i128" | "u128" => CF_EQ_I128,                    // eq_i128
                _ => CF_EQ_I32,                                    // eq_i32
            };
        }
        CF_EQ_I32 // eq_i32 默认
    }

    /// 编译构造器模式：构造器名判别 + 递归子模式。
    fn compile_pattern_constructor(
        &mut self,
        scrutinee_node: NodeId,
        name: &str,
        patterns: &[crate::ast::Ast::PatternRef],
    ) -> NodeId {
        // 构造器名判别节点
        let ctor_match_off = self.graph.inputs_pool.push(&[scrutinee_node]);
        let ctor_match_node = self.graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: 1,
            inputs_offset: ctor_match_off,
            compute_fn: CF_PATTERN_CTOR_MATCH, // pattern_ctor_match
        });
        self.graph.set_pattern_ctor_name(ctor_match_node, name.to_string());

        // 递归处理子模式：提取字段 + 判别
        let mut result = ctor_match_node;
        for (i, &sub_pattern_id) in patterns.iter().enumerate() {
            // 字段提取节点（按位置）
            let field_get_off = self.graph.inputs_pool.push(&[scrutinee_node]);
            let field_get_node = self.graph.add_node(Node {
                kind: NodeKind::BinOp,
                input_count: 1,
                inputs_offset: field_get_off,
                compute_fn: CF_PATTERN_ADT_FIELD_GET, // pattern_adt_field_get
            });
            self.graph.set_pattern_field_index(field_get_node, i as u16);

            // 递归编译子模式（可能绑定变量）
            let sub_match = self.compile_pattern_match(field_get_node, sub_pattern_id);

            // result = result && sub_match
            // field_get_node 作为额外依赖输入：确保变量绑定的字段提取节点
            // 在 Gate 触发前执行（compute_and_bool 只读 inputs[0..2]，inputs[2] 仅用于调度）
            let and_off = self.graph.inputs_pool.push(&[result, sub_match, field_get_node]);
            result = self.graph.add_node(Node {
                kind: NodeKind::BinOp,
                input_count: 3,
                inputs_offset: and_off,
                compute_fn: CF_AND_BOOL, // and_bool (ignores inputs[2])
            });
        }

        result
    }

    /// 编译记录模式：字段提取 + 递归子模式。
    fn compile_pattern_record(
        &mut self,
        scrutinee_node: NodeId,
        fields: &[crate::ast::Ast::PatternRecordField<'_>],
    ) -> NodeId {
        let mut result = self.compile_bool_const(true);

        for field in fields.iter() {
            // 字段提取节点（按名访问，复用 compute_record_field_get idx 30）
            let field_get_off = self.graph.inputs_pool.push(&[scrutinee_node]);
            let field_get_node = self.graph.add_node(Node {
                kind: NodeKind::FieldAccess,
                input_count: 1,
                inputs_offset: field_get_off,
                compute_fn: CF_RECORD_FIELD_GET, // record_field_get
            });
            self.graph.set_field_set_name(field_get_node, field.name.to_string());

            // 递归编译子模式
            let sub_match = self.compile_pattern_match(field_get_node, field.pattern);

            // field_get_node 作为额外依赖输入（同 compile_pattern_constructor）
            let and_off = self.graph.inputs_pool.push(&[result, sub_match, field_get_node]);
            result = self.graph.add_node(Node {
                kind: NodeKind::BinOp,
                input_count: 3,
                inputs_offset: and_off,
                compute_fn: CF_AND_BOOL,
            });
        }

        result
    }

    /// 编译字面量模式为 Const 节点。
    fn compile_pattern_literal(&mut self, pl: &crate::ast::Ast::PatternLiteral) -> NodeId {
        let const_val = match pl {
            crate::ast::Ast::PatternLiteral::Int(s) => {
                // 去除后缀再解析
                let digits: String = s.chars().take_while(|c| c.is_ascii_digit() || *c == '-' || *c == '+').collect();
                digits.parse::<i32>().ok().map(ConstValue::I32)
            }
            crate::ast::Ast::PatternLiteral::Float(s) => s.parse::<f64>().ok().map(ConstValue::F64),
            crate::ast::Ast::PatternLiteral::Bool(b) => Some(ConstValue::Bool(*b)),
            crate::ast::Ast::PatternLiteral::String(_) => {
                Some(ConstValue::Bool(true)) // 占位，实际用 compile_str_const
            }
            crate::ast::Ast::PatternLiteral::Char(c) => Some(ConstValue::I32(*c as i32)),
            crate::ast::Ast::PatternLiteral::Null => Some(ConstValue::Null),
        };
        let inputs_offset = self.graph.inputs_pool.push(&[]);
        let n = self.graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset,
            compute_fn: CF_NOOP,
        });
        self.graph.const_values[n.0 as usize] = const_val;
        n
    }

    /// 编译字符串常量节点（用于模式匹配的字符串字面量）。
    fn compile_str_const(&mut self, s: &str) -> NodeId {
        let static_s: &'static str = Box::leak(s.to_string().into_boxed_str());
        let inputs_offset = self.graph.inputs_pool.push(&[]);
        let n = self.graph.add_node(Node {
            kind: NodeKind::Const,
            input_count: 0,
            inputs_offset,
            compute_fn: CF_NOOP,
        });
        self.graph.const_values[n.0 as usize] = Some(ConstValue::Str(static_s));
        n
    }

    /// 编译字符串插值：将 `"text {expr} more {expr}"` 降级为链式 str_concat。
    ///
    /// 每个 Literal 部分编译为字符串常量节点；
    /// 每个 Expression 部分通过 `compute_reflect_format`（idx 290）转换为字符串；
    /// 所有部分通过 `compute_str_concat`（idx 269）链式拼接。
    fn compile_str_interp(
        &mut self,
        parts: &[crate::ast::Ast::InterpolationPart<'_>],
    ) -> NodeId {
        if parts.is_empty() {
            return self.compile_str_const("");
        }

        // 收集所有部分的节点
        let mut nodes: Vec<NodeId> = Vec::with_capacity(parts.len());
        for part in parts {
            match part {
                crate::ast::Ast::InterpolationPart::Literal(text) => {
                    if !text.is_empty() {
                        nodes.push(self.compile_str_const(text));
                    }
                }
                crate::ast::Ast::InterpolationPart::Expression(expr_id) => {
                    let expr_node = self.compile_subexpr(*expr_id);
                    // 通过 compute_reflect_format 将任意值转为字符串
                    //（独立 compute_fn，不走 FFI 分派，自带 lazy force）
                    let inputs_offset = self.graph.inputs_pool.push(&[expr_node]);
                    let reflect_node = self.graph.add_node(Node {
                        kind: NodeKind::Call,
                        input_count: 1,
                        inputs_offset,
                        compute_fn: CF_REFLECT_FORMAT, // compute_reflect_format
                    });
                    nodes.push(reflect_node);
                }
            }
        }

        // 单个部分：直接返回
        if nodes.len() == 1 {
            return nodes[0];
        }

        // 链式拼接：((part0 concat part1) concat part2) ...
        let mut result = nodes[0];
        for &next in &nodes[1..] {
            let inputs_offset = self.graph.inputs_pool.push(&[result, next]);
            result = self.graph.add_node(Node {
                kind: NodeKind::BinOp,
                input_count: 2,
                inputs_offset,
                compute_fn: CF_STR_CONCAT, // compute_str_concat
            });
        }
        result
    }

    /// 将任意值节点通过 compute_reflect_format（idx 290）转为字符串节点。
    /// 用于 `str + non-str` 拼接时将非字符串操作数转为字符串（与字符串插值一致）。
    fn make_reflect_format_node(&mut self, value_node: NodeId) -> NodeId {
        let inputs_offset = self.graph.inputs_pool.push(&[value_node]);
        self.graph.add_node(Node {
            kind: NodeKind::Call,
            input_count: 1,
            inputs_offset,
            compute_fn: CF_REFLECT_FORMAT,
        })
    }

    /// 查询表达式的类型名（来自 Sema）。
    ///
    /// 优先取 ExprInfo.type_name（adt/generic 等场景），回退到 type_desc.type_name。
    /// 当 Sema 无记录时（trait 默认方法特化版本中的 self），回退到 trait_self_type
    /// （前提是 expr 是 Ident("self")）。
    fn expr_type_name(&self, expr_id: crate::ast::Ast::ExprId) -> Option<&str> {
        // trait 默认方法特化版本中的 self：Sema 将其类型注册为 "void"（因 trait 方法无具体类型），
        // 此处用 trait_self_type 覆盖，使 self.method() 能静态绑定到具体类型的方法子图。
        if let Some(ref ty) = self.trait_self_type {
            if let crate::ast::Ast::Expr::Ident(name) = &self.module.arena.expr(expr_id).node {
                if *name == "self" {
                    return Some(ty.as_str());
                }
            }
        }
        let key = crate::sema::Sema::module_expr_key(self.current_module().name, expr_id.0 as u64);
        self.sema.expr_types.get(&key).map(|info| {
            info.type_name
                .as_deref()
                .unwrap_or(info.type_desc.type_name)
        })
    }

    /// 判断表达式是否为 nullable 类型（ConcreteType::Nullable）。
    /// nullable 类型的 ==/!= 需要 null 判别式比较：?. 短路或 null 字面量
    /// 产生 Value::Null，str/i32 等专用比较函数不处理 Null 导致结果错误。
    /// 分派到 CF_EQ_OBJ/CF_NE_OBJ（value_equals_with_arena 正确处理 Null）。
    fn expr_is_nullable(&self, expr_id: crate::ast::Ast::ExprId) -> bool {
        let key = crate::sema::Sema::module_expr_key(self.current_module().name, expr_id.0 as u64);
        self.sema
            .expr_types
            .get(&key)
            .map(|info| info.type_desc.type_name == "nullable")
            .unwrap_or(false)
    }

    /// 类型族：按整数宽度分派到 i32/i64/i128 路径（仅用于比较运算，结果为 bool）。
    /// i8/i16/u8/u16/u32/char → I32 路径；i64/u64/isize/usize → I64 路径；i128/u128 → I128 路径。
    fn int_family(ty_name: &str) -> &'static str {
        match crate::Value::ScalarTag::from_name(ty_name).and_then(scalar_meta) {
            Some(m) => m.family,
            None => "i32", // 未知整数类型回退到 i32 路径
        }
    }

    /// 算术/位运算 compute_fn 查表：按具体类型名返回算术基址。
    /// 整数类型每 12 个连续索引（add/sub/mul/div/mod/bitand/bitor/bitxor/shl/shr/neg/bitnot）；
    /// 浮点类型每 6 个连续索引（add/sub/mul/div/mod/neg，无位运算）。
    /// 返回 None 表示该类型不支持算术运算。
    /// 基址来自 `scalar_meta`，与 compute_fn_table! 的索引单点同步。
    fn arith_base(ty_name: &str) -> Option<u32> {
        crate::Value::ScalarTag::from_name(ty_name).and_then(scalar_meta).map(|m| m.arith_base)
    }

    /// 根据 op + 表达式类型选择 compute_fn id。
    fn select_binary_compute_fn(
        &self,
        op: crate::ast::Ast::BinaryOp,
        lhs_expr: crate::ast::Ast::ExprId,
    ) -> ComputeFnId {
        let ty_name = self.expr_type_name(lhs_expr).unwrap_or("i32");
        let ty_meta = crate::Value::ScalarTag::from_name(ty_name).and_then(scalar_meta);
        let is_float = ty_meta.as_ref().map(|m| m.is_float).unwrap_or(false);
        let is_int = !is_float && ty_name != "bool";
        let base = Self::arith_base(ty_name);

        // Elvis (??) 运算：lhs 为 null 时返回 rhs，否则返回 lhs。
        // 不依赖操作数类型，必须在 str/复合类型分支之前处理。
        if matches!(op, crate::ast::Ast::BinaryOp::Elvis) {
            return CF_ELVIS;
        }

        // nullable 类型的 ==/!=：?. 短路或 null 字面量产生 Value::Null，
        // str/i32 等专用比较函数不处理 Null（heap_obj() 返回 None 导致恒 false）。
        // 分派到 CF_EQ_OBJ/CF_NE_OBJ（value_equals_with_arena 正确处理 Null 判别）。
        if matches!(op, crate::ast::Ast::BinaryOp::Eq | crate::ast::Ast::BinaryOp::NotEq)
            && self.expr_is_nullable(lhs_expr)
        {
            return match op {
                crate::ast::Ast::BinaryOp::Eq => CF_EQ_OBJ,
                crate::ast::Ast::BinaryOp::NotEq => CF_NE_OBJ,
                _ => unreachable!(),
            };
        }

        // str + str → 字符串拼接（compute_str_concat, 269）
        if ty_name == "str" && matches!(op, crate::ast::Ast::BinaryOp::Add) {
            return CF_STR_CONCAT;
        }

        // str 比较 → 专用 str 比较 compute_fn（292-297）
        // 不走 i32 路径：str 无 as_i32 语义，走 i32 会恒为 0 导致结果错误
        if ty_name == "str" {
            return match op {
                crate::ast::Ast::BinaryOp::Eq => CF_EQ_STR,
                crate::ast::Ast::BinaryOp::NotEq => CF_NE_STR,
                crate::ast::Ast::BinaryOp::Lt => CF_LT_STR,
                crate::ast::Ast::BinaryOp::Gt => CF_GT_STR,
                crate::ast::Ast::BinaryOp::LtEq => CF_LE_STR,
                crate::ast::Ast::BinaryOp::GtEq => CF_GE_STR,
                _ => CF_EQ_STR, // 算术等已在上面处理，此处不会到达
            };
        }

        // 复合类型（record/adt/newtype/array/closure/throw 等）相等/不等 →
        // 通用语义比较 compute_fn（298-299）。走 i32 路径会因 as_i32() 恒为 0
        // 导致所有复合类型判为相等。
        if matches!(op, crate::ast::Ast::BinaryOp::Eq | crate::ast::Ast::BinaryOp::NotEq)
            && ty_meta.is_none()
        {
            return match op {
                crate::ast::Ast::BinaryOp::Eq => CF_EQ_OBJ,
                crate::ast::Ast::BinaryOp::NotEq => CF_NE_OBJ,
                _ => unreachable!(),
            };
        }

        // 算术运算（add/sub/mul/div/mod）：整数和浮点都支持，按具体类型查表
        // 整数索引顺序: add(0) sub(1) mul(2) div(3) mod(4) bitand(5) bitor(6) bitxor(7) shl(8) shr(9) neg(10) bitnot(11)
        // 浮点索引顺序: add(0) sub(1) mul(2) div(3) mod(4) neg(5)
        let arith_offset = |op: &crate::ast::Ast::BinaryOp| -> Option<u32> {
            match op {
                crate::ast::Ast::BinaryOp::Add => Some(0),
                crate::ast::Ast::BinaryOp::Sub => Some(1),
                crate::ast::Ast::BinaryOp::Mul => Some(2),
                crate::ast::Ast::BinaryOp::Div => Some(3),
                crate::ast::Ast::BinaryOp::Mod => Some(4),
                _ => None,
            }
        };
        if let Some(off) = arith_offset(&op) {
            if let Some(b) = base {
                return ComputeFnId(b + off);
            }
            // 未知类型回退到 i32 路径
            return ComputeFnId(116 + off);
        }

        // 位运算（bitand/bitor/bitxor/shl/shr）：仅整数支持
        if is_int {
            let bit_offset = match op {
                crate::ast::Ast::BinaryOp::BitAnd => Some(5),
                crate::ast::Ast::BinaryOp::BitOr => Some(6),
                crate::ast::Ast::BinaryOp::BitXor => Some(7),
                crate::ast::Ast::BinaryOp::Shl => Some(8),
                crate::ast::Ast::BinaryOp::Shr => Some(9),
                _ => None,
            };
            if let Some(off) = bit_offset {
                if let Some(b) = base {
                    return ComputeFnId(b + off);
                }
                return ComputeFnId(CF_ADD_I32_FULL.0 + off); // 回退 i32
            }
        }

        // 比较运算：结果为 bool，输入按类型族读取
        let fam = Self::int_family(ty_name);
        match op {
            crate::ast::Ast::BinaryOp::Eq => {
                if is_float { CF_EQ_F64 }     // eq_f64
                else if ty_name == "bool" { CF_EQ_BOOL } // eq_bool
                else if fam == "i128" { CF_EQ_I128 } // eq_i128
                else if fam == "i64" { CF_EQ_I64 }  // eq_i64
                else { CF_EQ_I32 }              // eq_i32
            }
            crate::ast::Ast::BinaryOp::NotEq => {
                if is_float { CF_NE_F64 }     // ne_f64
                else if fam == "i128" { CF_NE_I128 } // ne_i128
                else if fam == "i64" { CF_NE_I64 }  // ne_i64
                else { CF_NE_I32 }              // ne_i32
            }
            crate::ast::Ast::BinaryOp::Lt => {
                if is_float { CF_LT_F64 }     // lt_f64
                else if fam == "i128" { CF_LT_I128 } // lt_i128
                else if fam == "i64" { CF_LT_I64 }  // lt_i64
                else { CF_LT_I32 }             // lt_i32
            }
            crate::ast::Ast::BinaryOp::Gt => {
                if is_float { CF_GT_F64 }     // gt_f64
                else if fam == "i128" { CF_GT_I128 } // gt_i128
                else if fam == "i64" { CF_GT_I64 }  // gt_i64
                else { CF_GT_I32 }             // gt_i32
            }
            crate::ast::Ast::BinaryOp::LtEq => {
                if is_float { CF_LE_F64 }     // le_f64
                else if fam == "i128" { CF_LE_I128 } // le_i128
                else if fam == "i64" { CF_LE_I64 }  // le_i64
                else { CF_LE_I32 }              // le_i32
            }
            crate::ast::Ast::BinaryOp::GtEq => {
                if is_float { CF_GE_F64 }     // ge_f64
                else if fam == "i128" { CF_GE_I128 } // ge_i128
                else if fam == "i64" { CF_GE_I64 }  // ge_i64
                else { CF_GE_I32 }             // ge_i32
            }
            crate::ast::Ast::BinaryOp::And => CF_AND_BOOL, // and_bool
            crate::ast::Ast::BinaryOp::Or => CF_OR_BOOL,  // or_bool
            crate::ast::Ast::BinaryOp::RefEq => CF_REF_EQ,          // ref_eq
            crate::ast::Ast::BinaryOp::RefNeq => CF_REF_NEQ,         // ref_neq
            crate::ast::Ast::BinaryOp::ConcatList => CF_CONCAT_LIST,     // concat_list
            crate::ast::Ast::BinaryOp::Range => CF_RANGE,          // range
            crate::ast::Ast::BinaryOp::RangeInclusive => CF_RANGE_INCLUSIVE, // range_inclusive
            crate::ast::Ast::BinaryOp::Elvis => CF_ELVIS,          // elvis
            _ => CF_NOOP,
        }
    }

    /// 根据 op + operand 表达式类型选择一元运算 compute_fn id。
    fn select_unary_compute_fn(
        &self,
        op: crate::ast::Ast::UnaryOp,
        operand_expr: crate::ast::Ast::ExprId,
    ) -> ComputeFnId {
        let ty_name = self.expr_type_name(operand_expr).unwrap_or("i32");
        let is_float = crate::Value::ScalarTag::from_name(ty_name).and_then(scalar_meta).map(|m| m.is_float).unwrap_or(false);
        let base = Self::arith_base(ty_name);
        match op {
            crate::ast::Ast::UnaryOp::Not => CF_NOT_BOOL, // not_bool
            crate::ast::Ast::UnaryOp::Neg => {
                // 整数 neg 在 base+10，浮点 neg 在 base+5
                if let Some(b) = base {
                    let off = if is_float { 5 } else { 10 };
                    return ComputeFnId(b + off);
                }
                CF_NEG_I32_FULL // 回退 neg_i32
            }
            crate::ast::Ast::UnaryOp::BitNot => {
                // 仅整数，bitnot 在 base+11
                if let Some(b) = base {
                    return ComputeFnId(b + 11);
                }
                CF_BITNOT_I32_FULL // 回退 bitnot_i32
            }
        }
    }

    /// 编译二元运算。
    fn compile_binary(
        &mut self,
        op: crate::ast::Ast::BinaryOp,
        lhs: crate::ast::Ast::ExprId,
        rhs: crate::ast::Ast::ExprId,
    ) -> NodeId {
        // Range/RangeInclusive 编译为 range_iter(start, end, inclusive) 函数调用
        // （Range 本身是迭代器，For 循环通过 RangeIterator.next 静态分派）
        match op {
            crate::ast::Ast::BinaryOp::Range | crate::ast::Ast::BinaryOp::RangeInclusive => {
                let lhs_node = self.compile_subexpr(lhs);
                let rhs_node = self.compile_subexpr(rhs);
                let inclusive = matches!(op, crate::ast::Ast::BinaryOp::RangeInclusive);
                let bool_node = self.compile_bool_const(inclusive);
                self.make_call_by_name("range_iter", &[lhs_node, rhs_node, bool_node])
            }
            _ => {
                // str + non-str / non-str + str → 将非字符串操作数通过
                // compute_reflect_format 转为字符串后用 str_concat 拼接
                //（与字符串插值 "{expr}" 的降级路径一致）
                if matches!(op, crate::ast::Ast::BinaryOp::Add) {
                    let lhs_ty = self.expr_type_name(lhs).unwrap_or("");
                    let rhs_ty = self.expr_type_name(rhs).unwrap_or("");
                    let lhs_is_str = lhs_ty == "str";
                    let rhs_is_str = rhs_ty == "str";
                    if lhs_is_str || rhs_is_str {
                        let lhs_node = self.compile_subexpr(lhs);
                        let rhs_node = self.compile_subexpr(rhs);
                        let lhs_final = if lhs_is_str {
                            lhs_node
                        } else {
                            self.make_reflect_format_node(lhs_node)
                        };
                        let rhs_final = if rhs_is_str {
                            rhs_node
                        } else {
                            self.make_reflect_format_node(rhs_node)
                        };
                        let inputs_offset =
                            self.graph.inputs_pool.push(&[lhs_final, rhs_final]);
                        return self.graph.add_node(Node {
                            kind: NodeKind::BinOp,
                            input_count: 2,
                            inputs_offset,
                            compute_fn: CF_STR_CONCAT,
                        });
                    }
                }
                // 操作数不在尾位置：其值被运算节点消费，而非直接返回。
                let lhs_node = self.compile_subexpr(lhs);
                let rhs_node = self.compile_subexpr(rhs);
                let inputs_offset = self.graph.inputs_pool.push(&[lhs_node, rhs_node]);
                let compute_fn = self.select_binary_compute_fn(op, lhs);
                let node = self.graph.add_node(Node {
                    kind: NodeKind::BinOp,
                    input_count: 2,
                    inputs_offset,
                    compute_fn,
                });
                // 编译期标记 SIMD 批量化信息：标量类型 + 运算 → 运行期按 (tag,op) 分组批算
                if let Some(info) = self.binary_batch_info(op, lhs) {
                    self.graph.set_batch_info(node, info);
                }
                node
            }
        }
    }

    /// 将 Glue BinaryOp + 类型名映射为 BatchInfo（可批量化的运算+标量类型组合）。
    ///
    /// 返回 None 表示该运算不可 SIMD 批量化（如 And/Or/RefEq/ConcatList/Range
    /// 等非标量算术运算，或非标量类型）。
    fn binary_batch_info(
        &self,
        op: crate::ast::Ast::BinaryOp,
        lhs_expr: crate::ast::Ast::ExprId,
    ) -> Option<BatchInfo> {
        use crate::ast::Ast::BinaryOp;
        use crate::Value::{BinOp as VBinOp, CmpOp as VCmpOp};

        let ty = self.expr_type_name(lhs_expr)?;
        let tag = Self::ty_name_to_scalar_tag(ty)?;
        let is_float = scalar_meta(tag).map(|m| m.is_float).unwrap_or(false);

        let batch_op = match op {
            BinaryOp::Add => BatchOp::Bin(VBinOp::Add),
            BinaryOp::Sub => BatchOp::Bin(VBinOp::Sub),
            BinaryOp::Mul => BatchOp::Bin(VBinOp::Mul),
            BinaryOp::Div => BatchOp::Bin(VBinOp::Div),
            BinaryOp::Mod => BatchOp::Bin(VBinOp::Mod),
            BinaryOp::BitAnd if !is_float => BatchOp::Bin(VBinOp::Band),
            BinaryOp::BitOr if !is_float => BatchOp::Bin(VBinOp::Bor),
            BinaryOp::BitXor if !is_float => BatchOp::Bin(VBinOp::Bxor),
            BinaryOp::Shl if !is_float => BatchOp::Bin(VBinOp::Shl),
            BinaryOp::Shr if !is_float => BatchOp::Bin(VBinOp::Shr),
            BinaryOp::Eq => BatchOp::Cmp(VCmpOp::Eq),
            BinaryOp::NotEq => BatchOp::Cmp(VCmpOp::Ne),
            BinaryOp::Lt => BatchOp::Cmp(VCmpOp::Lt),
            BinaryOp::Gt => BatchOp::Cmp(VCmpOp::Gt),
            BinaryOp::LtEq => BatchOp::Cmp(VCmpOp::Le),
            BinaryOp::GtEq => BatchOp::Cmp(VCmpOp::Ge),
            // And/Or/RefEq/RefNeq/ConcatList/Range/RangeInclusive/Elvis → 不可批量化
            _ => return None,
        };
        Some(BatchInfo { tag, op: batch_op })
    }

    /// 将 Glue UnaryOp + 类型名映射为 BatchInfo。
    ///
    /// Neg（整数/浮点取负）和 BitNot（整数按位取反）可批量化；
    /// Not（bool 逻辑非）不走 SIMD 批算。
    fn unary_batch_info(
        &self,
        op: crate::ast::Ast::UnaryOp,
        operand_expr: crate::ast::Ast::ExprId,
    ) -> Option<BatchInfo> {
        use crate::ast::Ast::UnaryOp;
        use crate::Value::UnaryOp as VUnaryOp;

        let ty = self.expr_type_name(operand_expr)?;
        let tag = Self::ty_name_to_scalar_tag(ty)?;
        let is_float = scalar_meta(tag).map(|m| m.is_float).unwrap_or(false);

        let batch_op = match op {
            UnaryOp::Neg => BatchOp::Unary(VUnaryOp::Neg),
            UnaryOp::BitNot if !is_float => BatchOp::Unary(VUnaryOp::Bnot),
            // Not（bool 逻辑非）→ 不可批量化
            _ => return None,
        };
        Some(BatchInfo { tag, op: batch_op })
    }

    /// 类型名 → ScalarTag 映射（委托 `ScalarTag::from_name`，与 Value 单点同步）。
    fn ty_name_to_scalar_tag(ty: &str) -> Option<crate::Value::ScalarTag> {
        crate::Value::ScalarTag::from_name(ty)
    }

    /// 编译 cast 调用：__cast_to<T>(x) / __cast_try_to<T>(x)。
    ///
    /// 通用路径：
    ///   - 标量 → str：compute_cast_to_str 单节点（idx 277），覆盖所有整数/浮点/bool/char
    ///   - 标量 → 标量：compute_cast_scalar 单节点（idx 278），覆盖所有整数/浮点互转
    /// 特殊路径（FFI）：
    ///   - u8[]/bytes → str：仍走 cast_mangled_name 查 SPECIAL_CAST_PAIRS
    fn compile_cast_call(
        &mut self,
        _name: &str,
        args: &[crate::ast::Ast::ExprId],
        type_args: Option<&[crate::ast::Ast::TypeRef]>,
    ) -> NodeId {
        // 获取目标类型名
        let target_ty = type_args
            .and_then(|ta| ta.first())
            .and_then(|&tid| {
                let spanned = &self.current_module().arena.types[tid.0 as usize];
                if let crate::ast::Ast::TypeNode::Named { name } = &spanned.node {
                    Some(*name)
                } else {
                    None
                }
            })
            .unwrap_or("i64");

        // 获取源类型名（从 Sema expr_types）
        let source_ty = self.expr_type_name(args[0]).unwrap_or("i64").to_string();

        let input = self.compile_subexpr(args[0]);

        // 通用路径 1：任意类型 → str
        if target_ty == "str" {
            let inputs_offset = self.graph.inputs_pool.push(&[input]);
            return self.graph.add_node(Node {
                kind: NodeKind::UnOp,
                input_count: 1,
                inputs_offset,
                compute_fn: CF_CAST_TO_STR, // compute_cast_to_str
            });
        }

        // 通用路径 2：标量 → 标量（int↔int, int↔float, float↔float, bool↔int, char↔int）
        if Self::ty_name_to_scalar_tag(&source_ty).is_some()
            && Self::ty_name_to_scalar_tag(target_ty).is_some()
        {
            let inputs_offset = self.graph.inputs_pool.push(&[input]);
            let node = self.graph.add_node(Node {
                kind: NodeKind::UnOp,
                input_count: 1,
                inputs_offset,
                compute_fn: CF_CAST_SCALAR, // compute_cast_scalar
            });
            self.graph.set_cast_target_type(node, target_ty.to_string());
            return node;
        }

        // 特殊路径：u8[]/bytes → str 等 FFI cast
        let mangled = cast_mangled_name(&source_ty, target_ty);
        let inputs_offset = self.graph.inputs_pool.push(&[input]);
        let call_node = self.graph.add_node(Node {
            kind: NodeKind::Call,
            input_count: 1,
            inputs_offset,
            compute_fn: CF_CALL_LAUNCH, // compute_call_launch
        });
        if let Some(&target_sg) = self.func_subgraphs.get(mangled.as_str()) {
            self.graph.set_call_target(call_node, target_sg);
        }
        call_node
    }

    /// 编译函数调用。
    ///
    /// 若 callee 是已知函数名 → Call 节点 + set_call_target。
    /// 若 callee 是类型名（如 `Iterator(arr, 0)`）→ 编译为记录构造节点。
    fn compile_call(
        &mut self,
        call_expr_id: crate::ast::Ast::ExprId,
        callee: crate::ast::Ast::ExprId,
        args: &[crate::ast::Ast::ExprId],
    ) -> NodeId {
        // ── 内联展开：分析器标记的调用点，直接编译 callee body 而非 launch 子图 ──
        // 纯函数 + 小体 + 非递归 → 绑定实参到形参，编译 body，避免调用开销
        if let Some(callee_func) = self.inline_target(call_expr_id) {
            if let crate::ast::Ast::Decl::FunDecl { params, body, .. } =
                &self.module.declarations[callee_func.0 as usize].node
            {
                return self.compile_inline_expansion(*body, params, args);
            }
        }

        let callee_expr = self.current_module().arena.expr(callee);

        // 内置构造器检测：Ok(val) / Err(record) / channel(capacity)
        // 通过 BUILTIN_CTORS 注册表查表降级，未命中的错误类型走下方 record 构造路径
        if let crate::ast::Ast::Expr::Ident(name) = &callee_expr.node {
            if !self.func_subgraphs.contains_key(*name) {
                if let Some(lower) = BUILTIN_CTORS.iter().find_map(|(n, l)| (*n == *name).then_some(l)) {
                    return match lower {
                        // Ok(val) → compute_throw_ok（idx 44），输入 = val
                        BuiltinCtorLower::Ok => {
                            let mut inputs = Vec::with_capacity(args.len());
                            for &arg in args {
                                inputs.push(self.compile_subexpr(arg));
                            }
                            let inputs_offset = self.graph.inputs_pool.push(&inputs);
                            self.graph.add_node(Node {
                                kind: NodeKind::Call,
                                input_count: inputs.len() as u8,
                                inputs_offset,
                                compute_fn: CF_THROW_OK, // throw_ok
                            })
                        }
                        // Err(...) → 先 record_construct，再 throw_err 包装（idx 45）
                        BuiltinCtorLower::Err => {
                            let inner = self.compile_record_like("Error", args);
                            let inputs_offset = self.graph.inputs_pool.push(&[inner]);
                            self.graph.add_node(Node {
                                kind: NodeKind::Call,
                                input_count: 1,
                                inputs_offset,
                                compute_fn: CF_THROW_ERR, // throw_err
                            })
                        }
                        // channel(capacity) → compute_channel_create（idx 283），输入 = args
                        BuiltinCtorLower::Channel => {
                            let mut inputs = Vec::with_capacity(args.len());
                            for &arg in args {
                                inputs.push(self.compile_subexpr(arg));
                            }
                            let inputs_offset = self.graph.inputs_pool.push(&inputs);
                            self.graph.add_node(Node {
                                kind: NodeKind::BinOp,
                                input_count: inputs.len() as u8,
                                inputs_offset,
                                compute_fn: CF_CHANNEL_CREATE, // compute_channel_create
                            })
                        }
                    };
                }
            }
        }

        // 类型构造器/ADT/Newtype 构造器检测：callee 是 Ident 且不是已知函数
        if let crate::ast::Ast::Expr::Ident(name) = &callee_expr.node {
            if !self.func_subgraphs.contains_key(*name) {
                // 先查类型名（Record 或单构造器 ADT），再查多构造器 ADT 的构造器名
                let tf_info = self.lookup_type_field_names(name)
                    .or_else(|| self.lookup_constructor_field_names(name));
                if let Some(info) = tf_info {
                    // 编译为构造节点（compute_record_construct = 29，根据 kind 分派 HeapObj）
                    let mut inputs = Vec::with_capacity(args.len());
                    for &arg in args {
                        inputs.push(self.compile_subexpr(arg));
                    }
                    let inputs_offset = self.graph.inputs_pool.push(&inputs);
                    let node = self.graph.add_node(Node {
                        kind: NodeKind::BinOp,
                        input_count: inputs.len() as u8,
                        inputs_offset,
                        compute_fn: CF_RECORD_CONSTRUCT, // record_construct
                    });
                    self.graph.set_record_lit_info(node, RecordLitInfo {
                        type_name: info.type_name.clone(),
                        field_names: info.field_names.into_iter().map(Some).collect(),
                        constructor: name.to_string(),
                        kind: info.kind,
                    });
                    return node;
                }
            }
        }

        // 闭包调用检测：callee 是 Ident，非已知函数，但在作用域中绑定（变量持有 Closure/Partial）
        // → 用 compute_closure_call（idx 41），inputs[0] = 可调用值节点，inputs[1..1+arg_count] = 调用参数
        // 末尾追加 current_effect 作为隐式依赖（确保 Call 在前序 effect 完成后才执行）
        // arg_count 元数据记录实参数（不含闭包值和 effect），供链式偏应用判断使用
        if let crate::ast::Ast::Expr::Ident(name) = &callee_expr.node {
            if !self.func_subgraphs.contains_key(*name) {
                if let Some(closure_node) = self.lookup_var(name) {
                    let mut inputs = Vec::with_capacity(args.len() + 2);
                    inputs.push(closure_node);
                    for &arg in args {
                        inputs.push(self.compile_subexpr(arg));
                    }
                    if let Some(eff) = self.current_effect {
                        inputs.push(eff);
                    }
                    let inputs_offset = self.graph.inputs_pool.push(&inputs);
                    let call_node = self.graph.add_node(Node {
                        kind: NodeKind::Call,
                        input_count: inputs.len() as u8,
                        inputs_offset,
                        compute_fn: CF_CLOSURE_CALL, // compute_closure_call
                    });
                    self.graph.set_closure_call_arg_count(call_node, args.len() as u8);
                    return call_node;
                }
            }
        }

        // @extern("C") FFI 调用检测：不启动子帧，直接调用 Ffi::wrapper
        // 末尾追加 current_effect 作为隐式依赖（确保 FFI Call 在前序 effect 完成后才执行）
        //
        // 特殊拦截：__reflect_format / __reflect_scalar_to_str 拆分为独立 compute_fn
        //（CF_REFLECT_FORMAT/CF_REFLECT_SCALAR_TO_STR），不走 FFI 分派，
        // 避免 lazy force 逻辑与 FFI 调用耦合。这两个原语仍以 @extern("C") 声明
        //（builtin 机制），但 compute_fn 直接绑定到 reflect 实现。
        if let crate::ast::Ast::Expr::Ident(name) = &callee_expr.node {
            if self.is_extern_c_func(name) {
                // reflect 原语拦截：绑定到独立 compute_fn，不设置 ffi_call_name
                let (compute_fn, need_ffi_name) = match &**name {
                    "__reflect_format" => (CF_REFLECT_FORMAT, false),
                    "__reflect_scalar_to_str" => (CF_REFLECT_SCALAR_TO_STR, false),
                    _ => (CF_FFI_CALL, true),
                };
                let mut inputs = Vec::with_capacity(args.len() + 1);
                for &arg in args {
                    inputs.push(self.compile_subexpr(arg));
                }
                if let Some(eff) = self.current_effect {
                    inputs.push(eff);
                }
                let inputs_offset = self.graph.inputs_pool.push(&inputs);
                let node = self.graph.add_node(Node {
                    kind: NodeKind::Call,
                    input_count: inputs.len() as u8,
                    inputs_offset,
                    compute_fn,
                });
                if need_ffi_name {
                    self.graph.set_ffi_call_name(node, name.to_string());
                }
                return node;
            }
        }

        // 偏应用检测：callee 是已知函数名，但实参数 < 目标函数形参数
        // → 生成 partial_construct 节点（idx 286），产出 HeapObj::Partial
        // bound_args = 已提供的实参（按原函数参数顺序绑定前导参数）
        if let crate::ast::Ast::Expr::Ident(name) = &callee_expr.node {
            if let Some(&target_sg) = self.func_subgraphs.get(*name) {
                if let Some(sg) = self.graph.subgraphs.get(target_sg.0 as usize) {
                    let param_count = sg.param_count as usize;
                    if args.len() < param_count {
                        let mut bound_inputs = Vec::with_capacity(args.len());
                        for &arg in args {
                            bound_inputs.push(self.compile_subexpr(arg));
                        }
                        let inputs_offset = self.graph.inputs_pool.push(&bound_inputs);
                        let partial_node = self.graph.add_node(Node {
                            kind: NodeKind::BinOp,
                            input_count: bound_inputs.len() as u8,
                            inputs_offset,
                            compute_fn: CF_PARTIAL_CONSTRUCT, // compute_partial_construct
                        });
                        self.graph.set_partial_info(partial_node, PartialInfo {
                            subgraph_id: target_sg,
                            bound_count: args.len() as u8,
                        });
                        return partial_node;
                    }
                }
            }
        }

        // 普通函数调用
        // 末尾追加 current_effect 作为隐式依赖（确保 Call 在前序 effect 完成后才执行）
        let mut inputs = Vec::with_capacity(args.len() + 1);
        for &arg in args {
            inputs.push(self.compile_subexpr(arg));
        }
        if let Some(eff) = self.current_effect {
            inputs.push(eff);
        }
        let inputs_offset = self.graph.inputs_pool.push(&inputs);
        // 默认 sync call compute_fn（idx 36），async 函数用 compute_async_call_launch（idx 39）
        let call_node = self.graph.add_node(Node {
            kind: NodeKind::Call,
            input_count: inputs.len() as u8,
            inputs_offset,
            compute_fn: CF_CALL_LAUNCH, // compute_call_launch（sync）
        });

        // 绑定目标子图（如果 callee 是已知函数名）
        if let crate::ast::Ast::Expr::Ident(name) = &callee_expr.node {
            if let Some(&target_sg) = self.func_subgraphs.get(*name) {
                self.graph.set_call_target(call_node, target_sg);
                // async 函数：切换 compute_fn 为 compute_async_call_launch（idx 39）
                let is_async = if let Some(sg) = self.graph.subgraphs.get(target_sg.0 as usize) {
                    if sg.has_suspend {
                        self.graph.nodes[call_node.0 as usize].compute_fn = CF_ASYNC_CALL_LAUNCH;
                        true
                    } else {
                        false
                    }
                } else {
                    false
                };
                // 尾调用标记：尾位置 + 同步函数 + 有 call_target → 运行时 switch_subgraph 帧复用
                if self.in_tail_position && !is_async {
                    self.graph.set_tail_call(call_node);
                }
            }
        }

        call_node
    }

    /// 内联展开：编译 callee body，形参绑定到实参节点。
    ///
    /// 进入新作用域 → 编译实参 → 绑定形参名 → 编译 body（非尾位置）→ 退出作用域。
    /// 不生成 Call 节点和子图启动，直接把 body 的 IR 嵌入当前函数。
    fn compile_inline_expansion(
        &mut self,
        body: crate::ast::Ast::ExprRef,
        params: &[crate::ast::Ast::Param<'_>],
        args: &[crate::ast::Ast::ExprId],
    ) -> NodeId {
        self.enter_scope();
        // 编译实参并绑定到形参名（实参节点在当前作用域上下文中编译）
        for (param, &arg) in params.iter().zip(args.iter()) {
            let arg_node = self.compile_subexpr(arg);
            self.bind_var(param.name, arg_node);
        }
        // 编译 callee body（非尾位置，内联展开不保留尾调用语义）
        let body_node = self.compile_subexpr(body);
        self.exit_scope();
        body_node
    }

    /// 查找类型声明的字段信息（按类型名）。
    ///
    /// 统一从 type_scope_stack 逐层查找（顶层 + 嵌套类型共享同一查找路径）。
    fn lookup_type_field_names(&self, type_name: &str) -> Option<TypeFieldInfo> {
        self.lookup_type_fields(type_name)
    }

    /// 查找多构造器 ADT 中指定构造器的字段信息。
    ///
    /// 统一从 type_scope_stack 逐层查找（顶层 + 嵌套类型共享同一查找路径）。
    fn lookup_constructor_field_names(&self, constructor_name: &str) -> Option<TypeFieldInfo> {
        self.lookup_type_fields(constructor_name)
    }

    /// 检查函数名是否是 @extern("C") 函数（有 extern_c_body）。
    fn is_extern_c_func(&self, name: &str) -> bool {
        let modules: Vec<&crate::ast::Ast::Module<'_>> =
            std::iter::once(self.module).chain(self.builtin_modules.iter().copied()).collect();
        for m in modules {
            if let Some(d) = m.find_function(name) {
                if let crate::ast::Ast::Decl::FunDecl { extern_c_body, .. } = &d.node {
                    if extern_c_body.is_some() {
                        return true;
                    }
                }
            }
        }
        false
    }

    /// 编译方法调用。
    ///
    /// 方法分派统一走 (type_id, method_idx) 路径：
    /// - intrinsic 方法（await/len/send/recv/close/bytes/cancel 等）通过
    ///   MethodSigInfo.intrinsic 字段标注，直接降级为 compute_fn 节点
    /// - 类型/trait 方法编译为 Call 节点，通过 (type_id, method_idx) 查 method_subgraphs
    fn compile_method_call(
        &mut self,
        recv: crate::ast::Ast::ExprId,
        method: &str,
        args: &[crate::ast::Ast::ExprId],
    ) -> NodeId {
        let recv_node = self.compile_subexpr(recv);

        // ── intrinsic 降级 ──
        // 通过 (type_id, method_idx) 查 MethodSigInfo.intrinsic，命中则尝试降级。
        // 条件不满足（如参数数量不匹配）时 fall through 到 Call 节点路径。
        if let Some(intrinsic) = self.lookup_intrinsic(recv, method) {
            if let Some(node) = self.try_lower_intrinsic(recv, recv_node, args, intrinsic) {
                return node;
            }
        }

        // ── await 降级 ──
        // 用户自定义类型（Timer/Channel 等）未注册 MethodSigInfo.intrinsic，
        // 但 await 是通用挂起语义：无条件构建 Await 节点，
        // 事件源种类由 infer_event_source_kind 根据 recv 类型决定。
        if method == "await" && args.is_empty() {
            return self.build_await_node(recv, recv_node);
        }

        {
            // ConcreteType 驱动方法分派：(type_id, method_idx) 结构化键查 method_subgraphs
            // 末尾追加 current_effect 作为隐式依赖（确保 Call 在前序 effect 完成后才执行）
            let mut inputs = Vec::with_capacity(2 + args.len());
            inputs.push(recv_node);
            for &arg in args {
                inputs.push(self.compile_subexpr(arg));
            }
            if let Some(eff) = self.current_effect {
                inputs.push(eff);
            }
            let inputs_offset = self.graph.inputs_pool.push(&inputs);
            let call_node = self.graph.add_node(Node {
                kind: NodeKind::Call,
                input_count: inputs.len() as u8,
                inputs_offset,
                compute_fn: CF_CALL_LAUNCH,
            });

            // 分派优先级（语义优先级，非 fallback）：
            //   1. trait object 动态分派（recv 类型为 trait → vtable 运行时分派）
            //   2. 类型自有方法 / trait 方法覆写：(type_id, method_idx) 查 method_subgraphs
            //   3. trait 默认方法：(type_id, trait_def_idx, method_idx_in_trait) 查 trait_default_subgraphs

            // 路径 1：trait object 动态分派（vtable）
            if self.is_trait_object_recv(recv) {
                // 查 trait_def.methods 获取 method_idx（与 TraitValue.method_values 索引一致）
                let trait_name = self.expr_type_name(recv).unwrap_or("");
                let method_idx = self.sema.get_trait_def(trait_name)
                    .and_then(|td| td.methods.iter().position(|m| m.name.as_ref() == method))
                    .map(|i| i as u16)
                    .unwrap_or(0);
                self.graph.set_vtable_call(call_node, method_idx);
                return call_node;
            }

            // 路径 2：类型自有方法 / trait 方法覆写
            if let Some(type_name) = self.expr_type_name(recv) {
                if let Some(type_id) = self.expr_type_id(recv) {
                    if let Some(method_idx) = self.sema.lookup_method_idx(type_name, method) {
                        if let Some(&target_sg) = self.method_subgraphs.get(&(type_id, method_idx)) {
                            self.graph.set_call_target(call_node, target_sg);
                            self.mark_async_call_if_needed(call_node, target_sg);
                            return call_node;
                        }
                    }
                }
            }

            // 路径 3：trait 默认方法（类型未覆写，回退到 trait 默认实现的单态化特化版本）
            if let Some(type_id) = self.expr_type_id(recv) {
                for trait_def in &self.sema.trait_defs {
                    if !self.type_implements_trait(type_id, &trait_def.name) {
                        continue;
                    }
                    if let Some(method_idx) = trait_def
                        .methods
                        .iter()
                        .position(|m| m.name.as_ref() == method && m.has_body)
                    {
                        if let Some(&trait_idx) = self.sema.trait_def_index.get(trait_def.name.as_ref()) {
                            if let Some(&target_sg) = self.trait_default_subgraphs.get(&(type_id, trait_idx, method_idx as u16)) {
                                self.graph.set_call_target(call_node, target_sg);
                                self.mark_async_call_if_needed(call_node, target_sg);
                                return call_node;
                            }
                        }
                    }
                }
            }

            // 路径 4：自由函数方法调用（recv.method(args) → method(recv, args)）
            // 当方法名匹配顶层自由函数时，将 recv 作为第一个参数传递
            if let Some(&target_sg) = self.func_subgraphs.get(method) {
                self.graph.set_call_target(call_node, target_sg);
                self.mark_async_call_if_needed(call_node, target_sg);
                return call_node;
            }

            call_node
        }
    }

    /// 通过 (type_id, method_idx) 查 MethodSigInfo.intrinsic，返回降级策略。
    ///
    /// 内置类型的 intrinsic 方法（如 Async.await、Channel.send、Array.len）在 Sema 层
    /// 注册合成 TypeDefInfo 时已标注 intrinsic 字段，此处统一查表获取，不按方法名特判。
    fn lookup_intrinsic(
        &self,
        recv: crate::ast::Ast::ExprId,
        method: &str,
    ) -> Option<crate::sema::Sema::IntrinsicKind> {
        let type_name = self.expr_type_name(recv)?;
        let type_id = self.expr_type_id(recv)?;
        let method_idx = self.sema.lookup_method_idx(type_name, method)?;
        let sig = self.sema.get_method_sig(type_id, method_idx)?;
        sig.intrinsic
    }

    /// 根据 IntrinsicKind 尝试降级为 compute_fn 节点。
    ///
    /// 返回 None 表示条件不满足（如参数数量不匹配、recv 类型不符），
    /// 调用方应 fall through 到 Call 节点路径。
    fn try_lower_intrinsic(
        &mut self,
        recv: crate::ast::Ast::ExprId,
        recv_node: NodeId,
        args: &[crate::ast::Ast::ExprId],
        kind: crate::sema::Sema::IntrinsicKind,
    ) -> Option<NodeId> {
        use crate::sema::Sema::IntrinsicKind;
        match kind {
            // await：无条件降级为 Await（EventSource + Await 双节点）
            IntrinsicKind::Await if args.is_empty() => {
                Some(self.build_await_node(recv, recv_node))
            }
            // recv：仅当 recv 类型为 Channel/Receiver 时降级为 Await
            IntrinsicKind::ChannelAwait if args.is_empty() => {
                if self.infer_event_source_kind(recv) == crate::ir::Ir::EventSourceKind::Channel {
                    Some(self.build_await_node(recv, recv_node))
                } else {
                    None
                }
            }
            // cancel/len/close/bytes：单节点一元运算（无参数）
            IntrinsicKind::UnOp(idx) if args.is_empty() => {
                let inputs_offset = self.graph.inputs_pool.push(&[recv_node]);
                Some(self.graph.add_node(Node {
                    kind: NodeKind::UnOp,
                    input_count: 1,
                    inputs_offset,
                    compute_fn: ComputeFnId(idx),
                }))
            }
            // send(value)：二元运算，inputs = [recv, value]
            IntrinsicKind::BinOp(idx) => {
                let mut inputs = vec![recv_node];
                for &arg in args {
                    inputs.push(self.compile_subexpr(arg));
                }
                let inputs_offset = self.graph.inputs_pool.push(&inputs);
                Some(self.graph.add_node(Node {
                    kind: NodeKind::BinOp,
                    input_count: inputs.len() as u8,
                    inputs_offset,
                    compute_fn: ComputeFnId(idx),
                }))
            }
            _ => None, // 参数不匹配，走 Call 节点路径
        }
    }

    /// 若目标子图含挂起点（async 函数），将 Call 节点的 compute_fn
    /// 从 sync（idx 36）切换为 async（idx 39），使运行时走 async call 路径
    /// （子帧启动 + AsyncHandle 写入 + 当前帧不挂起）。
    fn mark_async_call_if_needed(&mut self, call_node: NodeId, target_sg: SubGraphId) {
        if let Some(sg) = self.graph.subgraphs.get(target_sg.0 as usize) {
            if sg.has_suspend {
                self.graph.nodes[call_node.0 as usize].compute_fn = CF_ASYNC_CALL_LAUNCH;
            }
        }
    }

    /// 检查类型是否实现了指定 trait（通过 witness_table 查询任意方法槽位）。
    fn type_implements_trait(&self, type_id: u16, trait_name: &str) -> bool {
        for entry in self.sema.witness_table.entries().iter() {
            if entry.trait_name.as_ref() == trait_name && entry.type_id == type_id {
                return true;
            }
        }
        false
    }

    /// 判断 recv 是否是 trait object（需运行时动态分派）。
    ///
    /// 查 recv 的类型名，若为 sema.trait_defs 中已注册的 trait 名则需走 vtable 动态分派。
    fn is_trait_object_recv(&self, recv: crate::ast::Ast::ExprId) -> bool {
        let key = crate::sema::Sema::module_expr_key(self.current_module().name, recv.0 as u64);
        if let Some(info) = self.sema.expr_types.get(&key) {
            if let Some(tn) = &info.type_name {
                return self
                    .sema
                    .trait_defs
                    .iter()
                    .any(|td| td.name.as_ref() == tn.as_ref());
            }
        }
        false
    }

    /// 获取表达式的 type_id（从 SemaResult.expr_types 查询）。
    ///
    /// type_id 计算与 populate_witness_table 一致：type_def_index[name] + FIRST_DYNAMIC_TYPE_ID。
    /// 当 Sema 无记录时（trait 默认方法特化版本中的 self），回退到 trait_self_type。
    fn expr_type_id(&self, expr: crate::ast::Ast::ExprId) -> Option<u16> {
        // trait 默认方法特化版本中的 self：用 trait_self_type 覆盖
        // （Sema 将其注册为 "void"，无法查找 type_id）
        if let Some(ref ty) = self.trait_self_type {
            if let crate::ast::Ast::Expr::Ident(name) = &self.module.arena.expr(expr).node {
                if *name == "self" {
                    return self
                        .sema
                        .type_def_index
                        .get(ty.as_str())
                        .map(|&idx| crate::TypeDesc::dynamic_type_id(idx));
                }
            }
        }
        let key = crate::sema::Sema::module_expr_key(self.current_module().name, expr.0 as u64);
        let info = self.sema.expr_types.get(&key)?;
        // 与 expr_type_name 一致：优先 type_name，fallback 到 type_desc.type_name。
        let type_name = info
            .type_name
            .as_deref()
            .unwrap_or(info.type_desc.type_name);
        self.sema
            .type_def_index
            .get(type_name)
            .map(|&idx| crate::TypeDesc::dynamic_type_id(idx))
    }

    /// 构建 Await 节点：EventSource 声明 + Await 节点（spec 4.5，未就绪→帧挂起）。
    ///
    /// await/recv 共用：推断事件源类型 → 注册 EventSourceDecl → 生成 Await 节点。
    fn build_await_node(
        &mut self,
        recv: crate::ast::Ast::ExprId,
        recv_node: NodeId,
    ) -> NodeId {
        let es_inputs_offset = self.graph.inputs_pool.push(&[]);
        let es_node = self.graph.add_node(Node {
            kind: NodeKind::EventSource,
            input_count: 0,
            inputs_offset: es_inputs_offset,
            compute_fn: CF_NOOP, // noop
        });
        let event_kind = self.infer_event_source_kind(recv);
        let current_sg = self.current_function_sg;
        if let Some(sg_id) = current_sg {
            if let Some(sg) = self.graph.subgraphs.get_mut(sg_id.0 as usize) {
                sg.event_source_decls.push(EventSourceDecl {
                    node: es_node,
                    kind: event_kind,
                });
            }
        }
        // 末尾追加 current_effect 作为隐式依赖（与 compile_call 一致）：
        // 确保 await 在前序 effect（如 producer.await()）完成后才执行，
        // 否则 result_ch.recv() 会在 producer.await() 之前就绪并向空 channel 挂起，导致死锁。
        let mut await_inputs = vec![recv_node];
        if let Some(eff) = self.current_effect {
            await_inputs.push(eff);
        }
        let await_inputs_offset = self.graph.inputs_pool.push(&await_inputs);
        let await_node = self.graph.add_node(Node {
            kind: NodeKind::Await,
            input_count: await_inputs.len() as u8,
            inputs_offset: await_inputs_offset,
            compute_fn: CF_AWAIT, // compute_await
        });
        self.graph.set_await_event_source(await_node, es_node);
        await_node
    }

    /// 从 recv 表达式推断事件源种类。
    ///
    /// Async<T> → AsyncJoin, Channel<T>/Receiver<T> → Channel, Timer → Timer
    /// 默认 → AsyncJoin（5a-2 主要支持 await async handle）
    fn infer_event_source_kind(&self, recv: crate::ast::Ast::ExprId) -> EventSourceKind {
        // 查 Sema expr_types 获取 recv 的类型名
        let key = crate::sema::Sema::module_expr_key(self.current_module().name, recv.0 as u64);
        if let Some(info) = self.sema.expr_types.get(&key) {
            if let Some(ref tn) = info.type_name {
                let tn = tn.as_ref();
                if tn.starts_with("Async") {
                    return EventSourceKind::AsyncJoin;
                }
                if tn.starts_with("Channel") || tn.starts_with("Receiver") {
                    return EventSourceKind::Channel;
                }
                if tn.contains("Timer") {
                    return EventSourceKind::Timer;
                }
            }
        }
        EventSourceKind::AsyncJoin
    }

    /// 编译字段访问。
    ///
    /// 绑定 compute_record_field_get，仅存储 field 名称作为运行时按名查找依据。
    fn compile_field_access(
        &mut self,
        _expr_id: crate::ast::Ast::ExprId,
        recv: crate::ast::Ast::ExprId,
        field: &str,
    ) -> NodeId {
        let recv_node = self.compile_subexpr(recv);
        let inputs_offset = self.graph.inputs_pool.push(&[recv_node]);
        let node = self.graph.add_node(Node {
            kind: NodeKind::FieldAccess,
            input_count: 1,
            inputs_offset,
            compute_fn: CF_RECORD_FIELD_GET, // record_field_get
        });
        // 统一存储 field 名称作为运行时唯一查找依据：
        // Record/Adt 均通过 find_field(name) 按名取值，无需编译期 field_idx
        self.graph.set_field_set_name(node, field.to_string());
        node
    }

    /// 编译索引访问。
    fn compile_index(&mut self, recv: crate::ast::Ast::ExprId, index: crate::ast::Ast::ExprId) -> NodeId {
        let recv_node = self.compile_subexpr(recv);
        let index_node = self.compile_subexpr(index);
        let inputs_offset = self.graph.inputs_pool.push(&[recv_node, index_node]);
        self.graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: 2,
            inputs_offset,
            compute_fn: CF_ARRAY_INDEX, // array_index
        })
    }

    /// 编译切片 `recv[start..end]`（inclusive=false）或 `recv[start..=end]`（inclusive=true）。
    ///
    /// 三输入节点（recv, start, end），inclusive 标志存于 graph.slice_inclusive。
    /// 运行时对 str 按码点切片、对 array 按元素切片。
    fn compile_slice(
        &mut self,
        recv: crate::ast::Ast::ExprId,
        start: crate::ast::Ast::ExprId,
        end: crate::ast::Ast::ExprId,
        inclusive: bool,
    ) -> NodeId {
        let recv_node = self.compile_subexpr(recv);
        let start_node = self.compile_subexpr(start);
        let end_node = self.compile_subexpr(end);
        let inputs_offset = self.graph.inputs_pool.push(&[recv_node, start_node, end_node]);
        let node = self.graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: 3,
            inputs_offset,
            compute_fn: CF_SLICE, // compute_slice
        });
        self.graph.set_slice_inclusive(node, inclusive);
        node
    }

    /// 编译记录构造（按位置参数 + 类型名）。
    ///
    /// 用于 `Err(args)` / `IOError(args)` 等构造器调用，字段名自动生成 `_0`, `_1`, ...
    fn compile_record_like(&mut self, type_name: &str, args: &[crate::ast::Ast::ExprId]) -> NodeId {
        let mut inputs = Vec::with_capacity(args.len());
        for &arg in args {
            inputs.push(self.compile_subexpr(arg));
        }
        let field_names: Vec<Option<String>> = (0..args.len())
            .map(|i| Some(format!("_{}", i)))
            .collect();
        let inputs_offset = self.graph.inputs_pool.push(&inputs);
        let node = self.graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: inputs.len() as u8,
            inputs_offset,
            compute_fn: CF_RECORD_CONSTRUCT, // record_construct
        });
        self.graph.set_record_lit_info(
            node,
            RecordLitInfo {
                type_name: type_name.to_string(),
                field_names,
                constructor: type_name.to_string(),
                kind: RecordLitKind::Record,
            },
        );
        node
    }

    /// 编译记录构造表达式。
    /// 分析器标记为不逃逸的分配点使用栈分配 compute_fn（288）。
    fn compile_record_lit(&mut self, expr_id: crate::ast::Ast::ExprId, fields: &[crate::ast::Ast::RecordFieldExpr<'_>]) -> NodeId {
        let mut inputs = Vec::with_capacity(fields.len());
        let mut field_names = Vec::with_capacity(fields.len());
        for field in fields {
            inputs.push(self.compile_subexpr(field.value));
            field_names.push(Some(field.name.to_string()));
        }
        let inputs_offset = self.graph.inputs_pool.push(&inputs);
        // 栈分配标记：不逃逸的分配用 compute_record_construct_stack（288）
        let compute_fn = if self.should_stack_alloc(expr_id) {
            CF_RECORD_CONSTRUCT_STACK // record_construct_stack
        } else {
            CF_RECORD_CONSTRUCT // record_construct
        };
        let node = self.graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: inputs.len() as u8,
            inputs_offset,
            compute_fn,
        });
        self.graph.set_record_lit_info(
            node,
            RecordLitInfo {
                type_name: "Record".to_string(),
                field_names,
                constructor: "Record".to_string(),
                kind: RecordLitKind::Record,
            },
        );
        node
    }

    /// 编译记录扩展表达式 `(...base, field: value, ...)`。
    ///
    /// inputs[0] = base record，inputs[1..] = 更新字段值。
    /// RecordExtendInfo 存储更新字段名列表（顺序对应 inputs[1..]）。
    /// 运行时从 base 克隆字段，按更新字段名替换/追加，构造新 RecordValue。
    fn compile_record_extend(
        &mut self,
        base: crate::ast::Ast::ExprId,
        updates: &[crate::ast::Ast::RecordFieldExpr<'_>],
    ) -> NodeId {
        let mut inputs = Vec::with_capacity(1 + updates.len());
        let mut update_names = Vec::with_capacity(updates.len());
        inputs.push(self.compile_subexpr(base));
        for field in updates {
            inputs.push(self.compile_subexpr(field.value));
            update_names.push(field.name.to_string());
        }
        let inputs_offset = self.graph.inputs_pool.push(&inputs);
        let node = self.graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: inputs.len() as u8,
            inputs_offset,
            compute_fn: CF_RECORD_EXTEND, // record_extend
        });
        self.graph.set_record_extend_info(node, RecordExtendInfo { update_names });
        node
    }

    /// 编译原子构造表达式 `atomic expr`。
    ///
    /// 单输入节点，运行时将值包装为 AtomicValue（共享底层内存的原子容器）。
    fn compile_atomic(&mut self, operand: crate::ast::Ast::ExprId) -> NodeId {
        let operand_node = self.compile_subexpr(operand);
        let inputs_offset = self.graph.inputs_pool.push(&[operand_node]);
        self.graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: 1,
            inputs_offset,
            compute_fn: CF_ATOMIC_CONSTRUCT, // atomic_construct
        })
    }

    /// 编译数组构造表达式。
    /// 分析器标记为不逃逸的分配点使用栈分配 compute_fn（289）。
    fn compile_array_lit(&mut self, expr_id: crate::ast::Ast::ExprId, elements: &[crate::ast::Ast::ExprRef]) -> NodeId {
        let mut inputs = Vec::with_capacity(elements.len());
        for &elem in elements {
            inputs.push(self.compile_subexpr(elem));
        }
        let inputs_offset = self.graph.inputs_pool.push(&inputs);
        // 栈分配标记：不逃逸的分配用 compute_array_construct_stack（289）
        let compute_fn = if self.should_stack_alloc(expr_id) {
            CF_ARRAY_CONSTRUCT_STACK // array_construct_stack
        } else {
            CF_ARRAY_CONSTRUCT // array_construct
        };
        self.graph.add_node(Node {
            kind: NodeKind::BinOp,
            input_count: inputs.len() as u8,
            inputs_offset,
            compute_fn,
        })
    }

    /// 编译 Block 表达式。
    ///
    /// 依次编译 stmts，trailing 表达式的 NodeId 作为 Block 产出。
    fn compile_block(
        &mut self,
        stmts: &[crate::ast::Ast::StmtId],
        trailing: &Option<crate::ast::Ast::ExprId>,
    ) -> NodeId {
        self.enter_scope();
        let prev_effect = self.current_effect;
        // 初始化 last_effect 为 prev_effect，使 block 的首条语句依赖前序 effect
        // （如 entry 函数中全局变量初始化的 store 节点），保证 block 内的 load/call
        // 在前序副作用完成后才执行。
        let mut last_effect: Option<NodeId> = prev_effect;
        self.current_effect = None;
        for &stmt_id in stmts {
            // 设置 current_effect 让后续效果节点（如 WriteBack）依赖前一个效果
            self.current_effect = last_effect;
            // 语句不在尾位置（Return 内部会为其 value 恢复 in_tail_position = true）
            let prev_tail = self.in_tail_position;
            self.in_tail_position = false;
            let effect = self.compile_stmt(stmt_id);
            self.in_tail_position = prev_tail;
            if let Some(eff) = effect {
                // 控制信号（Return/Break/Continue/Throw）必须延迟到前序副作用完成后才触发：
                // 将信号从 eff 移到 chain_effects 创建的 seq 节点上，
                // 确保 seq（依赖 last_effect）执行后才触发信号，避免跳过副作用节点。
                let signal = self.graph.control_signal_nodes[eff.0 as usize];
                if signal.is_some() && last_effect.is_some() {
                    self.graph.control_signal_nodes[eff.0 as usize] = None;
                }
                let chained = self.chain_effects(last_effect, eff);
                if let Some(kind) = signal {
                    if last_effect.is_some() {
                        self.graph.set_control_signal(chained, kind);
                    }
                }
                last_effect = Some(chained);
            }
        }
        // trailing 表达式编译时继承 block 内 effect 链，
        // 确保 trailing 中的 Call 节点依赖前序 effect（与 stmts 中的行为一致）
        self.current_effect = last_effect;
        let result = match trailing {
            Some(expr_id) => {
                let result_node = self.compile_expr(*expr_id);
                self.chain_effects(last_effect, result_node)
            }
            None => last_effect.unwrap_or_else(|| self.compile_void_const()),
        };
        self.current_effect = prev_effect;
        self.exit_scope();
        result
    }

    /// 编译语句，返回效果节点（需顺序链接到块结果的节点）。
    /// 返回 None 表示纯声明（变量绑定），其值节点通过变量引用自动可达。
    fn compile_stmt(&mut self, stmt_id: crate::ast::Ast::StmtId) -> Option<NodeId> {
        // 分析器标记的死语句（不可达代码/死声明/死存储）跳过，不生成 IR 节点
        if self.is_dead_stmt(stmt_id) {
            return None;
        }
        let spanned = self.current_module().arena.stmt(stmt_id);
        let stmt = &spanned.node;
        match stmt {
            crate::ast::Ast::Stmt::ValDecl { name, value, .. } => {
                let value_node = self.compile_subexpr(*value);
                // 为 val 声明创建独立 copy 节点（CF_SEQ 单输入 = identity），
                // 使 val 绑定拥有独立节点 ID，而非别名源节点。
                // 这确保闭包捕获 val 变量时捕获的是声明时的快照值，
                // 而非源变量（可能是 var）的当前值。
                // 例如：while 循环中 `val captured = i` 后 `fun() { captured }`，
                // 若不创建 copy 节点，captured 别名 i 的节点，循环结束后所有
                // 闭包都读到 i 的最终值；创建 copy 节点后，captured 拥有独立
                // 节点（在循环体子图范围内），main 帧中该节点未就绪，
                // same_function 路径回退到闭包的 Cell upvalue，返回正确快照值。
                let copy_off = self.graph.inputs_pool.push(&[value_node]);
                let copy_node = self.graph.add_node(Node {
                    kind: NodeKind::BinOp,
                    input_count: 1,
                    inputs_offset: copy_off,
                    compute_fn: CF_SEQ,
                });
                self.bind_var(name, copy_node);
                Some(copy_node)
            }
            crate::ast::Ast::Stmt::VarDecl { name, value, .. } => {
                let value_node = self.compile_subexpr(*value);
                self.bind_var(name, value_node);
                Some(value_node)
            }
            crate::ast::Ast::Stmt::Expression { expr } => {
                let expr_node = self.compile_subexpr(*expr);
                Some(expr_node)
            }
            crate::ast::Ast::Stmt::Assignment { target, value } => {
                let raw_val = self.compile_subexpr(*value);
                // 链接 current_effect：确保赋值表达式在前序效果（如 if-Gate with continue）
                // 完成后才执行。防止 continue 后的语句提前执行。
                let val_node = self.chain_effects(self.current_effect, raw_val);
                let target_expr = &self.current_module().arena.expr(*target).node;
                if let crate::ast::Ast::Expr::Ident(name) = target_expr {
                    // 检查是否为 lambda 捕获变量：captured_scopes 记录每层 lambda
                    // 捕获的变量名与对应外层节点。捕获变量赋值需 WriteBack 到外层节点，
                    // 使变更对外层可见（引用捕获语义）。
                    let captured_source = self.captured_scopes.iter().rev()
                        .find_map(|scope| scope.iter()
                            .find(|(n, _)| n.as_str() == *name)
                            .map(|(_, node)| *node));
                    if let Some(source) = captured_source {
                        // 捕获变量 → WriteBack 到外层节点
                        let wb_node = self.compile_writeback_node(val_node, source);
                        self.bind_var(name, val_node);
                        return Some(wb_node);
                    } else if let Some(outer_node) = self.lookup_var(name) {
                        if !self.is_in_current_subgraph(outer_node) {
                            // 外层变量 → WriteBack，返回效果节点确保被调度执行
                            let wb_node = self.compile_writeback_node(val_node, outer_node);
                            // 绑定本地引用：后续同子图内读取使用新值（val_node），
                            // 避免 cond_node 在 WriteBack 完成前读取根帧旧值。
                            // WriteBack 负责跨迭代可见性（写回根帧）。
                            self.bind_var(name, val_node);
                            return Some(wb_node);
                        } else if let Some(&captured_node) = self.captured_vars.get(*name) {
                            // 被内层 lambda 捕获的本地变量 → WriteBack 到捕获时的原始节点，
                            // 使 same_function 闭包调用能从父帧读到最新值（引用捕获语义）。
                            let wb_node = self.compile_writeback_node(val_node, captured_node);
                            self.bind_var(name, val_node);
                            return Some(wb_node);
                        } else {
                            self.bind_var(name, val_node);
                        }
                    } else if let Some(slot) = self.lookup_global_var(name) {
                        // 全局变量 → global_store，返回效果节点确保被调度执行
                        let store_node = self.compile_global_store(val_node, slot);
                        return Some(store_node);
                    } else {
                        self.bind_var(name, val_node);
                    }
                }
                None
            }
            crate::ast::Ast::Stmt::FieldAssignment { object, field, value } => {
                let obj_node = self.compile_subexpr(*object);
                let val_node = self.compile_subexpr(*value);
                let inputs_offset = self.graph.inputs_pool.push(&[obj_node, val_node]);
                let set_node = self.graph.add_node(Node {
                    kind: NodeKind::BinOp,
                    input_count: 2,
                    inputs_offset,
                    compute_fn: CF_RECORD_FIELD_SET, // record_field_set
                });
                self.graph.set_field_set_name(set_node, field.to_string());
                Some(set_node)
            }
            crate::ast::Ast::Stmt::CompoundAssignment { target, op, value } => {
                let val_node = self.compile_subexpr(*value);
                let target_expr = &self.current_module().arena.expr(*target).node;
                let bin_compute = self.compound_assign_op_to_compute_fn(*op, *target);
                if let crate::ast::Ast::Expr::Ident(name) = target_expr {
                    // 检查是否为 lambda 捕获变量
                    let captured_source = self.captured_scopes.iter().rev()
                        .find_map(|scope| scope.iter()
                            .find(|(n, _)| n.as_str() == *name)
                            .map(|(_, node)| *node));
                    // 读取当前值：局部变量 > 全局变量 > 占位
                    let cur_node = if let Some(n) = self.lookup_var(name) {
                        n
                    } else if let Some(slot) = self.lookup_global_var(name) {
                        self.compile_global_load(slot)
                    } else {
                        self.compile_placeholder()
                    };
                    let off = self.graph.inputs_pool.push(&[cur_node, val_node]);
                    let raw_result = self.graph.add_node(Node {
                        kind: NodeKind::BinOp,
                        input_count: 2,
                        inputs_offset: off,
                        compute_fn: bin_compute,
                    });
                    // 链接 current_effect：防止 continue 后的复合赋值提前执行
                    let result_node = self.chain_effects(self.current_effect, raw_result);
                    if captured_source.is_some() {
                        // 捕获变量 → WriteBack 到外层节点 + 绑定本地引用
                        self.compile_writeback_node(result_node, captured_source.unwrap());
                        self.bind_var(name, result_node);
                    } else if self.lookup_global_var(name).is_some() && self.lookup_var(name).is_none() {
                        // 全局变量 → global_store
                        let slot = self.lookup_global_var(name).unwrap();
                        let store_node = self.compile_global_store(result_node, slot);
                        self.current_effect = Some(store_node);
                    } else if !self.is_in_current_subgraph(cur_node) {
                        // 外层变量 → WriteBack + 绑定本地引用
                        self.compile_writeback_node(result_node, cur_node);
                        self.bind_var(name, result_node);
                    } else if let Some(&captured_node) = self.captured_vars.get(*name) {
                        // 被内层 lambda 捕获的本地变量 → WriteBack 到原始节点
                        self.compile_writeback_node(result_node, captured_node);
                        self.bind_var(name, result_node);
                    } else {
                        self.bind_var(name, result_node);
                    }
                }
                None
            }
            crate::ast::Ast::Stmt::Return { value } => {
                let return_node = match value {
                    Some(expr_id) => {
                        let prev_tail = self.in_tail_position;
                        self.in_tail_position = true;
                        let r = self.compile_expr(*expr_id);
                        self.in_tail_position = prev_tail;
                        r
                    }
                    None => self.compile_void_const(),
                };
                self.graph.set_control_signal(return_node, SignalKind::Return);
                Some(return_node)
            }
            crate::ast::Ast::Stmt::Throw { expr } => {
                let expr_node = self.compile_subexpr(*expr);
                // 包装为 ThrowVal(Err)
                let wrap_off = self.graph.inputs_pool.push(&[expr_node]);
                let wrap_node = self.graph.add_node(Node {
                    kind: NodeKind::UnOp,
                    input_count: 1,
                    inputs_offset: wrap_off,
                    compute_fn: CF_THROW_WRAP_ERR, // throw_wrap_err
                });
                // throw = 提前返回 ThrowVal
                self.graph.set_control_signal(wrap_node, SignalKind::Return);
                Some(wrap_node)
            }
            crate::ast::Ast::Stmt::Break => {
                let n = self.compile_void_const();
                self.graph.set_control_signal(n, SignalKind::Break);
                Some(n)
            }
            crate::ast::Ast::Stmt::Continue => {
                // continue = ControlSignal(Continue)，跳过 body 剩余
                // Engine 侧 complete_and_wake_caller 检测 Continue → reset_loop_iteration 下一轮
                // （Sema 保证 continue 必在循环内）
                let n = self.compile_void_const();
                self.graph.set_control_signal(n, SignalKind::Continue);
                Some(n)
            }
            crate::ast::Ast::Stmt::While { condition, body } => {
                let while_sg = self.register_while_subgraph(*condition, *body);
                let call_node = self.compile_recursive_call(while_sg);
                Some(call_node)
            }
            crate::ast::Ast::Stmt::Loop { body } => {
                let loop_sg = self.register_loop_subgraph(*body);
                let call_node = self.compile_recursive_call(loop_sg);
                Some(call_node)
            }
            crate::ast::Ast::Stmt::For {
                name,
                iterable,
                body,
            } => {
                // For 循环 = iterable（已是迭代器）→ 递归子图 (next() + is_null + body)
                let iterable_node = self.compile_subexpr(*iterable);
                // 从 Sema 获取 iterable 类型信息（类型名 + 是否为 trait 对象）
                let (iter_type_name, is_trait_object) = self.lookup_expr_iter_info(*iterable);
                // 注册 For 循环子图（静态分派：按类型名绑定 next()；trait 对象走 vtable）
                let for_sg = self.register_for_subgraph(
                    name,
                    *body,
                    iter_type_name.as_deref(),
                    is_trait_object,
                );
                // 启动循环：Call(for_sg, [iterable_node])
                let call_node = self.make_call(for_sg, &[iterable_node]);
                Some(call_node)
            }
            crate::ast::Ast::Stmt::Defer { expr } => {
                // defer expr → 编译 expr 为独立子图，注册到当前函数子图的 defer_table
                let (body_sg, captured_inputs) = self.compile_branch_subgraph(*expr);
                let trigger = self.compile_void_const();
                if let Some(cur_sg) = self.current_function_sg {
                    let entry = DeferEntry {
                        trigger_node: trigger,
                        body_subgraph: body_sg,
                        captured_inputs,
                        registered: false,
                    };
                    self.graph.subgraphs[cur_sg.0 as usize]
                        .defer_table
                        .push(entry);
                }
                None
            }
            crate::ast::Ast::Stmt::LocalDecl { decl } => {
                match decl.as_ref() {
                    crate::ast::Ast::Decl::FunDecl {
                        name, params, body, is_async, extern_c_body, ..
                    } => {
                        if extern_c_body.is_some() {
                            return None;
                        }
                        let construct_node =
                            self.compile_lambda(params, *body, *is_async, Some(name));
                        self.bind_var(name, construct_node);
                        Some(construct_node)
                    }
                    crate::ast::Ast::Decl::TypeDecl { name, def, .. } => {
                        // 注册嵌套类型字段到当前作用域（与顶层类型统一通过 type_scope_stack 查找）
                        match def {
                            crate::ast::Ast::TypeDef::Record { fields } => {
                                let field_names: Vec<String> = fields.iter().map(|f| f.name.to_string()).collect();
                                self.bind_type_fields(name, TypeFieldInfo {
                                    field_names,
                                    type_name: name.to_string(),
                                    kind: RecordLitKind::Record,
                                });
                            }
                            crate::ast::Ast::TypeDef::Adt { constructors } => {
                                // 注册类型名 + 各构造器名（映射到类型名）
                                self.bind_type_fields(name, TypeFieldInfo {
                                    field_names: Vec::new(),
                                    type_name: name.to_string(),
                                    kind: RecordLitKind::Adt,
                                });
                                for ctor in constructors {
                                    let field_names: Vec<String> = ctor.fields.iter()
                                        .map(|f| f.name.unwrap_or("_").to_string())
                                        .collect();
                                    self.bind_type_fields(ctor.name, TypeFieldInfo {
                                        field_names,
                                        type_name: name.to_string(),
                                        kind: RecordLitKind::Adt,
                                    });
                                }
                            }
                            crate::ast::Ast::TypeDef::Newtype { name: nt_name, .. } => {
                                self.bind_type_fields(nt_name, TypeFieldInfo {
                                    field_names: Vec::new(),
                                    type_name: nt_name.to_string(),
                                    kind: RecordLitKind::Newtype,
                                });
                            }
                            crate::ast::Ast::TypeDef::Alias { .. } => {}
                        }
                        None
                    }
                    // trait 声明：Sema 层注册类型，IR 层无需生成代码
                    crate::ast::Ast::Decl::TraitDecl { .. } => None,
                    _ => None,
                }
            }
        }
    }

    /// 在用户模块和 builtin 模块中查找函数位置。
    /// 返回 None = 用户模块，Some(i) = builtin_modules[i]。
    fn find_function_location(&self, name: &str) -> Option<Option<usize>> {
        if self.module.find_function(name).is_some() {
            return Some(None);
        }
        for (i, builtin_mod) in self.builtin_modules.iter().enumerate() {
            if builtin_mod.find_function(name).is_some() {
                return Some(Some(i));
            }
        }
        None
    }

    /// 编译函数为子图（支持跨模块：用户模块 + builtin 模块）。
    ///
    /// 若函数不存在或声明类型不匹配，记录编译错误并返回占位子图（错误恢复）。
    pub fn compile_function(&mut self, name: &str) -> SubGraphId {
        let location = match self.find_function_location(name) {
            Some(loc) => loc,
            None => {
                self.errors.push(format!("function {} not found", name));
                return self.register_subgraph_placeholder(name, 0, false);
            }
        };

        let module = match location {
            None => self.module,
            Some(i) => self.builtin_modules[i],
        };

        // 设置当前编译模块（compile_expr 通过 current_module() 访问 AST arena）
        let prev_builtin = self.compiling_builtin;
        self.compiling_builtin = match location {
            None => None,
            Some(i) => Some(self.builtin_modules[i]),
        };

        let (body_expr, is_async, params, is_entry, return_type) = match module.find_function(name) {
            Some(d) => match &d.node {
                crate::ast::Ast::Decl::FunDecl {
                    body,
                    is_async,
                    params,
                    is_entry,
                    return_type,
                    ..
                } => (*body, *is_async, params.clone(), *is_entry, *return_type),
                _ => {
                    self.errors.push(format!("{} is not a function", name));
                    self.compiling_builtin = prev_builtin;
                    return self.register_subgraph_placeholder(name, 0, false);
                }
            },
            None => {
                self.errors.push(format!("function {} not found", name));
                self.compiling_builtin = prev_builtin;
                return self.register_subgraph_placeholder(name, 0, false);
            }
        };
        let param_count = params.len();

        // 复用预注册的 sg_id（build() 预注册 pass 已创建），避免重复子图
        let sg_id = if let Some(&existing) = self.func_subgraphs.get(name) {
            existing
        } else {
            let new_id = self.register_subgraph_placeholder(name, param_count as u8, is_async);
            self.func_subgraphs.insert(name.to_string(), new_id);
            new_id
        };
        let node_start = self.graph.nodes.len() as u32;

        self.current_function_sg = Some(sg_id);
        self.current_function_id = sg_id.0;
        self.enter_scope();

        // 创建参数节点（Const 占位，值在运行时由 start_subgraph 注入）
        // 这些节点必须是子图的前 param_count 个节点
        for param in &params {
            let inputs_offset = self.graph.inputs_pool.push(&[]);
            let param_node = self.graph.add_node(Node {
                kind: NodeKind::Const,
                input_count: 0,
                inputs_offset,
                compute_fn: CF_NOOP,
            });
            self.bind_var(param.name, param_node);
        }

        // entry 函数：在函数体之前编译所有模块的顶层 var/val 声明初始化
        // 全局变量通过 global_store 写入共享存储区，所有函数通过 global_load 读取
        // 按模块切换 compiling_builtin，使 compile_subexpr 访问正确的 AST arena
        if is_entry && !self.top_level_var_decls.is_empty() {
            let decls: Vec<(Option<usize>, crate::ast::Ast::StmtId)> = std::mem::take(&mut self.top_level_var_decls);
            for (mod_idx, stmt_id) in &decls {
                let prev_builtin = self.compiling_builtin;
                self.compiling_builtin = match mod_idx {
                    None => None,
                    Some(i) => Some(self.builtin_modules[*i]),
                };
                let module = self.current_module();
                let stmt = &module.arena.stmt(*stmt_id).node;
                let (name, value_expr) = match stmt {
                    crate::ast::Ast::Stmt::VarDecl { name, value, .. } => (*name, *value),
                    crate::ast::Ast::Stmt::ValDecl { name, value, .. } => (*name, *value),
                    _ => { self.compiling_builtin = prev_builtin; continue; }
                };
                let init_node = self.compile_subexpr(value_expr);
                let slot = self.global_var_slots.get(name).copied()
                    .expect("global var slot must exist after collection");
                let store_node = self.compile_global_store(init_node, slot);
                self.current_effect = Some(store_node);
                self.compiling_builtin = prev_builtin;
            }
            self.top_level_var_decls = decls;
        }

        // tail call 优化仅对非 void 函数启用：void 函数的 trailing 表达式是副作用
        // （如 println("done")），不应 tail call（switch_subgraph 会丢失当前帧状态）。
        let is_void_fn = match return_type {
            None => true,
            Some(tr) => {
                matches!(module.arena.ty(tr).node, crate::ast::Ast::TypeNode::Named { name } if name == "void")
            }
        };
        let return_node = {
            let prev_tail = self.in_tail_position;
            self.in_tail_position = !is_void_fn;
            let r = self.compile_expr(body_expr);
            self.in_tail_position = prev_tail;
            r
        };
        self.exit_scope();
        self.current_function_sg = None;
        self.compiling_builtin = prev_builtin;

        let node_end = self.graph.nodes.len() as u32;
        let sg = &mut self.graph.subgraphs[sg_id.0 as usize];
        sg.node_range = (NodeId(node_start), NodeId(node_end));
        sg.entry_node = NodeId(node_start);
        sg.return_node = return_node;
        sg.has_suspend = is_async;
        sg.function_id = sg_id.0;

        self.func_subgraphs.insert(name.to_string(), sg_id);
        sg_id
    }

    /// 编译 builtin 模块中 TypeDecl 的方法（通过 (type_id, method_idx) 查 method_subgraphs）。
    fn compile_builtin_method(&mut self, type_name: &str, method_idx: usize) {
        // 在 builtin 模块中查找方法数据（直接按 method_idx 索引）
        let found = self.builtin_modules.iter().enumerate().find_map(|(mod_i, m)| {
            for d in &m.declarations {
                if let crate::ast::Ast::Decl::TypeDecl { name, methods, .. } = &d.node {
                    if *name == type_name {
                        if let Some(method) = methods.get(method_idx) {
                            if method.body.is_some() {
                                return Some((
                                    mod_i,
                                    method.body.unwrap(),
                                    method.is_async,
                                    method.params.clone(),
                                ));
                            }
                        }
                    }
                }
            }
            None
        });

        let (mod_i, body_expr, is_async, params) = match found {
            Some(x) => x,
            None => return,
        };

        let m = self.builtin_modules[mod_i];

        // 从 method_subgraphs 获取预注册的 sg_id（build() 步骤 0a 已创建）
        let type_id = match self.sema.type_def_index.get(type_name) {
            Some(&idx) => crate::TypeDesc::dynamic_type_id(idx),
            None => return,
        };
        let sg_id = match self.method_subgraphs.get(&(type_id, method_idx as u16)) {
            Some(&sg) => sg,
            None => return,
        };

        let prev = self.compiling_builtin;
        self.compiling_builtin = Some(m);
        let node_start = self.graph.nodes.len() as u32;

        self.current_function_sg = Some(sg_id);
        self.current_function_id = sg_id.0;
        self.enter_scope();

        for param in &params {
            let inputs_offset = self.graph.inputs_pool.push(&[]);
            let param_node = self.graph.add_node(Node {
                kind: NodeKind::Const,
                input_count: 0,
                inputs_offset,
                compute_fn: CF_NOOP,
            });
            self.bind_var(param.name, param_node);
        }

        let return_node = self.compile_expr(body_expr);
        self.exit_scope();
        self.current_function_sg = None;
        self.compiling_builtin = prev;

        let node_end = self.graph.nodes.len() as u32;
        let sg = &mut self.graph.subgraphs[sg_id.0 as usize];
        sg.node_range = (NodeId(node_start), NodeId(node_end));
        sg.entry_node = NodeId(node_start);
        sg.return_node = return_node;
        sg.has_suspend = is_async;
        sg.function_id = sg_id.0;
    }

    /// 编译用户模块中 TypeDecl 的方法（通过 (type_id, method_idx) 查 method_subgraphs）。
    fn compile_user_method(&mut self, type_name: &str, method_idx: usize) {
        // 在用户模块中查找方法数据（直接按 method_idx 索引）
        let found = self.module.declarations.iter().find_map(|d| {
            if let crate::ast::Ast::Decl::TypeDecl { name, methods, .. } = &d.node {
                if *name == type_name {
                    if let Some(method) = methods.get(method_idx) {
                        if method.body.is_some() {
                            return Some((
                                method.body.unwrap(),
                                method.is_async,
                                method.params.clone(),
                            ));
                        }
                    }
                }
            }
            None
        });

        let (body_expr, is_async, params) = match found {
            Some(x) => x,
            None => return,
        };

        // 从 method_subgraphs 获取预注册的 sg_id（build() 步骤 0a 已创建）
        let type_id = match self.sema.type_def_index.get(type_name) {
            Some(&idx) => crate::TypeDesc::dynamic_type_id(idx),
            None => return,
        };
        let sg_id = match self.method_subgraphs.get(&(type_id, method_idx as u16)) {
            Some(&sg) => sg,
            None => return,
        };

        let node_start = self.graph.nodes.len() as u32;

        self.current_function_sg = Some(sg_id);
        self.current_function_id = sg_id.0;
        self.enter_scope();

        for param in &params {
            let inputs_offset = self.graph.inputs_pool.push(&[]);
            let param_node = self.graph.add_node(Node {
                kind: NodeKind::Const,
                input_count: 0,
                inputs_offset,
                compute_fn: CF_NOOP,
            });
            self.bind_var(param.name, param_node);
        }

        let return_node = self.compile_expr(body_expr);
        self.exit_scope();
        self.current_function_sg = None;

        let node_end = self.graph.nodes.len() as u32;
        let sg = &mut self.graph.subgraphs[sg_id.0 as usize];
        sg.node_range = (NodeId(node_start), NodeId(node_end));
        sg.entry_node = NodeId(node_start);
        sg.return_node = return_node;
        sg.has_suspend = is_async;
        sg.function_id = sg_id.0;
    }

    /// 编译 trait 默认方法的单态化特化版本（为指定实现类型生成专用子图）。
    ///
    /// trait 默认方法在类型未覆盖时作为分派目标。为每个实现 trait 的类型生成
    /// 特化子图，使 body 中的 self 拥有具体类型信息，从而 self.method() 调用
    /// 能通过路径 2（类型自有方法）静态绑定到正确的方法子图。
    fn compile_trait_default_method(&mut self, trait_name: &str, method_idx: usize, impl_type_name: &str) {
        // 在用户模块中查找 TraitDecl 的有 body 方法（直接按 method_idx 索引）
        let found = self.module.declarations.iter().find_map(|d| {
            if let crate::ast::Ast::Decl::TraitDecl { name, methods, .. } = &d.node {
                if *name == trait_name {
                    if let Some(method) = methods.get(method_idx) {
                        if method.body.is_some() {
                            return Some((
                                method.body.unwrap(),
                                method.is_async,
                                method.params.clone(),
                            ));
                        }
                    }
                }
            }
            None
        });

        let (body_expr, is_async, params) = match found {
            Some(x) => x,
            None => return,
        };

        // 从 trait_default_subgraphs 获取预注册的特化子图 sg_id
        let trait_idx = match self.sema.trait_def_index.get(trait_name) {
            Some(&idx) => idx,
            None => return,
        };
        let type_id = match self.sema.type_def_index.get(impl_type_name) {
            Some(&idx) => crate::TypeDesc::dynamic_type_id(idx),
            None => return,
        };
        let sg_id = match self.trait_default_subgraphs.get(&(type_id, trait_idx, method_idx as u16)) {
            Some(&sg) => sg,
            None => return,
        };

        let node_start = self.graph.nodes.len() as u32;

        self.current_function_sg = Some(sg_id);
        self.current_function_id = sg_id.0;
        // 设置 self 的具体类型名，使 body 中 self.method() 能静态绑定。
        self.trait_self_type = Some(impl_type_name.to_string());
        self.enter_scope();

        for param in &params {
            let inputs_offset = self.graph.inputs_pool.push(&[]);
            let param_node = self.graph.add_node(Node {
                kind: NodeKind::Const,
                input_count: 0,
                inputs_offset,
                compute_fn: CF_NOOP,
            });
            self.bind_var(param.name, param_node);
        }

        let return_node = self.compile_expr(body_expr);
        self.exit_scope();
        self.current_function_sg = None;
        self.trait_self_type = None;

        let node_end = self.graph.nodes.len() as u32;
        let sg = &mut self.graph.subgraphs[sg_id.0 as usize];
        sg.node_range = (NodeId(node_start), NodeId(node_end));
        sg.entry_node = NodeId(node_start);
        sg.return_node = return_node;
        sg.has_suspend = is_async;
        sg.function_id = sg_id.0;
    }
    pub fn build(mut self) -> DataFlowGraph {
        // 0. 预注册所有函数（builtin + std + dep + 用户）到 func_subgraphs，解决前向引用问题：
        //    函数 A 调用函数 B 时，B 可能尚未编译（未注册到 func_subgraphs），
        //    导致 call_target 未绑定、compute_call_launch 静默返回 VOID。
        //    预注册后，所有函数名均可解析到 SubGraphId，body 在后续 pass 填充。
        //    同时注册 mangled 名（模块路径.函数名），供 selective import alias 解析。
        let all_modules: Vec<&crate::ast::Ast::Module<'_>> = self
            .builtin_modules
            .iter()
            .copied()
            .chain(std::iter::once(self.module))
            .collect();
        for m in &all_modules {
            let module_path = crate::sema::Sema::module_logical_path(m.name);
            for d in &m.declarations {
                if let crate::ast::Ast::Decl::FunDecl { name, params, is_async, .. } = &d.node {
                    // 跳过 @extern("C") 函数：它们仅通过 FFI 调用，不需要子图
                    if let crate::ast::Ast::Decl::FunDecl { extern_c_body, .. } = &d.node {
                        if extern_c_body.is_some() {
                            continue;
                        }
                    }
                    let sg_id = self.register_subgraph_placeholder(name, params.len() as u8, *is_async);
                    self.func_subgraphs.insert(name.to_string(), sg_id);
                    // 同时注册 mangled 名（模块路径.函数名），供 selective import alias 解析
                    if let Some(ref mp) = module_path {
                        let mangled = format!("{}.{}", mp, name);
                        self.func_subgraphs.insert(mangled, sg_id);
                    }
                }
            }
        }

        // 0a. 预注册类型方法子图到 method_subgraphs：(type_id, method_idx) → SubGraphId
        //     同时注册 mangled name 到 func_subgraphs，供 selective import alias 解析
        //     type_id = dynamic_type_id(type_def_index)，method_idx = 方法在 TypeDefInfo.methods 中的位置
        for m in &all_modules {
            for d in &m.declarations {
                if let crate::ast::Ast::Decl::TypeDecl { name, methods, .. } = &d.node {
                    let type_id = self.sema.type_def_index.get(*name).map(|&idx| crate::TypeDesc::dynamic_type_id(idx));
                    if let Some(tid) = type_id {
                        for (method_idx, method) in methods.iter().enumerate() {
                            if method.body.is_some() {
                                let mangled = format!("{}.{}", name, method.name);
                                let sg_id = self.register_subgraph_placeholder(
                                    &mangled,
                                    method.params.len() as u8,
                                    method.is_async,
                                );
                                self.method_subgraphs.insert((tid, method_idx as u16), sg_id);
                                self.func_subgraphs.insert(mangled, sg_id);
                            }
                        }
                    }
                }
            }
        }

        // 0a-trait. 预注册 trait 默认方法单态化子图：
        //   (type_id, trait_def_idx, method_idx) → SubGraphId
        //   消费 Sema 后阶段收集的 trait_default_instances，为每个特化实例注册专用子图。
        //   实例收集（含跳过显式覆写）已由 Monomorph::collect_trait_default_instances 完成。
        for inst in &self.sema.trait_default_instances {
            // 查找 trait 默认方法的 AST 信息（method_name, params_count, is_async）
            let method_info = self.module.declarations.iter().find_map(|d| {
                if let crate::ast::Ast::Decl::TraitDecl { name, methods, .. } = &d.node {
                    if *name == inst.trait_name.as_ref() {
                        if let Some(method) = methods.get(inst.method_idx as usize) {
                            return Some((
                                method.name.to_string(),
                                method.params.len() as u8,
                                method.is_async,
                            ));
                        }
                    }
                }
                None
            });
            let (method_name, params_count, is_async) = match method_info {
                Some(info) => info,
                None => continue,
            };
            let mangled = format!("{}.{}.{}", inst.type_name, inst.trait_name, method_name);
            let sg_id = self.register_subgraph_placeholder(&mangled, params_count, is_async);
            self.trait_default_subgraphs
                .insert((inst.type_id, inst.trait_idx, inst.method_idx), sg_id);
        }

        // 0b. 注册 selective import alias 到 func_subgraphs：
        //     遍历 sema.import_aliases，将 alias 名映射到 mangled 名对应的 sg_id。
        //     alias 名（如 "area"）通过 import_alias → mangled 名（如 "Math.Geometry.circle_area"）
        //     → func_subgraphs 查找 sg_id，注册 alias 名指向同一 sg_id。
        let alias_entries: Vec<(String, String)> = self.sema.import_aliases.iter()
            .filter_map(|(alias, target)| match target {
                crate::sema::Sema::AliasTarget::Symbol(mangled) => Some((alias.clone(), mangled.to_string())),
                crate::sema::Sema::AliasTarget::Module(_) => None,
            })
            .collect();
        for (alias, mangled) in &alias_entries {
            if let Some(&sg_id) = self.func_subgraphs.get(mangled.as_str()) {
                self.func_subgraphs.insert(alias.clone(), sg_id);
            }
        }

        // 0b. 收集所有模块（entry + builtin/std/dep）顶层 var/val 声明，
        //     分配全局 slot。entry 函数编译时注入初始化代码（按模块切换 arena）。
        //     全局变量存储在 DataFlowGraph.global_var_storage 中，跨函数共享，不依赖帧链。
        //     模块索引：None = entry 模块，Some(i) = builtin_modules[i]
        //     同时注册 mangled 名（module_path.name），供 selective import alias 解析。
        for d in &self.module.declarations {
            if let crate::ast::Ast::Decl::ExprDecl { stmt: Some(stmt_id), .. } = &d.node {
                let stmt = &self.module.arena.stmt(*stmt_id).node;
                if matches!(stmt, crate::ast::Ast::Stmt::VarDecl { .. } | crate::ast::Ast::Stmt::ValDecl { .. }) {
                    let name = match stmt {
                        crate::ast::Ast::Stmt::VarDecl { name, .. } => *name,
                        crate::ast::Ast::Stmt::ValDecl { name, .. } => *name,
                        _ => unreachable!(),
                    };
                    if !self.global_var_slots.contains_key(name) {
                        let slot = self.global_var_slots.len() as u32;
                        self.global_var_slots.insert(name.to_string(), slot);
                        self.top_level_var_decls.push((None, *stmt_id));
                        // 注册 mangled 名（module_path.name）指向同一 slot
                        if let Some(ref mp) = crate::sema::Sema::module_logical_path(self.module.name) {
                            let mangled = format!("{}.{}", mp, name);
                            self.global_var_slots.insert(mangled, slot);
                        }
                    }
                }
            }
        }
        for (i, m) in self.builtin_modules.iter().enumerate() {
            for d in &m.declarations {
                if let crate::ast::Ast::Decl::ExprDecl { stmt: Some(stmt_id), .. } = &d.node {
                    let stmt = &m.arena.stmt(*stmt_id).node;
                    if matches!(stmt, crate::ast::Ast::Stmt::VarDecl { .. } | crate::ast::Ast::Stmt::ValDecl { .. }) {
                        let name = match stmt {
                            crate::ast::Ast::Stmt::VarDecl { name, .. } => *name,
                            crate::ast::Ast::Stmt::ValDecl { name, .. } => *name,
                            _ => unreachable!(),
                        };
                        if !self.global_var_slots.contains_key(name) {
                            let slot = self.global_var_slots.len() as u32;
                            self.global_var_slots.insert(name.to_string(), slot);
                            self.top_level_var_decls.push((Some(i), *stmt_id));
                            // 注册 mangled 名（module_path.name）指向同一 slot
                            if let Some(ref mp) = crate::sema::Sema::module_logical_path(m.name) {
                                let mangled = format!("{}.{}", mp, name);
                                self.global_var_slots.insert(mangled, slot);
                            }
                        }
                    }
                }
            }
        }

        // 0b-2. 注册 selective import alias 到 global_var_slots：
        //       遍历 sema.import_aliases，将别名映射到 mangled 名对应的 slot。
        //       如 "phi" → "Math.Algebra.GOLDEN_RATIO" → slot
        for (alias, target) in &self.sema.import_aliases {
            if let crate::sema::Sema::AliasTarget::Symbol(mangled) = target {
                if let Some(&slot) = self.global_var_slots.get(mangled.as_ref()) {
                    self.global_var_slots.insert(alias.clone(), slot);
                }
            }
        }

        // 0c. 注册所有模块的顶层类型到 base scope（与嵌套类型统一通过 type_scope_stack 查找）
        //     ADT 同时注册类型名和各构造器名（构造器名映射到类型名，用于反射 type_name）
        //     Newtype 注册构造器名（== 类型名），kind=Newtype 驱动 compute_record_construct 构造 NewtypeValue
        self.type_scope_stack.push(rustc_hash::FxHashMap::default());
        for m in &all_modules {
            for d in &m.declarations {
                if let crate::ast::Ast::Decl::TypeDecl { name, def, .. } = &d.node {
                    match def {
                        crate::ast::Ast::TypeDef::Record { fields } => {
                            let field_names: Vec<String> = fields.iter().map(|f| f.name.to_string()).collect();
                            self.bind_type_fields(name, TypeFieldInfo {
                                field_names,
                                type_name: name.to_string(),
                                kind: RecordLitKind::Record,
                            });
                        }
                        crate::ast::Ast::TypeDef::Adt { constructors } => {
                            // 注册类型名（nullary 路径用于类型名查找，field_names 为空仅当无字段构造器）
                            self.bind_type_fields(name, TypeFieldInfo {
                                field_names: Vec::new(),
                                type_name: name.to_string(),
                                kind: RecordLitKind::Adt,
                            });
                            // 注册每个构造器名（映射到类型名）
                            for ctor in constructors {
                                let field_names: Vec<String> = ctor.fields.iter()
                                    .map(|f| f.name.unwrap_or("_").to_string())
                                    .collect();
                                self.bind_type_fields(ctor.name, TypeFieldInfo {
                                    field_names,
                                    type_name: name.to_string(),
                                    kind: RecordLitKind::Adt,
                                });
                            }
                        }
                        crate::ast::Ast::TypeDef::Newtype { name: nt_name, .. } => {
                            // Newtype：构造器名 == 类型名，kind=Newtype
                            self.bind_type_fields(nt_name, TypeFieldInfo {
                                field_names: Vec::new(),
                                type_name: nt_name.to_string(),
                                kind: RecordLitKind::Newtype,
                            });
                        }
                        crate::ast::Ast::TypeDef::Alias { .. } => {}
                    }
                }
            }
        }

        // 1. 先编译 builtin 模块的函数（注册到 func_subgraphs 供用户代码调用）
        let builtin_fun_names: Vec<(Box<str>, usize)> = self
            .builtin_modules
            .iter()
            .enumerate()
            .flat_map(|(i, m)| {
                m.declarations.iter().filter_map(move |d| match &d.node {
                    crate::ast::Ast::Decl::FunDecl { name, extern_c_body, .. } => {
                        // 跳过 @extern("C") 函数
                        if extern_c_body.is_some() { return None; }
                        Some((name.to_string().into_boxed_str(), i))
                    }
                    _ => None,
                })
            })
            .collect();
        for (name, _mod_idx) in &builtin_fun_names {
            self.compile_function(name);
        }

        // 1b. 编译 builtin 模块中 TypeDecl 的方法（按 method_idx 索引）
        let builtin_methods: Vec<(String, usize)> = self
            .builtin_modules
            .iter()
            .flat_map(|m| {
                m.declarations.iter().flat_map(|d| {
                    if let crate::ast::Ast::Decl::TypeDecl { name, methods, .. } = &d.node {
                        methods
                            .iter()
                            .enumerate()
                            .filter(|(_, mt)| mt.body.is_some())
                            .map(|(idx, _)| (name.to_string(), idx))
                            .collect::<Vec<_>>()
                    } else {
                        Vec::new()
                    }
                })
            })
            .collect();
        for (type_name, method_idx) in &builtin_methods {
            self.compile_builtin_method(type_name, *method_idx);
        }

        // 2. 收集用户模块函数名（跳过 @extern("C") 函数 + 分析器标记的死函数）
        //    死函数不编译子图：分析器已确认无调用路径可达（单模块分析）
        let fun_names: Vec<Box<str>> = self
            .module
            .declarations
            .iter()
            .enumerate()
            .filter_map(|(idx, d)| match &d.node {
                crate::ast::Ast::Decl::FunDecl { name, extern_c_body, is_entry, .. } => {
                    if extern_c_body.is_some() { return None; }
                    // 入口函数永不消除（分析器已排除，这里双重保险）
                    if *is_entry { return Some(name.to_string().into_boxed_str()); }
                    // 分析器标记的死函数跳过
                    if self.is_dead_func(idx) { return None; }
                    Some(name.to_string().into_boxed_str())
                }
                _ => None,
            })
            .collect();

        // 2b. 编译用户模块中 TypeDecl 的方法（按 method_idx 索引，须在步骤 3 前完成）
        let user_methods: Vec<(String, usize)> = self
            .module
            .declarations
            .iter()
            .flat_map(|d| {
                if let crate::ast::Ast::Decl::TypeDecl { name, methods, .. } = &d.node {
                    methods
                        .iter()
                        .enumerate()
                        .filter(|(_, mt)| mt.body.is_some())
                        .map(|(idx, _)| (name.to_string(), idx))
                        .collect::<Vec<_>>()
                } else {
                    Vec::new()
                }
            })
            .collect();
        for (type_name, method_idx) in &user_methods {
            self.compile_user_method(type_name, *method_idx);
        }

        // 2c. 编译 trait 默认方法的单态化特化版本：
        //     消费 Sema 后阶段收集的 trait_default_instances，为每个实例编译特化子图。
        //     trait_default_subgraphs 中的条目由步骤 0a-trait 预注册。
        for inst in &self.sema.trait_default_instances {
            self.compile_trait_default_method(
                inst.trait_name.as_ref(),
                inst.method_idx as usize,
                inst.type_name.as_ref(),
            );
        }

        // 3. 编译用户模块函数
        for name in &fun_names {
            self.compile_function(name);
        }

        // 计算 fan-out
        self.graph.compute_downstreams();

        // 设置入口子图：通过函数名查 func_subgraphs（compile_function 可能为每个函数
        // 生成多个子图，declaration index 与 subgraph index 非 1:1 映射）
        for d in &self.module.declarations {
            if let crate::ast::Ast::Decl::FunDecl { name, is_entry: true, .. } = &d.node {
                if let Some(&sg) = self.func_subgraphs.get(*name) {
                    self.graph.entry_subgraph = Some(sg);
                }
                break;
            }
        }

        // 构建期填充计算函数表（运行时按 ComputeFnId 索引调用）
        self.graph.compute_fns = build_compute_fn_table();

        // 初始化全局变量存储区（按 slot count 预分配 Mutex 槽）
        let global_var_count = self.global_var_slots.len();
        let storage: Vec<std::sync::Mutex<Option<crate::Value::Value>>> = (0..global_var_count)
            .map(|_| std::sync::Mutex::new(None))
            .collect();
        self.graph.global_var_storage = Arc::new(storage);

        // 移入 IR 编译期错误（未实现的特性等），供调用方检查
        self.graph.ir_errors = std::mem::take(&mut self.errors);

        self.graph
    }
}
