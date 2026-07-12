//! 类型种类（kind）检查模块。
//!
//! 负责在语义分析阶段校验类型注解中类型构造器的使用是否与其种类（arity）一致，
//! 例如 `Throw` 期望 2 个类型参数、`Atomic` 期望 1 个，而自定义 ADT 按其声明
//! 的类型参数个数决定。当类型构造器被当作具体类型使用或参数个数不符时报告错误。

const std = @import("std");
const ast = @import("ast");
const type_check = @import("type_check");

pub const TypeInferencer = type_check.TypeInferencer;

/// 返回类型名为 `name` 的类型构造器所期望的类型参数个数（种类 arity）。
/// 内建高阶类型（Throw/Atomic/Spawn 等）使用固定 arity，自定义 ADT 取其声明的
/// 类型参数个数，其余裸类型名 arity 为 0。
pub fn arityOfTypeName(inferencer: *TypeInferencer, name: []const u8) usize {
    if (std.mem.eql(u8, name, "Throw")) return 2;
    if (std.mem.eql(u8, name, "Atomic") or
        std.mem.eql(u8, name, "Spawn") or
        std.mem.eql(u8, name, "Channel") or
        std.mem.eql(u8, name, "Sender") or
        std.mem.eql(u8, name, "Receiver") or
        std.mem.eql(u8, name, "Lazy"))
    {
        return 1;
    }
    if (inferencer.adt_types.get(name)) |info| {
        return info.type_param_names.len;
    }
    return 0;
}

/// 递归检查类型节点树中每个类型构造器的使用是否符合其种类 arity。
/// `type_param_names` 给出当前作用域内合法的类型参数名（它们可作具体类型使用）。
pub fn checkTypeNode(
    inferencer: *TypeInferencer,
    node: *const ast.TypeNode,
    type_param_names: []const []const u8,
) void {
    switch (node.*) {
        .named => |n| {
            // 类型参数名可直接作为具体类型使用，无需校验
            if (isTypeParam(n.name, type_param_names)) return;
            const arity = arityOfTypeName(inferencer, n.name);
            if (arity > 0) {
                inferencer.addErrorAt(.type_mismatch, n.location.line, n.location.column, "kind mismatch: type constructor '{s}' expects {d} type argument(s) but is used as a concrete type", .{ n.name, arity });
            }
        },
        .self_type => {
            return;
        },
        .generic => |g| {
            if (!isTypeParam(g.name, type_param_names)) {
                const arity = arityOfTypeName(inferencer, g.name);
                if (arity != 0 and arity != g.args.len) {
                    inferencer.addErrorAt(.type_mismatch, g.location.line, g.location.column, "kind mismatch: type constructor '{s}' expects {d} type argument(s) but got {d}", .{ g.name, arity, g.args.len });
                }
            }
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

/// 判断 `name` 是否为当前作用域内的类型参数。
fn isTypeParam(name: []const u8, type_param_names: []const []const u8) bool {
    for (type_param_names) |tp| {
        if (std.mem.eql(u8, name, tp)) return true;
    }
    return false;
}

/// 计算类型节点剩余的种类 arity：即还差多少个类型参数才能成为具体类型。
/// 裸类型名返回其 arity；部分应用的高阶类型返回 (arity - 已提供参数数)。
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
