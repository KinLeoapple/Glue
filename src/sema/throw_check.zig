//! Throw 类型检查
//!
//! Phase 6+ 实现：Throw<T, E> 效果系统与错误传播检查
//!
//! 本模块提取了 TypeInferencer 中与 Nullable/Throw 相关的类型检查逻辑：
//! - unifyReturnType: 函数返回类型的 T → T? / Throw<T, E> 自动提升
//! - tryWidenUnify: Nullable/Throw 类型的自动宽化统一
//! - checkPropagate: ? 传播操作符的类型检查

const std = @import("std");
const ast = @import("ast");
const type_check = @import("type_check");

const Type = type_check.Type;
const TypeInferencer = type_check.TypeInferencer;
const SemaError = type_check.SemaError;
const TypeErrorKind = type_check.TypeErrorKind;

/// 判断类型from是否可以按§6.12规则widening/narrowing到to
/// 用于支持"显式标注指导字面量类型"
///
/// §6.12规则2: 显式类型标注次之：val x: i64 = 5 中字面量按标注类型处理
/// 这意味着字面量可以根据标注进行widening或narrowing
///
/// 整数：val a: i32 = 100，100推断为i8，允许widen到i32
/// 浮点：val f: f32 = 3.14，3.14推断为f64，允许narrow到f32（标注指导）
fn canCoerceNumeric(to: *const Type, from: *const Type) bool {
    // 首先检查是否完全相同类型
    const to_int_rank = intTypeRank(to.*);
    const from_int_rank = intTypeRank(from.*);
    const to_float_rank = floatTypeRank(to.*);
    const from_float_rank = floatTypeRank(from.*);

    // 相同整数类型
    if (to_int_rank > 0 and from_int_rank > 0) {
        const to_signed = isSignedInt(to.*);
        const from_signed = isSignedInt(from.*);

        // 完全相同的类型：允许
        if (to_int_rank == from_int_rank and to_signed == from_signed) {
            return true;
        }

        // §6.12规则2: 标注指导字面量类型
        // val d: u8 = 55，其中55推断为i8，但标注u8应该允许
        // 只要值在目标类型范围内即可（运行时保证）
        if (to_int_rank == from_int_rank) {
            // 同位宽的有符号<->无符号转换：允许
            // i8 <-> u8, i16 <-> u16等
            return true;
        }

        // 整数widening：目标类型更大
        if (to_signed == from_signed) {
            return to_int_rank >= from_int_rank;
        } else if (from_signed and !to_signed) {
            // 有符号->无符号：需要更大rank（严格大于）
            return to_int_rank > from_int_rank;
        } else {
            // 无符号->有符号：需要更大rank
            return to_int_rank > from_int_rank;
        }
    }

    // 相同浮点类型
    if (to_float_rank > 0 and from_float_rank > 0) {
        // §6.12: 标注指导字面量类型，允许任意浮点转换
        // val f: f32 = 3.14 中，3.14(f64)可以按标注转为f32
        return true;
    }

    // 整数->浮点（widening）
    if (to_float_rank > 0 and from_int_rank > 0) {
        return true;
    }

    return false;
}

/// 获取浮点类型的rank
fn floatTypeRank(t: Type) u8 {
    return switch (t) {
        .f16_type => 1,
        .f32_type => 2,
        .f64_type => 3,
        .f128_type => 4,
        else => 0,
    };
}

/// 获取整数类型的rank（位宽等级）
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
        else => 0, // 非整数类型
    };
}

/// 判断是否是有符号整数类型
fn isSignedInt(t: Type) bool {
    return switch (t) {
        .i8_type, .i16_type, .i32_type, .i64_type, .i128_type => true,
        else => false,
    };
}

/// 函数返回类型的 Nullable/Throw 自动提升
///
/// 当声明返回 T? 但推断为 T 时，将 T 统一到 T? 的内部类型；
/// 当声明返回 Throw<T, E> 但推断为 T 时，将 T 统一到 Throw 的 value_type。
/// §6.12规则2: 函数返回类型标注也应该指导字面量类型
pub fn unifyReturnType(inferencer: *TypeInferencer, declared: *Type, inferred: *Type) SemaError!void {
    const resolved_declared = inferencer.resolve(declared);
    const resolved_inferred = inferencer.resolve(inferred);

    switch (resolved_declared.*) {
        .nullable_type => |inner| {
            // 声明返回 T?，推断为 T → 将 T 统一到 T? 的内部类型
            switch (resolved_inferred.*) {
                .nullable_type => try inferencer.unify(declared, inferred),
                .unit_type => {
                    // Function body is all throws/defer, return type T? is OK
                },
                else => {
                    // 先尝试tryWidenUnify支持数值类型标注指导
                    _ = tryWidenUnify(inferencer, inner, inferred) catch {
                        // 如果widening失败，再用严格unify
                        try inferencer.unify(inner, inferred);
                    };
                },
            }
        },
        .throw_type => |tt| {
            // 声明返回 Throw<T, E>，推断为 T → 将 T 统一到 Throw 的 value_type
            switch (resolved_inferred.*) {
                .throw_type => {
                    // 两者都是 Throw，使用 tryWidenUnify 支持数值类型提升
                    _ = tryWidenUnify(inferencer, declared, inferred) catch {
                        try inferencer.unify(declared, inferred);
                    };
                },
                .unit_type => {
                    // Function body is all throws/defer, return type Throw<T, E> is OK
                },
                else => {
                    // 先尝试tryWidenUnify支持数值类型标注指导
                    _ = tryWidenUnify(inferencer, tt.value_type, inferred) catch {
                        // 如果widening失败，再用严格unify
                        try inferencer.unify(tt.value_type, inferred);
                    };
                },
            }
        },
        else => {
            // 普通类型：使用tryWidenUnify支持§6.12规则2
            // fun foo(): i32 { 42 } 中，42推断为i8，i32标注应该指导
            _ = tryWidenUnify(inferencer, resolved_declared, resolved_inferred) catch {
                // 如果widening失败，再用严格unify
                try inferencer.unify(declared, inferred);
            };
        },
    }
}

/// Nullable/Throw 类型的自动宽化统一
///
/// 在直接统一失败后，尝试以下宽化策略：
/// - T? 与 T: 将 T 统一到 T? 的内部类型，返回 T?
/// - Throw<T, E> 与 T: 将 T 统一到 Throw 的 value_type，返回 Throw<T, E>
/// - () 与 T? 或 Throw<T, E>: 兼容（函数体全为 throw/defer）
pub fn tryWidenUnify(inferencer: *TypeInferencer, t1: *Type, t2: *Type) SemaError!*Type {
    const r1 = inferencer.resolve(t1);
    const r2 = inferencer.resolve(t2);

    // Try direct unification first
    if (inferencer.unify(r1, r2)) {
        return r1;
    } else |_| {
        // 文档 §6.12: 字面量类型确定优先级
        // 1. 显式后缀最高优先：42i32, 255u8
        // 2. 显式类型标注次之：val x: i64 = 5 中字面量按标注类型处理
        // 3. 既无后缀也无标注时，推断为最小容纳类型
        //
        // 这里的场景是：tryWidenUnify(标注类型, 推断类型)
        // - val a: i32 = 100: r1=i32(标注), r2=i8(推断) → 允许widening
        // - val f: f32 = 3.14: r1=f32(标注), r2=f128(推断) → 允许narrowing（标注指导）
        //
        // 但在 if 表达式中：tryWidenUnify(then_ty, else_ty)
        // - if true { 1 } else { n }: r1=i8(字面量), r2=i32(变量) → 应该统一为 i32
        // 因此需要尝试双向转换
        //
        // 文档 §2.15: 普通表达式的类型转换必须显式
        // 但 §6.12 明确指出：标注可以指导字面量类型（这不是隐式转换）
        if (r1.isNumericType() and r2.isNumericType()) {
            // 检查是否可以按§6.12标注指导进行类型转换
            // 尝试 r2 → r1
            if (canCoerceNumeric(r1, r2)) {
                return r1; // 返回标注类型
            }
            // 尝试 r1 → r2（对称情况）
            if (canCoerceNumeric(r2, r1)) {
                return r2; // 返回更宽的类型
            }
            // 不可转换，必须显式转换
            return error.TypeMismatch;
        }
        // Try auto-widening for nullable/throw
        switch (r1.*) {
            .nullable_type => |inner1| {
                switch (r2.*) {
                    .nullable_type => |inner2| {
                        // Both nullable - check if inner types can coerce
                        // 支持数值类型提升：i32? vs i8?
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
                        // () is compatible with T? (e.g., function body is all throws)
                        return r1;
                    },
                    else => {
                        // t1 is T?, t2 is non-nullable → try unify inner with t2
                        // 支持数值类型提升：val n1: i32? = 42 (i8 → i32)
                        if (inferencer.unify(inner1, r2)) |_| {
                            return r1;
                        } else |_| {
                            // 如果直接unify失败，尝试数值类型提升
                            const inner1_resolved = inferencer.resolve(inner1);
                            const r2_resolved = inferencer.resolve(r2);
                            if (inner1_resolved.isNumericType() and r2_resolved.isNumericType()) {
                                if (canCoerceNumeric(inner1_resolved, r2_resolved)) {
                                    return r1; // 允许提升，返回 T?
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
                        // Both are Throw types - check if value types can coerce
                        // 支持数值类型提升：Throw<i32, E> vs Throw<i8, E>
                        const v1 = inferencer.resolve(tt1.value_type);
                        const v2 = inferencer.resolve(tt2.value_type);

                        // Error types must match
                        inferencer.unify(tt1.error_type, tt2.error_type) catch return error.TypeMismatch;

                        // Try to unify value types with numeric coercion
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
                        // () is compatible with Throw<T, E> (function body is all throws)
                        return r1;
                    },
                    else => {
                        // t1 is Throw<T, E>, t2 is T → try unify value_type with t2
                        // 支持数值类型提升：fun f(): Throw<i32, E> { 42 } (i8 → i32)
                        if (inferencer.unify(tt1.value_type, r2)) |_| {
                            return r1;
                        } else |_| {
                            // 如果直接unify失败，尝试数值类型提升
                            const value_ty_resolved = inferencer.resolve(tt1.value_type);
                            const r2_resolved = inferencer.resolve(r2);
                            if (value_ty_resolved.isNumericType() and r2_resolved.isNumericType()) {
                                if (canCoerceNumeric(value_ty_resolved, r2_resolved)) {
                                    return r1; // 允许提升，返回 Throw<T, E>
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
                        // t1 is non-nullable, t2 is T? → try unify t1 with inner
                        inferencer.unify(r1, inner2) catch return error.TypeMismatch;
                        return r2; // Return T?
                    },
                    .throw_type => |tt2| {
                        // t1 is non-nullable, t2 is Throw<T', E> → try unify t1 with T'
                        inferencer.unify(r1, tt2.value_type) catch return error.TypeMismatch;
                        return r2; // Return Throw<T', E>
                    },
                    else => return error.TypeMismatch,
                }
            },
        }
    }
}

/// ? 传播操作符的类型检查
///
/// 文档 2.3.9: ? 操作符严格按类型匹配，不跨 Nullable/Throw
/// - T? 上的 ? → 外层函数必须返回 U?
/// - Throw<T, E> 上的 ? → 外层函数必须返回 Throw<U, E'>
/// - 非 Nullable/Throw 类型上使用 ? → 编译错误
///
/// 参数:
///   inferencer: 类型推断器（用于 resolve 和 addErrorAt）
///   resolved_inner: 已解析的内部表达式类型
///   inner_ty: 未解析的内部表达式类型（用于 else 分支返回）
///   fn_return_type: 外层函数的返回类型（可能为 null）
///   location: ? 操作符的源码位置（用于错误报告）
///
/// 返回: ? 操作符的结果类型
pub fn checkPropagate(
    inferencer: *TypeInferencer,
    resolved_inner: *Type,
    inner_ty: *Type,
    fn_return_type: ?*Type,
    location: ast.SourceLocation,
) *Type {
    switch (resolved_inner.*) {
        .nullable_type => |inner| {
            // T? 上的 ? → 外层函数必须返回 U?
            if (fn_return_type) |fn_ret| {
                const resolved_ret = inferencer.resolve(fn_ret);
                switch (resolved_ret.*) {
                    .nullable_type => {
                        // ✅ 外层返回 U?，兼容
                    },
                    else => {
                        // ❌ 在非 Nullable 返回函数中对 T? 用 ?
                        inferencer.addErrorAt(.propagate_cross_type, location.line, location.column, "propagation operator '?' on T? requires enclosing function to return U?, but return type is non-nullable", .{});
                    },
                }
            } else {
                // 无返回类型注解，无法验证
            }
            return inner;
        },
        .throw_type => |tt| {
            // Throw<T, E_inner> 上的 ? → 外层函数必须返回 Throw<U, E_outer>
            if (fn_return_type) |fn_ret| {
                const resolved_ret = inferencer.resolve(fn_ret);
                switch (resolved_ret.*) {
                    .throw_type => {
                        // ✅ 外层返回 Throw<U, E_outer>，兼容
                        // 文档要求 E_inner <: E_outer，Phase 2 简化：仅检查外层是 Throw
                    },
                    else => {
                        // ❌ 在非 Throw 返回函数中对 Throw 用 ?
                        inferencer.addErrorAt(.propagate_cross_type, location.line, location.column, "propagation operator '?' on Throw<T, E> requires enclosing function to return Throw<U, E'>, but return type is non-throw", .{});
                    },
                }
            }
            return tt.value_type;
        },
        else => {
            // ? 作用于非 T? 非 Throw<T,E> 的类型
            // 文档 2.3.9: 在普通函数中使用 ? → 编译错误
            if (fn_return_type) |fn_ret| {
                const resolved_ret = inferencer.resolve(fn_ret);
                switch (resolved_ret.*) {
                    .nullable_type, .throw_type => {
                        // 外层期望 Nullable/Throw 但表达式不是
                        inferencer.addErrorAt(.propagate_cross_type, location.line, location.column, "propagation operator '?' cannot be used on a non-nullable, non-throw expression", .{});
                    },
                    else => {
                        // 普通函数中对普通值用 ? — 也报错
                        inferencer.addErrorAt(.propagate_cross_type, location.line, location.column, "propagation operator '?' cannot be used on a non-nullable, non-throw expression", .{});
                    },
                }
            }
            return inner_ty;
        },
    }
}
