//! JIT 运行时模块入口。
//!
//! 重新导出 Value 布局常量（layout）与 C-ABI 桥接函数（bridge），
//! 供 JIT 代码生成器和编译引擎引用。

pub const layout = @import("layout.zig");
pub const bridge = @import("bridge.zig");

// 向后兼容：直接重新导出 layout 和 bridge 的公开符号，
// 使现有 `runtime.TAG_OFFSET` / `runtime.rt_step` 等引用无需修改。
// 注意：Zig 0.16 移除了 `pub usingnamespace`，改用 `pub const ... = ...` 逐个导出。

// layout 常量
pub const VALUE_SIZE = layout.VALUE_SIZE;
pub const VALUE_ALIGN = layout.VALUE_ALIGN;
pub const TAG_OFFSET = layout.TAG_OFFSET;
pub const PAYLOAD_OFFSET = layout.PAYLOAD_OFFSET;
pub const INT_LO_OFFSET = layout.INT_LO_OFFSET;
pub const INT_TYPE_OFFSET = layout.INT_TYPE_OFFSET;
pub const INT_HI_OFFSET = layout.INT_HI_OFFSET;
pub const FLOAT_BITS_OFFSET = layout.FLOAT_BITS_OFFSET;
pub const FLOAT_EXTRA_OFFSET = layout.FLOAT_EXTRA_OFFSET;
pub const FLOAT_TYPE_OFFSET = layout.FLOAT_TYPE_OFFSET;
pub const TAG_NULL = layout.TAG_NULL;
pub const TAG_UNIT = layout.TAG_UNIT;
pub const TAG_BOOLEAN = layout.TAG_BOOLEAN;
pub const TAG_CHAR = layout.TAG_CHAR;
pub const TAG_INT = layout.TAG_INT;
pub const TAG_FLOAT = layout.TAG_FLOAT;
pub const TAG_STRING = layout.TAG_STRING;
pub const TAG_ARRAY = layout.TAG_ARRAY;
pub const ARRAY_ELEMENTS_PTR_OFFSET = layout.ARRAY_ELEMENTS_PTR_OFFSET;
pub const ARRAY_ELEMENTS_LEN_OFFSET = layout.ARRAY_ELEMENTS_LEN_OFFSET;
pub const INT_TYPE_I8 = layout.INT_TYPE_I8;
pub const INT_TYPE_I16 = layout.INT_TYPE_I16;
pub const INT_TYPE_I32 = layout.INT_TYPE_I32;
pub const INT_TYPE_I64 = layout.INT_TYPE_I64;
pub const INT_TYPE_U8 = layout.INT_TYPE_U8;
pub const INT_TYPE_U16 = layout.INT_TYPE_U16;
pub const INT_TYPE_U32 = layout.INT_TYPE_U32;
pub const INT_TYPE_U64 = layout.INT_TYPE_U64;
pub const INT_TYPE_I128 = layout.INT_TYPE_I128;
pub const FLOAT_TYPE_F8 = layout.FLOAT_TYPE_F8;
pub const FLOAT_TYPE_F16 = layout.FLOAT_TYPE_F16;
pub const FLOAT_TYPE_F32 = layout.FLOAT_TYPE_F32;
pub const FLOAT_TYPE_F64 = layout.FLOAT_TYPE_F64;
pub const FLOAT_TYPE_F128 = layout.FLOAT_TYPE_F128;

// bridge 函数
pub const rt_step = bridge.rt_step;
pub const rt_call_inline = bridge.rt_call_inline;
pub const rt_call = bridge.rt_call;
pub const rt_set_i64 = bridge.rt_set_i64;
pub const rt_get_i64 = bridge.rt_get_i64;
pub const rt_array_push = bridge.rt_array_push;
pub const rt_array_len = bridge.rt_array_len;
