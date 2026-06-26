//! Kind 检查与推断
//!
//! 文档 §2.11.1: Kind 系统
//!   *            具体类型           i32, str, bool
//!   * -> *       一阶类型构造器     List, Vec, Tree, Atomic, Spawn
//!   * -> * -> *  二阶类型构造器     Map, Throw
//!
//! 以自由函数形式实现，TypeInferencer 委托过来。
//! 核心检查：类型注解中出现的类型构造器，必须按其 arity 完全应用到 `*`
//! （即"用作具体类型的地方 kind 必须是 *"）。
//!   - `C<a, b, ...>`：head C 的 arity 必须等于实参个数，且每个实参 kind 为 *
//!   - 裸 `C`（无尖括号）：若 C 是 arity>0 的构造器，则它是 `* -> ...`，
//!     用在类型位置是 kind 不匹配。

const std = @import("std");
const ast = @import("ast");
const type_check = @import("type_check");

pub const TypeInferencer = type_check.TypeInferencer;

/// 返回某个类型名作为类型构造器的 arity（需要的类型参数个数）。
/// 未知名字返回 0（当作具体类型，避免误报）。
pub fn arityOfTypeName(inferencer: *TypeInferencer, name: []const u8) usize {
    // 内建二阶构造器
    if (std.mem.eql(u8, name, "Throw")) return 2;
    // 内建一阶构造器
    if (std.mem.eql(u8, name, "Atomic") or
        std.mem.eql(u8, name, "Spawn") or
        std.mem.eql(u8, name, "Channel") or
        std.mem.eql(u8, name, "Sender") or
        std.mem.eql(u8, name, "Receiver") or
        std.mem.eql(u8, name, "Lazy"))
    {
        return 1;
    }
    // 用户 ADT / newtype：type_param_names 长度即 arity
    if (inferencer.adt_types.get(name)) |info| {
        return info.type_param_names.len;
    }
    return 0;
}

/// 检查一个类型注解节点的 kind 合法性，错误写入 inferencer.errors。
/// type_param_names：当前作用域内的类型参数名（如函数/ADT 的 <T>），
/// 这些名字是已绑定的类型变量，跳过 arity 检查。
pub fn checkTypeNode(
    inferencer: *TypeInferencer,
    node: *const ast.TypeNode,
    type_param_names: []const []const u8,
) void {
    switch (node.*) {
        .named => |n| {
            // 裸类型名用在类型位置：若是 arity>0 的构造器则 kind 不匹配
            if (isTypeParam(n.name, type_param_names)) return;
            const arity = arityOfTypeName(inferencer, n.name);
            if (arity > 0) {
                inferencer.addErrorAt(.type_mismatch, n.location.line, n.location.column, "kind mismatch: type constructor '{s}' expects {d} type argument(s) but is used as a concrete type", .{ n.name, arity });
            }
        },
        .self_type => {
            // Self 类型在方法中总是具体类型
            return;
        },
        .generic => |g| {
            // Throw/内建/用户构造器：实参个数必须等于 arity
            if (!isTypeParam(g.name, type_param_names)) {
                const arity = arityOfTypeName(inferencer, g.name);
                // arity==0 且非内建泛型：可能是未知类型（由别处报 undefined），不在此重复报 kind
                if (arity != 0 and arity != g.args.len) {
                    inferencer.addErrorAt(.type_mismatch, g.location.line, g.location.column, "kind mismatch: type constructor '{s}' expects {d} type argument(s) but got {d}", .{ g.name, arity, g.args.len });
                }
            }
            // 递归检查每个实参必须是具体类型（kind *）
            for (g.args) |arg| {
                checkTypeNode(inferencer, arg, type_param_names);
            }
        },
        .nullable => |nl| checkTypeNode(inferencer, nl.inner, type_param_names),
        .function => |f| {
            for (f.params) |p| checkTypeNode(inferencer, p, type_param_names);
            checkTypeNode(inferencer, f.return_type, type_param_names);
        },
        .record => |r| {
            for (r.fields) |fld| checkTypeNode(inferencer, fld.ty, type_param_names);
        },
        .array => |a| checkTypeNode(inferencer, a.element_type, type_param_names),
        .kind_annotated => |ka| checkTypeNode(inferencer, ka.inner, type_param_names),
    }
}

fn isTypeParam(name: []const u8, type_param_names: []const []const u8) bool {
    for (type_param_names) |tp| {
        if (std.mem.eql(u8, name, tp)) return true;
    }
    return false;
}

/// 计算一个类型注解在「类型构造器」意义上的 kind arity（剩余未应用的参数个数）。
///   i32 / List<i32>            → 0（具体类型，kind *）
///   List（裸名，arity 1）       → 1（kind * -> *）
///   Map（裸名，arity 2）        → 2
///   List<i32>（已应用 1 个）    → 0
/// 未知/类型参数名 → 0（当作具体类型，避免误报）。
pub fn kindArityOfTypeNode(inferencer: *TypeInferencer, node: *const ast.TypeNode) usize {
    switch (node.*) {
        .named => |n| return arityOfTypeName(inferencer, n.name),
        .generic => |g| {
            const head = arityOfTypeName(inferencer, g.name);
            if (g.args.len >= head) return 0;
            return head - g.args.len;
        },
        else => return 0,
    }
}

fn typeNodeLoc(node: *const ast.TypeNode) ast.SourceLocation {
    return switch (node.*) {
        .named => |n| n.location,
        .self_type => |s| s.location,
        .generic => |g| g.location,
        .nullable => |nl| typeNodeLoc(nl.inner),
        .function => |f| f.location,
        .record => |r| r.location,
        .array => |a| a.location,
        .kind_annotated => |ka| ka.location,
    };
}
