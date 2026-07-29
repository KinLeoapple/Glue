//! GADT（广义代数数据类型）模式精化模块。
//!
//! 当 match 表达式 scrutinee 的类型属于 GADT 时，本模块负责在构造器模式
//! 匹配过程中将构造器的返回类型与期望类型进行 unify，从而让类型变量获得
//! 更具体的类型信息（类型精化），使 GADT 的类型安全约束得以在语义分析阶段落实。

const std = @import("std");
const ast = @import("ast");
const type_check = @import("type_check");

pub const Type = type_check.Type;
pub const TypeEnv = type_check.TypeEnv;
pub const TypeInferencer = type_check.TypeInferencer;

/// 对构造器模式进行类型精化。
///
/// 实例化构造器方案，将其返回类型与 `expected_ty` 统一，并对子模式
/// 依次按对应字段类型继续推断，最终返回 true 表示已由本函数处理。
/// 若构造器未在环境中注册，返回 false 交由常规模式推断处理。
/// 适用于 GADT、普通 ADT 和内置类型（如 Throw 的 Ok/Error）构造器。
///
/// 通用 Throw 虚拟构造器处理：当 expected_ty 是 throw_type 时，
/// error_newtype ADT 构造器（如 Error/CastError/IOError）自动作为
/// Throw 的错误分支构造器，子模式绑定到 error_type。
/// 判断依据：构造器返回类型是 error_newtype ADT 且 expected_ty 是 throw_type。
/// 不依赖具体构造器名字。
pub fn refineConstructorPattern(
    inferencer: *TypeInferencer,
    con: @TypeOf(@as(ast.Pattern, undefined).constructor),
    expected_ty: *Type,
    env: *TypeEnv,
) bool {
    const resolved_expected = inferencer.resolve(expected_ty);
    // 通用 Throw 错误构造器处理：expected_ty 是 throw_type 时，
    // 检查构造器是否是 error_newtype ADT 构造器（通过 env.lookup 的返回类型判断）。
    // 如果是，子模式绑定到 throw_type.error_type，使 err.message() 等方法分派生效。
    if (resolved_expected.* == .throw_type) {
        if (env.lookup(con.name)) |scheme| {
            const inst = inferencer.freshenType(scheme) catch return false;
            const resolved = inferencer.resolve(inst);
            if (resolved.* == .fn_type) {
                const ret_resolved = inferencer.resolve(resolved.fn_type.return_type);
                if (ret_resolved.* == .adt_type) {
                    if (inferencer.adt_types.get(ret_resolved.adt_type.name)) |adt_info| {
                        if (adt_info.is_error_newtype) {
                            // 构造器是 error_newtype ADT，作为 Throw 错误分支构造器
                            // 子模式绑定到 error_type（整个 ADT 类型，而非字段类型）
                            if (con.patterns.len > 0) {
                                inferencer.inferPattern(con.patterns[0], resolved_expected.throw_type.error_type, env) catch {};
                            }
                            return true;
                        }
                    }
                }
            }
        }
    }
    const scheme = env.lookup(con.name) orelse return false;
    const inst = inferencer.freshenType(scheme) catch return false;
    const resolved = inferencer.resolve(inst);

    switch (resolved.*) {
        .fn_type => |ft| {
            // 将构造器返回类型与期望类型统一，实现 GADT 类型精化
            inferencer.unify(ft.return_type, expected_ty) catch {};
            for (con.patterns, 0..) |sub_pat, i| {
                const field_ty = if (i < ft.params.len) ft.params[i] else (inferencer.freshTypeVar() catch return true);
                inferencer.inferPattern(sub_pat, field_ty, env) catch {};
            }
            return true;
        },
        else => {
            // 非函数类型（零参构造器）直接与期望类型统一
            inferencer.unify(resolved, expected_ty) catch {};
            for (con.patterns) |sub_pat| {
                const fresh = inferencer.freshTypeVar() catch return true;
                inferencer.inferPattern(sub_pat, fresh, env) catch {};
            }
            return true;
        },
    }
}

/// 判断给定构造器名是否属于某个被标记为 GADT 的 ADT。
fn constructorBelongsToGadt(inferencer: *TypeInferencer, ctor_name: []const u8) bool {
    var it = inferencer.adt_types.valueIterator();
    while (it.next()) |info| {
        if (!info.is_gadt) continue;
        for (info.constructor_names) |cn| {
            if (std.mem.eql(u8, cn, ctor_name)) return true;
        }
    }
    return false;
}
