//! VM 共享模块的聚合入口。
//!
//! 集中导出方法分发、类型转换、原生函数、描述符和字面量解析等
//! 在栈式 VM 与寄存器 VM 之间共用的子模块，避免重复实现。

pub const method_mod = @import("method.zig");
pub const cast_mod = @import("cast.zig");
pub const native_mod = @import("native.zig");
pub const descriptors_mod = @import("descriptors.zig");
pub const parse_mod = @import("parse.zig");
