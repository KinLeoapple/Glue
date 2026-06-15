//! 子类型检查
//!
//! 从 type_check.zig 提取的子类型判定逻辑，以自由函数形式实现。
//! TypeInferencer 上的 isSubtype/isRecordSubtype/... 方法委托到此模块。
//!
//! 文档 §2.12: 三种子类型关系
//!   §2.12.1 记录宽度子类型 —— 字段更多的记录是字段更少的记录的子类型
//!   §2.12.2 Trait 结构化子类型 —— 方法更多的模块是方法更少的 Trait 的子类型
//!   §2.12.3 Error 子类型 —— 自定义错误类型是 Error 的子类型
//! 另含 Null<:T?、T<:T?、Throw<T,E1><:Throw<T,E2>(E1<:E2) 等关系。

const std = @import("std");
const ast = @import("ast");
const type_check = @import("type_check");

pub const Type = type_check.Type;
pub const FieldType = type_check.FieldType;
pub const TypeInferencer = type_check.TypeInferencer;

/// 子类型判定：sub <: super ?
pub fn isSubtype(inferencer: *TypeInferencer, sub: *Type, super: *Type) bool {
    const resolved_sub = inferencer.resolve(sub);
    const resolved_super = inferencer.resolve(super);

    // 相同类型
    if (resolved_sub == resolved_super) return true;

    // 1. Null <: T?（文档 §2.3.1: null 是所有 T? 的共享值）
    if (resolved_sub.* == .null_type and resolved_super.* == .nullable_type) return true;

    // 2. T <: T?（任何类型都是其可空版本的子类型）
    if (resolved_super.* == .nullable_type) {
        const inner = resolved_super.nullable_type;
        if (isSubtype(inferencer, resolved_sub, inner)) return true;
    }

    // 3. 记录宽度子类型（文档 §2.12.1）
    //    (name: str, age: i32) <: (name: str)
    if (resolved_sub.* == .record_type and resolved_super.* == .record_type) {
        return isRecordSubtype(inferencer, resolved_sub.record_type.fields, resolved_super.record_type.fields);
    }

    // 4. Error 子类型（文档 §2.12.3）
    //    FileError <: Error
    if (resolved_sub.* == .adt_type and resolved_super.* == .adt_type) {
        return isErrorSubtype(inferencer, resolved_sub.adt_type.name, resolved_super.adt_type.name);
    }

    // 5. Throw 子类型：Throw<T, E1> <: Throw<T, E2> 当 E1 <: E2
    if (resolved_sub.* == .throw_type and resolved_super.* == .throw_type) {
        return isThrowSubtype(
            inferencer,
            resolved_sub.throw_type.value_type,
            resolved_sub.throw_type.error_type,
            resolved_super.throw_type.value_type,
            resolved_super.throw_type.error_type,
        );
    }

    // 6. Trait 结构化子类型（文档 §2.12.2）
    //    方法更多的模块是方法更少的 Trait 的子类型
    if (resolved_sub.* == .trait_type and resolved_super.* == .trait_type) {
        return isTraitStructuralSubtype(inferencer, resolved_sub.trait_type.name, resolved_super.trait_type.name);
    }

    return false;
}

/// 记录宽度子类型检查
/// 文档 §2.12.1: 字段更多的记录是字段更少的记录的子类型
pub fn isRecordSubtype(inferencer: *TypeInferencer, sub_fields: []const FieldType, super_fields: []const FieldType) bool {
    _ = inferencer;
    // 子类型（字段更多）必须包含父类型（字段更少）的所有字段
    for (super_fields) |super_field| {
        var found = false;
        for (sub_fields) |sub_field| {
            if (std.mem.eql(u8, super_field.name, sub_field.name)) {
                // 字段类型必须相同（简化处理，递归子类型检查在 unify 中处理）
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/// 调用点方向性检查：实参类型 arg 是否满足形参类型 param。
/// 只针对「两者都是记录」的情况按宽度子类型方向把关（arg 字段 ⊇ param 字段），
/// 并对同名字段递归检查（嵌套记录的宽度子类型也按方向把关）；
/// 其它类型组合一律返回 true，交给 unify/tryWidenUnify 处理。
pub fn recordArgSatisfies(inferencer: *TypeInferencer, param: *Type, arg: *Type) bool {
    const rp = inferencer.resolve(param);
    const ra = inferencer.resolve(arg);
    if (rp.* != .record_type or ra.* != .record_type) return true;
    // param 的每个字段都要在 arg 中出现，且字段类型递归满足
    for (rp.record_type.fields) |pf| {
        var found = false;
        for (ra.record_type.fields) |af| {
            if (std.mem.eql(u8, pf.name, af.name)) {
                if (!recordArgSatisfies(inferencer, pf.ty, af.ty)) return false;
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/// Error 子类型检查
/// 文档 §2.12.3: 自定义错误类型是 Error 的子类型
pub fn isErrorSubtype(inferencer: *TypeInferencer, sub_name: []const u8, super_name: []const u8) bool {
    // 检查 sub 是否是 Error 的子类型
    if (std.mem.eql(u8, super_name, "Error")) {
        if (inferencer.adt_types.get(sub_name)) |info| {
            if (info.is_error_newtype) return true;
        }
    }
    return false;
}

/// Throw 子类型检查
/// Throw<T, E1> <: Throw<T, E2> 当 E1 <: E2
pub fn isThrowSubtype(inferencer: *TypeInferencer, sub_val: *Type, sub_err: *Type, super_val: *Type, super_err: *Type) bool {
    // 值类型必须兼容
    if (!isSubtype(inferencer, sub_val, super_val)) return false;
    // 错误类型必须是子类型关系
    if (!isSubtype(inferencer, sub_err, super_err)) return false;
    return true;
}

/// Trait 结构化子类型检查
/// 文档 §2.12.2: 方法更多的模块是方法更少的 Trait 的子类型
pub fn isTraitStructuralSubtype(inferencer: *TypeInferencer, sub_name: []const u8, super_name: []const u8) bool {
    const sub_info = inferencer.trait_types.get(sub_name) orelse return false;
    const super_info = inferencer.trait_types.get(super_name) orelse return false;

    // sub 必须包含 super 的所有方法
    for (super_info.method_names) |super_method| {
        var found = false;
        for (sub_info.method_names) |sub_method| {
            if (std.mem.eql(u8, super_method, sub_method)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}
