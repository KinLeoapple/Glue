//! GADT 类型细化
//!
//! 文档 §2.13: GADT 允许构造器返回不同的类型参数（IntLit : Expr<i32>）。
//! 匹配 GADT 时，编译器通过类型细化推导局部类型等式（match IntLit(n) 中 T ~ i32）。
//!
//! 以自由函数形式实现，TypeInferencer 在 inferPattern 的 .constructor 分支委托过来。
//! 核心：构造器模式匹配时
//!   1. 取构造器的 scheme（已含 GADT 返回类型，如 IntLit : i32 -> Expr<i32>），实例化；
//!   2. 把实例化后的返回类型与被匹配值的期望类型 unify —— 推导类型等式（细化）；
//!   3. 把各子模式绑定到实例化后的真实字段类型（而非 fresh 变量）。
//! 细化对 scrutinee 的 unify 用「容错」方式：GADT 各分支返回类型不同，
//! 分支间对同一 T 的约束会冲突，这是 GADT 的本质，故 unify 失败时静默
//! （由调用方 per-arm 隔离 scrutinee 类型，避免污染兄弟分支）。

const std = @import("std");
const ast = @import("ast");
const type_check = @import("type_check");

pub const Type = type_check.Type;
pub const TypeScheme = type_check.TypeScheme;
pub const TypeEnv = type_check.TypeEnv;
pub const TypeInferencer = type_check.TypeInferencer;

/// 构造器模式的类型细化 + 字段绑定。
/// 返回 true 表示已处理（找到构造器并绑定字段）；false 表示未知构造器，
/// 调用方回退到旧的「fresh 变量」行为。
pub fn refineConstructorPattern(
    inferencer: *TypeInferencer,
    con: @TypeOf(@as(ast.Pattern, undefined).constructor),
    expected_ty: *Type,
    env: *TypeEnv,
) bool {
    // 仅对 GADT 构造器做类型细化。普通 ADT 沿用调用方的 fresh-变量行为
    // （改动它会破坏 HM 对递归泛型 ADT 如 GList<T> 的推断）。
    if (!constructorBelongsToGadt(inferencer, con.name)) return false;

    const scheme = env.lookup(con.name) orelse return false;
    const inst = inferencer.instantiate(scheme) catch return false;

    const resolved = inferencer.resolve(inst);
    switch (resolved.*) {
        .fn_type => |ft| {
            // 返回类型与期望类型 unify —— GADT 类型细化（T ~ i32 等）。容错。
            inferencer.unify(ft.return_type, expected_ty) catch {};
            for (con.patterns, 0..) |sub_pat, i| {
                const field_ty = if (i < ft.params.len) ft.params[i] else (inferencer.freshTypeVar() catch return true);
                inferencer.inferPattern(sub_pat, field_ty, env) catch {};
            }
            return true;
        },
        else => {
            // 无参构造器：scheme 即返回类型，直接 unify 做细化
            inferencer.unify(resolved, expected_ty) catch {};
            for (con.patterns) |sub_pat| {
                const fresh = inferencer.freshTypeVar() catch return true;
                inferencer.inferPattern(sub_pat, fresh, env) catch {};
            }
            return true;
        },
    }
}

/// 判断构造器名是否属于某个 GADT（其所属 ADT 的 is_gadt 为 true）。
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
