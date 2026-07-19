//! 子类型关系判定模块。
//!
//! 本模块负责 Glue 语言中各种类型之间的子类型（subtyping）检查，包括：
//! - 基础类型与可空类型之间的兼容关系
//! - 记录类型（record）的结构化子类型
//! - 代数数据类型（ADT）的错误子类型关系
//! - Throw 类型在值/错误维度上的子类型关系
//! - trait 之间的结构化子类型关系
//!
//! 这些判定由 TypeInferencer 在 unify、参数检查等场景下调用。

const std = @import("std");
const ast = @import("ast");
const type_check = @import("type_check");

pub const Type = type_check.Type;
pub const FieldType = type_check.FieldType;
pub const TypeInferencer = type_check.TypeInferencer;

/// 判断 `sub` 是否为 `super` 的子类型。
///
/// 判定流程依次处理：同一类型、null 与 nullable 的关系、nullable 内层、
/// record 结构子类型、ADT 错误子类型、Throw 子类型以及 trait 结构子类型。
/// 任何一步成立即返回 true；否则最终返回 false。
pub fn isSubtype(inferencer: *TypeInferencer, sub: *Type, super: *Type) bool {
    const resolved_sub = inferencer.resolve(sub);
    const resolved_super = inferencer.resolve(super);

    // 解析后指向同一类型对象，必然兼容
    if (resolved_sub == resolved_super) return true;

    // null 字面量类型可赋值给任意可空类型
    if (resolved_sub.* == .null_type and resolved_super.* == .nullable_type) return true;

    // 可空类型的内层类型若与 sub 存在子类型关系，则整体也兼容
    if (resolved_super.* == .nullable_type) {
        const inner = resolved_super.nullable_type;
        if (isSubtype(inferencer, resolved_sub, inner)) return true;
    }

    // 记录类型按结构化子类型判定（子类型需包含超类型全部字段）
    if (resolved_sub.* == .record_type and resolved_super.* == .record_type) {
        return isRecordSubtype(inferencer, resolved_sub.record_type.fields, resolved_super.record_type.fields);
    }

    // ADT 类型仅在错误新类型（error newtype）场景下构成子类型
    if (resolved_sub.* == .adt_type and resolved_super.* == .adt_type) {
        return isErrorSubtype(inferencer, resolved_sub.adt_type.name, resolved_super.adt_type.name);
    }

    // Throw 类型要求值类型与错误类型同时满足子类型关系
    if (resolved_sub.* == .throw_type and resolved_super.* == .throw_type) {
        return isThrowSubtype(
            inferencer,
            resolved_sub.throw_type.value_type,
            resolved_sub.throw_type.error_type,
            resolved_super.throw_type.value_type,
            resolved_super.throw_type.error_type,
        );
    }

    // trait 类型按方法集合的结构化子类型判定
    if (resolved_sub.* == .trait_type and resolved_super.* == .trait_type) {
        return isTraitStructuralSubtype(inferencer, resolved_sub.trait_type.name, resolved_super.trait_type.name);
    }

    return false;
}

/// 记录类型结构化子类型判定：`sub_fields` 是否覆盖 `super_fields` 的全部字段。
/// 仅按字段名匹配，不递归校验字段类型（宽度子类型）。
pub fn isRecordSubtype(inferencer: *TypeInferencer, sub_fields: []const FieldType, super_fields: []const FieldType) bool {
    _ = inferencer;

    for (super_fields) |super_field| {
        var found = false;
        for (sub_fields) |sub_field| {
            if (std.mem.eql(u8, super_field.name, sub_field.name)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/// 判断实参记录 `arg` 是否满足形参记录 `param` 的字段要求。
/// 非记录类型视为满足；记录类型则递归校验每个形参字段都存在且类型满足。
pub fn recordArgSatisfies(inferencer: *TypeInferencer, param: *Type, arg: *Type) bool {
    const rp = inferencer.resolve(param);
    const ra = inferencer.resolve(arg);

    // 其中任一不是记录类型则不做结构校验
    if (rp.* != .record_type or ra.* != .record_type) return true;

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

/// 错误子类型判定：当 `super_name` 为内置 Error 类型时，
/// 任何错误新类型（is_error_newtype）的 ADT 都是其子类型。
pub fn isErrorSubtype(inferencer: *TypeInferencer, sub_name: []const u8, super_name: []const u8) bool {
    if (std.mem.eql(u8, super_name, "Error")) {
        if (inferencer.adt_types.get(sub_name)) |info| {
            if (info.is_error_newtype) return true;
        }
    }
    return false;
}

/// Throw 子类型判定：值类型与错误类型需同时满足子类型关系。
pub fn isThrowSubtype(inferencer: *TypeInferencer, sub_val: *Type, sub_err: *Type, super_val: *Type, super_err: *Type) bool {
    if (!isSubtype(inferencer, sub_val, super_val)) return false;
    if (!isSubtype(inferencer, sub_err, super_err)) return false;
    return true;
}

/// trait 结构化子类型判定：`sub_name` 的方法集合需覆盖 `super_name` 的全部方法名。
pub fn isTraitStructuralSubtype(inferencer: *TypeInferencer, sub_name: []const u8, super_name: []const u8) bool {
    const sub_info = inferencer.trait_types.get(sub_name) orelse return false;
    const super_info = inferencer.trait_types.get(super_name) orelse return false;

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
