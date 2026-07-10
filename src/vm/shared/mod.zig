//! VM 共享资产模块（栈式/寄存器式 VM 公用）。
//! method 分派、数值转换、Native 枚举、描述符类型、字面量解析。
pub const method_mod = @import("method.zig");
pub const cast_mod = @import("cast.zig");
pub const native_mod = @import("native.zig");
pub const descriptors_mod = @import("descriptors.zig");
pub const parse_mod = @import("parse.zig");
