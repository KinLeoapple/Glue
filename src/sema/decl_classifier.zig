//! Decl 分类器注册表（v3 阶段 12）
//!
//! 将 selective import item 的种类分类逻辑从 type_check.zig:classifyImportItem
//! 的 4-if 链改为 per-variant classify 函数 + 注册表查询。
//!
//! 每个 AST Decl variant 对应一个 classify 函数，接收 (decl, item_name, candidate_module, candidate_symbol)
//! 返回 ?ImportItemKind（null 表示不匹配）。注册表通过 switch on decl 分派到对应函数。
//!
//! 新增 Decl variant 只需追加一个 classify 函数并在注册表中注册。

const std = @import("std");
const ast = @import("ast");

/// selective import item 的种类分类
pub const ImportItemKind = enum { function, constant, submodule, type_kind, not_found };

/// 分类上下文：携带匹配所需的名称信息
pub const ClassifyCtx = struct {
    item_name: []const u8,
    candidate_module: []const u8,
    candidate_symbol: []const u8,
};

/// fun_decl 分类：function / submodule
fn classifyFunDecl(decl: ast.Decl, ctx: ClassifyCtx) ?ImportItemKind {
    const fd = decl.fun_decl;
    // function：函数名完全匹配 candidate_symbol
    if (std.mem.eql(u8, fd.name, ctx.candidate_symbol)) return .function;
    // submodule：存在以 candidate_module + "." 开头的 mangled 函数名
    if (std.mem.startsWith(u8, fd.name, ctx.candidate_module) and
        fd.name.len > ctx.candidate_module.len and
        fd.name[ctx.candidate_module.len] == '.')
    {
        return .submodule;
    }
    return null;
}

/// expr_decl 分类：constant（val_decl.name == candidate_symbol）
fn classifyExprDecl(decl: ast.Decl, ctx: ClassifyCtx) ?ImportItemKind {
    const ed = decl.expr_decl;
    if (ed.stmt) |st| {
        switch (st.*) {
            .val_decl => |vd| {
                if (std.mem.eql(u8, vd.name, ctx.candidate_symbol)) return .constant;
            },
            else => {},
        }
    }
    return null;
}

/// type_decl 分类：type_kind（type_decl.name == item_name，原名不 mangle）
fn classifyTypeDecl(decl: ast.Decl, ctx: ClassifyCtx) ?ImportItemKind {
    const td = decl.type_decl;
    if (std.mem.eql(u8, td.name, ctx.item_name)) return .type_kind;
    return null;
}

/// 默认分类：不匹配
fn classifyDefault(decl: ast.Decl, ctx: ClassifyCtx) ?ImportItemKind {
    _ = decl;
    _ = ctx;
    return null;
}

/// 注册表：switch on Decl variant 分派到对应 classify 函数
/// 新增 Decl variant 时在此 switch 追加分支即可
fn classifyDecl(decl: ast.Decl, ctx: ClassifyCtx) ?ImportItemKind {
    return switch (decl) {
        .fun_decl => classifyFunDecl(decl, ctx),
        .expr_decl => classifyExprDecl(decl, ctx),
        .type_decl => classifyTypeDecl(decl, ctx),
        // 其他 variant（import_decl/trait_decl 等）不参与 import item 分类
        else => classifyDefault(decl, ctx),
    };
}

/// 入口：扫描 module.declarations，返回第一个匹配的 ImportItemKind
/// 未匹配返回 .not_found
pub fn classifyImportItem(
    item_name: []const u8,
    candidate_module: []const u8,
    candidate_symbol: []const u8,
    module: *const ast.Module,
) ImportItemKind {
    const ctx = ClassifyCtx{
        .item_name = item_name,
        .candidate_module = candidate_module,
        .candidate_symbol = candidate_symbol,
    };
    for (module.declarations) |decl| {
        if (classifyDecl(decl, ctx)) |kind| return kind;
    }
    return .not_found;
}
