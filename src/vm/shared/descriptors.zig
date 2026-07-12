//! 类型描述符定义。
//!
//! 提供 ADT 构造器、记录形状、新类型、错误构造器以及 trait 方法等
//! 编译期与运行期共用的描述结构，供 RegProgram 描述类型布局。

/// ADT 构造器描述符，记录所属类型、构造器名及各字段信息。
pub const AdtCtorDesc = struct {
    type_name: []const u8,
    ctor_name: []const u8,
    field_names: []const ?[]const u8,
    field_types: []const ?[]const u8,
    arity: u8,
};

/// 记录形状描述符，仅保存字段名顺序。
pub const RecordShape = struct {
    field_names: []const []const u8,
};

/// 新类型构造器描述符，仅记录归属的类型名。
pub const NewtypeCtorDesc = struct {
    type_name: []const u8,
};

/// 错误构造器描述符，包含类型名与默认前缀。
pub const ErrorCtorDesc = struct {
    type_name: []const u8,
    default_prefix: []const u8,
};

/// trait 方法描述符，绑定类型、方法名、trait 名到函数索引。
pub const TraitMethodDesc = struct {
    type_name: []const u8,
    method_name: []const u8,
    trait_name: []const u8,
    func_idx: u16,
};

/// trait 默认方法描述符，绑定 trait 名与方法名到函数索引。
pub const TraitDefaultDesc = struct {
    trait_name: []const u8,
    method_name: []const u8,
    func_idx: u16,
};
