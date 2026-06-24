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

/// 函数返回类型的 Nullable/Throw 自动提升
///
/// 当声明返回 T? 但推断为 T 时，将 T 统一到 T? 的内部类型；
/// 当声明返回 Throw<T, E> 但推断为 T 时，将 T 统一到 Throw 的 value_type。
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
                else => try inferencer.unify(inner, inferred),
            }
        },
        .throw_type => |tt| {
            // 声明返回 Throw<T, E>，推断为 T → 将 T 统一到 Throw 的 value_type
            switch (resolved_inferred.*) {
                .throw_type => try inferencer.unify(declared, inferred),
                .unit_type => {
                    // Function body is all throws/defer, return type Throw<T, E> is OK
                },
                else => try inferencer.unify(tt.value_type, inferred),
            }
        },
        else => try inferencer.unify(declared, inferred),
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
        // 文档 §2.15: 类型转换必须显式，数值类型之间无隐式转换
        // widening（低位转高位）和 narrowing（高位转低位）都需要显式 Type(value) 语法
        // 移除了自动数值类型提升逻辑，确保类型严格匹配
        if (r1.isNumericType() and r2.isNumericType()) {
            // 数值类型不匹配，必须显式转换
            return error.TypeMismatch;
        }
        // Try auto-widening for nullable/throw
        switch (r1.*) {
            .nullable_type => |inner1| {
                switch (r2.*) {
                    .nullable_type => {
                        // Both nullable but inner types don't match - propagate error
                        return error.TypeMismatch;
                    },
                    .unit_type => {
                        // () is compatible with T? (e.g., function body is all throws)
                        return r1;
                    },
                    else => {
                        // t1 is T?, t2 is non-nullable → try unify inner with t2
                        inferencer.unify(inner1, r2) catch return error.TypeMismatch;
                        return r1; // Return T?
                    },
                }
            },
            .throw_type => |tt1| {
                switch (r2.*) {
                    .throw_type => return error.TypeMismatch,
                    .unit_type => {
                        // () is compatible with Throw<T, E> (function body is all throws)
                        return r1;
                    },
                    else => {
                        // t1 is Throw<T, E>, t2 is T → try unify value_type with t2
                        inferencer.unify(tt1.value_type, r2) catch return error.TypeMismatch;
                        return r1;
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
