//! GADT（广义代数数据类型）模式精化模块。
//!
//! 当 match 表达式 scrutinee 的类型属于 GADT 时，本模块负责在构造器模式
//! 匹配过程中将构造器的返回类型与期望类型进行 unify，从而让类型变量获得
//! 更具体的类型信息（类型精化），使 GADT 的类型安全约束得以在语义分析阶段落实。

const std = @import("std");
const ast = @import("ast");
const type_check = @import("type_check");

pub const Type = type_check.Type;
pub const TypeScheme = type_check.TypeScheme;
pub const TypeEnv = type_check.TypeEnv;
pub const TypeInferencer = type_check.TypeInferencer;

/// 对 GADT 构造器模式进行类型精化。
///
/// 若该构造器不属于任何 GADT，则返回 false 交由常规模式推断处理；
/// 否则实例化构造器方案，将其返回类型与 `expected_ty` 统一，并对子模式
/// 依次按对应字段类型继续推断，最终返回 true 表示已由本函数处理。
pub fn refineConstructorPattern(
    inferencer: *TypeInferencer,
    con: @TypeOf(@as(ast.Pattern, undefined).constructor),
    expected_ty: *Type,
    env: *TypeEnv,
) bool {
    if (!constructorBelongsToGadt(inferencer, con.name)) return false;

    const scheme = env.lookup(con.name) orelse return false;
    const inst = inferencer.instantiate(scheme) catch return false;
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
