//! VM 共享：类型描述符（ADT/Record/Newtype/Error/Trait）。
//! 栈式与寄存器式 VM 共用。

/// ADT 构造器描述：OP_MAKE_ADT / make_adt 索引进 program.adt_ctors。
/// type_name/ctor_name/field_names/field_types 借用 AST 字节（不持有），外层切片由 Program alloc/free。
pub const AdtCtorDesc = struct {
    type_name: []const u8,
    ctor_name: []const u8,
    /// 各字段名（位置字段为 null）；len == arity。建 AdtValue 时填 fields[i].name。
    field_names: []const ?[]const u8,
    /// 各字段声明类型名（builtin 数值类型才非 null），用于隐式定型
    /// （如 Emp(.., salary: i32) 把 i8 实参 100 协调成 i32，避免后续算术溢出）。len == arity。
    field_types: []const ?[]const u8,
    arity: u8,
};

/// 记录字面量形状：OP_MAKE_RECORD / make_record 索引进 program.record_shapes。
/// field_names 借用 AST 字节（不持有），外层切片由 Program alloc/free。栈顶 n 个值依次对应。
pub const RecordShape = struct {
    field_names: []const []const u8,
};

/// Newtype 构造器描述：OP_MAKE_NEWTYPE / make_newtype 索引进 program.newtype_ctors。
/// type_name 借用 AST 字节（不持有）。
pub const NewtypeCtorDesc = struct {
    type_name: []const u8,
};

/// 自定义错误类型构造器描述：OP_MAKE_ERROR / make_error 索引进 program.error_ctors。
/// type FileError = Error("file error") → FileError("msg") 产 throw_val.err{
///   type_name="FileError", message="file error: msg", is_error_subtype=true}。
/// type_name / default_prefix 借用 AST 字节（不持有）。
pub const ErrorCtorDesc = struct {
    type_name: []const u8,
    default_prefix: []const u8,
};

/// trait 方法描述：`type T: Trait { fun m(self, ..) {..} }` 编出的方法函数。
/// OP_CALL_METHOD / call_method 据 receiver 的类型名 + 方法名查此表分派。type_name/method_name/trait_name 借用 AST。
/// func_idx 指向 program.functions 中编译好的方法体（self 占 slot 0）。
pub const TraitMethodDesc = struct {
    type_name: []const u8,
    method_name: []const u8,
    trait_name: []const u8,
    func_idx: u16,
};

/// trait 默认方法描述：`trait T { fun m(self) {..默认..} }`，类型未覆写时回退此体。
/// trait_name/method_name 借用 AST；func_idx 指向编译好的默认方法体。
pub const TraitDefaultDesc = struct {
    trait_name: []const u8,
    method_name: []const u8,
    func_idx: u16,
};
