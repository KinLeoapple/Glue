//! 可调用堆对象类型：内建函数、闭包、偏应用、Trait 值、惰性值
//!
//! 对应 Zig 实现中的可调用值类型。函数指针与闭包捕获均通过 `Value` 引用。

use std::fmt;
use std::rc::Rc;

use crate::value::Value;

// =========================================================================
// Builtin — 内建函数
// =========================================================================

/// 内建函数指针类型
pub type BuiltinFn = fn(&[Value]) -> Result<Value, String>;

/// 内建函数值：包装函数指针与名称
///
/// 注意：函数指针类型不自动实现 `Debug`，因此手动实现。
#[derive(Clone)]
pub struct Builtin {
    /// 函数指针
    pub fn_ptr: BuiltinFn,
    /// 函数名称（用于调试输出）
    pub name: String,
}

impl fmt::Debug for Builtin {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "<builtin {}>", self.name)
    }
}

// =========================================================================
// Closure — 闭包值
// =========================================================================

/// 闭包值：捕获环境的函数
#[derive(Debug, Clone)]
pub struct Closure {
    /// IR 函数表中的索引
    pub func_id: u32,
    /// 参数个数
    pub arity: u8,
    /// 上值列表
    pub upvalues: Vec<Value>,
    /// 已绑定的参数（用于部分应用）
    pub bound_args: Vec<Value>,
    /// `self` 上值索引，`-1` 表示无
    pub self_upvalue_idx: i32,
    /// 上值引用位图
    pub upvalue_ref_bits: u8,
    /// 上值中 Cell 数量
    pub cell_upvalues: u8,
}

// =========================================================================
// PartialApplication — 偏应用（柯里化函数）
// =========================================================================

/// 偏应用值：已绑定部分参数的函数
#[derive(Debug, Clone)]
pub struct PartialApplication {
    /// IR 函数表中的索引
    pub func_id: u32,
    /// 已绑定的参数列表
    pub bound_args: Vec<Value>,
    /// 剩余所需参数个数
    pub remaining_arity: u8,
    /// 绑定参数引用位图
    pub bound_arg_ref_bits: u16,
}

// =========================================================================
// TraitValue — Trait 值（内联 trait 实现）
// =========================================================================

/// Trait 值：内联 trait 实现的运行时表示
#[derive(Debug, Clone)]
pub struct TraitValue {
    /// trait 名称
    pub trait_name: String,
    /// 方法名称列表
    pub method_names: Vec<String>,
    /// 方法值列表（与 `method_names` 一一对应）
    pub method_values: Vec<Value>,
    /// 关联数据（可选）
    pub data: Option<Value>,
    /// 是否拥有数据所有权
    pub owned: bool,
}

// =========================================================================
// LazyValue — 惰性值（延迟求值的 thunk）
// =========================================================================

/// 惰性值：延迟求值的 thunk，首次访问时强制求值并缓存结果
///
/// 注意：`Rc<dyn Fn() -> Value>` 不实现 `Debug`，因此手动实现。
#[derive(Clone)]
pub struct LazyValue {
    /// 缓存的求值结果
    pub cached: Option<Value>,
    /// 是否已强制求值
    pub forced: bool,
    /// thunk 闭包：延迟求值的计算体
    pub thunk: Option<Rc<dyn Fn() -> Value>>,
}

impl fmt::Debug for LazyValue {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.debug_struct("LazyValue")
            .field("cached", &self.cached)
            .field("forced", &self.forced)
            .field("thunk", &self.thunk.as_ref().map(|_| "<thunk>"))
            .finish()
    }
}
