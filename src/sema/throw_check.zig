//! Throw / 可空类型的返回值统一与传播（propagate）检查模块。
//!
//! 本模块处理与 Glue 错误处理机制相关的语义检查：
//! - 函数返回类型与函数体推断类型之间的统一（含 nullable/throw 的特殊放宽规则）
//! - 数值类型间的宽化（widening）统一，避免不必要的类型不匹配
//! - 传播操作符 `?` 在 nullable/throw 表达式上的合法性检查与类型展开
//! - throw 语句的表达式必须是 Error 子类型（error_newtype 或 Error trait 实例）

const std = @import("std");
const ast = @import("ast");
const type_check = @import("type_check");

const Type = type_check.Type;
const TypeInferencer = type_check.TypeInferencer;
const SemaError = type_check.SemaError;
const TypeErrorKind = type_check.TypeErrorKind;

/// 判断数值类型 `from` 是否可被隐式宽化为数值类型 `to`。
/// 覆盖整型之间、浮点之间以及整型到浮点的宽化规则。
fn canCoerceNumeric(to: *const Type, from: *const Type) bool {
    const to_int_rank = intTypeRank(to.*);
    const from_int_rank = intTypeRank(from.*);
    const to_float_rank = floatTypeRank(to.*);
    const from_float_rank = floatTypeRank(from.*);

    // 整型之间：同秩或目标秩更大时允许宽化
    if (to_int_rank > 0 and from_int_rank > 0) {
        const to_signed = isSignedInt(to.*);
        const from_signed = isSignedInt(from.*);
        if (to_int_rank == from_int_rank and to_signed == from_signed) {
            return true;
        }
        if (to_int_rank == from_int_rank) {
            return true;
        }
        if (to_signed == from_signed) {
            return to_int_rank >= from_int_rank;
        } else if (from_signed and !to_signed) {
            // 有符号 -> 无符号需要目标秩严格更大以容纳符号位
            return to_int_rank > from_int_rank;
        } else {
            return to_int_rank > from_int_rank;
        }
    }
    // 浮点之间：任意浮点都可宽化为更大秩的浮点
    if (to_float_rank > 0 and from_float_rank > 0) {
        return true;
    }
    // 整型 -> 浮点：允许
    if (to_float_rank > 0 and from_int_rank > 0) {
        return true;
    }
    return false;
}

/// 返回浮点类型的秩（用于宽化比较），非浮点返回 0。
fn floatTypeRank(t: Type) u8 {
    return switch (t) {
        .f16_type => 1,
        .f32_type => 2,
        .f64_type => 3,
        .f128_type => 4,
        else => 0,
    };
}

/// 返回整型的秩（用于宽化比较），同宽的有符号/无符号共享同一秩，非整型返回 0。
fn intTypeRank(t: Type) u8 {
    return switch (t) {
        .i8_type => 1,
        .u8_type => 1,
        .i16_type => 2,
        .u16_type => 2,
        .i32_type => 3,
        .u32_type => 3,
        .i64_type => 4,
        .u64_type => 4,
        .i128_type => 5,
        .u128_type => 5,
        // isize/usize 跟随平台位宽等价处理
        .isize_type => 4,
        .usize_type => 4,
        else => 0,
    };
}

/// 判断是否为有符号整型。
fn isSignedInt(t: Type) bool {
    return switch (t) {
        .i8_type, .i16_type, .i32_type, .i64_type, .i128_type, .isize_type => true,
        else => false,
    };
}

/// 统一函数声明的返回类型与函数体推断出的类型。
///
/// 针对 nullable/throw 返回类型有特殊放宽：函数体返回 unit（如早退/抛出）
/// 时不视为不匹配；否则尝试宽化统一，失败再回退到严格 unify。
pub fn unifyReturnType(inferencer: *TypeInferencer, declared: *Type, inferred: *Type) SemaError!void {
    const resolved_declared = inferencer.resolve(declared);
    const resolved_inferred = inferencer.resolve(inferred);

    switch (resolved_declared.*) {
        .nullable_type => |inner| {
            switch (resolved_inferred.*) {
                .nullable_type => try inferencer.unify(declared, inferred),
                .unit_type => {
                    // 函数体未产生值（如抛出/提前返回），与 nullable 兼容
                },
                else => {
                    _ = tryWidenUnify(inferencer, inner, inferred) catch {
                        try inferencer.unify(inner, inferred);
                    };
                },
            }
        },
        .throw_type => |tt| {
            switch (resolved_inferred.*) {
                .throw_type => {
                    _ = tryWidenUnify(inferencer, declared, inferred) catch {
                        try inferencer.unify(declared, inferred);
                    };
                },
                .unit_type => {
                    // 函数体未产生值，与 throw 兼容
                },
                else => {
                    _ = tryWidenUnify(inferencer, tt.value_type, inferred) catch {
                        try inferencer.unify(tt.value_type, inferred);
                    };
                },
            }
        },
        else => {
            _ = tryWidenUnify(inferencer, resolved_declared, resolved_inferred) catch {
                try inferencer.unify(declared, inferred);
            };
        },
    }
}

/// 尝试对两个类型进行宽化统一，返回统一后的类型。
///
/// 先尝试严格 unify；失败时若二者均为数值类型则按宽化规则择一返回；
/// 否则针对 nullable/throw 与普通类型、unit 等组合做结构性兼容处理，
/// 全部失败时返回 TypeMismatch 错误。
pub fn tryWidenUnify(inferencer: *TypeInferencer, t1: *Type, t2: *Type) SemaError!*Type {
    const r1 = inferencer.resolve(t1);
    const r2 = inferencer.resolve(t2);

    if (inferencer.unify(r1, r2)) {
        return r1;
    } else |_| {
        // 数值类型之间尝试宽化
        if (r1.isNumericType() and r2.isNumericType()) {
            if (canCoerceNumeric(r1, r2)) {
                return r1;
            }
            if (canCoerceNumeric(r2, r1)) {
                return r2;
            }
            return error.TypeMismatch;
        }
        switch (r1.*) {
            .nullable_type => |inner1| {
                switch (r2.*) {
                    .nullable_type => |inner2| {
                        const inner1_resolved = inferencer.resolve(inner1);
                        const inner2_resolved = inferencer.resolve(inner2);
                        if (inferencer.unify(inner1_resolved, inner2_resolved)) |_| {
                            return r1;
                        } else |_| {
                            if (inner1_resolved.isNumericType() and inner2_resolved.isNumericType()) {
                                if (canCoerceNumeric(inner1_resolved, inner2_resolved)) {
                                    return r1;
                                }
                            }
                            return error.TypeMismatch;
                        }
                    },
                    .unit_type => {
                        // unit 可视为 nullable 的“空值”
                        return r1;
                    },
                    else => {
                        // nullable<T> 与 T 兼容
                        if (inferencer.unify(inner1, r2)) |_| {
                            return r1;
                        } else |_| {
                            const inner1_resolved = inferencer.resolve(inner1);
                            const r2_resolved = inferencer.resolve(r2);
                            if (inner1_resolved.isNumericType() and r2_resolved.isNumericType()) {
                                if (canCoerceNumeric(inner1_resolved, r2_resolved)) {
                                    return r1;
                                }
                            }
                            return error.TypeMismatch;
                        }
                    },
                }
            },
            .throw_type => |tt1| {
                switch (r2.*) {
                    .throw_type => |tt2| {
                        const v1 = inferencer.resolve(tt1.value_type);
                        const v2 = inferencer.resolve(tt2.value_type);
                        inferencer.unify(tt1.error_type, tt2.error_type) catch return error.TypeMismatch;
                        if (inferencer.unify(v1, v2)) |_| {
                            return r1;
                        } else |_| {
                            if (v1.isNumericType() and v2.isNumericType()) {
                                if (canCoerceNumeric(v1, v2)) {
                                    return r1;
                                }
                            }
                            return error.TypeMismatch;
                        }
                    },
                    .unit_type => {
                        // unit 可视为 throw 的“未取值”
                        return r1;
                    },
                    else => {
                        // Throw<T, E> 与 T 兼容（仅取值维度）
                        if (inferencer.unify(tt1.value_type, r2)) |_| {
                            return r1;
                        } else |_| {
                            const value_ty_resolved = inferencer.resolve(tt1.value_type);
                            const r2_resolved = inferencer.resolve(r2);
                            if (value_ty_resolved.isNumericType() and r2_resolved.isNumericType()) {
                                if (canCoerceNumeric(value_ty_resolved, r2_resolved)) {
                                    return r1;
                                }
                            }
                            return error.TypeMismatch;
                        }
                    },
                }
            },
            .unit_type => {
                switch (r2.*) {
                    .nullable_type, .throw_type => return r2,
                    else => return error.TypeMismatch,
                }
            },
            else => {
                switch (r2.*) {
                    .nullable_type => |inner2| {
                        // T 与 nullable<T> 兼容，统一为 nullable
                        inferencer.unify(r1, inner2) catch return error.TypeMismatch;
                        return r2;
                    },
                    .throw_type => |tt2| {
                        // T 与 Throw<T, E> 兼容，统一为 throw
                        inferencer.unify(r1, tt2.value_type) catch return error.TypeMismatch;
                        return r2;
                    },
                    else => return error.TypeMismatch,
                }
            },
        }
    }
}

/// 检查传播操作符 `?` 在表达式上的合法性，并返回展开后的类型。
///
/// - nullable：展开为内层类型；要求外层函数返回类型也是 nullable，否则报错
/// - throw：展开为值类型；要求外层函数返回类型也是 throw，否则报错
/// - 其它类型：报“不可用于非 nullable/throw 表达式”错误，并返回原类型
pub fn checkPropagate(
    inferencer: *TypeInferencer,
    resolved_inner: *Type,
    inner_ty: *Type,
    fn_return_type: ?*Type,
    location: ast.SourceLocation,
) *Type {
    switch (resolved_inner.*) {
        .nullable_type => |inner| {
            if (fn_return_type) |fn_ret| {
                const resolved_ret = inferencer.resolve(fn_ret);
                switch (resolved_ret.*) {
                    .nullable_type => {
                        // 外层函数同样返回 nullable，传播合法
                    },
                    else => {
                        inferencer.addErrorAt(.propagate_cross_type, location.line, location.column, "propagation operator '?' on T? requires enclosing function to return U?, but return type is non-nullable", .{});
                    },
                }
            }
            return inner;
        },
        .throw_type => |tt| {
            if (fn_return_type) |fn_ret| {
                const resolved_ret = inferencer.resolve(fn_ret);
                switch (resolved_ret.*) {
                    .throw_type => {
                        // 外层函数同样返回 throw，传播合法
                    },
                    else => {
                        inferencer.addErrorAt(.propagate_cross_type, location.line, location.column, "propagation operator '?' on Throw<T, E> requires enclosing function to return Throw<U, E'>, but return type is non-throw", .{});
                    },
                }
            }
            return tt.value_type;
        },
        else => {
            // 非 nullable/throw 表达式使用传播操作符属于错误
            if (fn_return_type) |fn_ret| {
                const resolved_ret = inferencer.resolve(fn_ret);
                switch (resolved_ret.*) {
                    .nullable_type, .throw_type => {
                        inferencer.addErrorAt(.propagate_cross_type, location.line, location.column, "propagation operator '?' cannot be used on a non-nullable, non-throw expression", .{});
                    },
                    else => {
                        inferencer.addErrorAt(.propagate_cross_type, location.line, location.column, "propagation operator '?' cannot be used on a non-nullable, non-throw expression", .{});
                    },
                }
            }
            return inner_ty;
        },
    }
}

/// 检查 throw 语句的表达式是否为 Error 子类型。
///
/// 合法情况：
/// - 类型为 adt_type 且在 adt_types 中标记 is_error_newtype=true（用户定义的 `type X: Error = X(...)`）
/// - 类型为 adt_type 且实现了 Error trait（通过 registered_traits 注册，key 为 "Error::TypeName"）
/// - 类型为 throw_type（如 `throw Error("...")`，builtin Error 构造返回 Throw<T, Error>）
/// - 类型为 type_var（尚未解析出具体类型，延迟到后续统一阶段处理）
///
/// 非法情况：抛出非 Error 类型（如 i32、str、普通 record），报 type_mismatch 错误。
pub fn checkThrowStmt(
    inferencer: *TypeInferencer,
    thrown_ty: *Type,
    location: ast.SourceLocation,
) void {
    const resolved = inferencer.resolve(thrown_ty);

    // 类型变量延迟到统一阶段判断
    switch (resolved.*) {
        .type_var => return,
        .throw_type => return, // throw Error("...") 返回 Throw<T, Error>，合法
        .adt_type => |adt| {
            // 检查是否为 error_newtype
            if (inferencer.adt_types.get(adt.name)) |info| {
                if (info.is_error_newtype) return;
            }
            // 检查是否实现 Error trait（registered_traits 的 key 格式为 "TraitName::TypeName"）
            const trait_key = std.fmt.allocPrint(
                inferencer.arena.allocator(),
                "Error::{s}",
                .{adt.name},
            ) catch return;
            defer inferencer.arena.allocator().free(trait_key);
            if (inferencer.registered_traits.contains(trait_key)) return;
        },
        .generic_type => |gt| {
            if (inferencer.adt_types.get(gt.name)) |info| {
                if (info.is_error_newtype) return;
            }
            const trait_key = std.fmt.allocPrint(
                inferencer.arena.allocator(),
                "Error::{s}",
                .{gt.name},
            ) catch return;
            defer inferencer.arena.allocator().free(trait_key);
            if (inferencer.registered_traits.contains(trait_key)) return;
        },
        else => {},
    }

    inferencer.addErrorAt(
        .type_mismatch,
        location.line,
        location.column,
        "throw expression must be an Error subtype, got {s}",
        .{@tagName(resolved.*)},
    );
}
