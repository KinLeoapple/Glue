//! 从 AST 填充 SemaResult 的类型/函数/Trait 定义表
//!
//! v3 spec §5.1 Task 3.13: 迁自 builder.zig:1302 populateSemaResultFromAst。
//! 职责：遍历模块声明，将 AST 的 type_decl/fun_decl/trait_decl 转换为
//! SemaResult 的 TypeDefInfo/FuncSigInfo/TraitDefInfo 并注册。

const std = @import("std");
const ast = @import("ast");
const ir_mod = @import("ir");
const type_resolver = @import("type_resolver.zig");

const sema_output = @import("sema_output.zig");
const SemaResult = sema_output.SemaResult;
const ChanType = ir_mod.ChanType;
const TypeDefInfo = sema_output.TypeDefInfo;
const TypeDefKind = sema_output.TypeDefKind;
const CtorDefInfo = sema_output.CtorDefInfo;
const FuncSigInfo = sema_output.FuncSigInfo;
const TraitDefInfo = sema_output.TraitDefInfo;
const TraitMethodSig = sema_output.TraitMethodSig;
const TypeDescriptor = ir_mod.TypeDescriptor;

/// 从 AST 填充 SemaResult 的类型/函数/Trait 定义表
///
/// 迁自 builder.zig:1302 populateSemaResultFromAst
/// 已注册的同名定义会被覆盖（AST 为权威来源，sema 阶段保证无重复声明）。
pub fn populateSemaResultFromAst(
    sema_result: *SemaResult,
    module: ast.Module,
    arena_alloc: std.mem.Allocator,
) !void {
    for (module.declarations) |decl| {
        switch (decl) {
            .type_decl => |td| try astTypeDeclToTypeDef(sema_result, td, arena_alloc),
            .fun_decl => |fd| try astFunDeclToFuncSig(sema_result, fd, arena_alloc),
            .trait_decl => |trd| try astTraitDeclToTraitDef(sema_result, trd, arena_alloc),
            else => {},
        }
    }
}

/// 将 AST fun_decl 转换为 FuncSigInfo 并注册到 sema_result
/// 迁自 builder.zig:1324 astFunDeclToFuncSig
fn astFunDeclToFuncSig(
    sema_result: *SemaResult,
    fd: anytype,
    arena_alloc: std.mem.Allocator,
) !void {
    const type_params = try arena_alloc.alloc([]const u8, fd.type_params.len);
    for (fd.type_params, 0..) |tp, i| type_params[i] = tp.name;

    const param_chan_types = try arena_alloc.alloc(ChanType, fd.params.len);
    const param_is_ref = try arena_alloc.alloc(bool, fd.params.len);
    for (fd.params, 0..) |p, i| {
        param_chan_types[i] = type_resolver.resolveChanType(p.type_annotation, &.{}) orelse .ref_chan;
        param_is_ref[i] = if (p.type_annotation) |ta| ta.* == .ref_type else false;
    }

    const return_chan_type = type_resolver.resolveChanType(fd.return_type, &.{}) orelse .i64_chan;
    const is_throwing = isThrowType(fd.return_type);

    try sema_result.putFuncSig(.{
        .name = fd.name,
        .type_params = type_params,
        .param_chan_types = param_chan_types,
        .return_chan_type = return_chan_type,
        .param_is_ref = param_is_ref,
        .is_async = fd.is_async,
        .is_throwing = is_throwing,
    });
}

/// 将 AST trait_decl 转换为 TraitDefInfo 并注册到 sema_result
/// 迁自 builder.zig:1347 astTraitDeclToTraitDef
fn astTraitDeclToTraitDef(
    sema_result: *SemaResult,
    trd: anytype,
    arena_alloc: std.mem.Allocator,
) !void {
    const methods = try arena_alloc.alloc(TraitMethodSig, trd.methods.len);
    for (trd.methods, 0..) |m, i| {
        const return_chan_type = type_resolver.resolveChanType(m.return_type, &.{}) orelse .i64_chan;
        methods[i] = .{
            .name = m.name,
            .param_count = @intCast(m.params.len),
            .return_chan_type = return_chan_type,
            .has_body = m.body != null,
        };
    }
    try sema_result.putTraitDef(.{
        .name = trd.name,
        .methods = methods,
    });
}

/// 将 AST type_decl 转换为 TypeDefInfo 并注册到 sema_result
/// 迁自 builder.zig:1365 astTypeDeclToTypeDef
fn astTypeDeclToTypeDef(
    sema_result: *SemaResult,
    td: anytype,
    arena_alloc: std.mem.Allocator,
) !void {
    const type_params = try arena_alloc.alloc([]const u8, td.type_params.len);
    for (td.type_params, 0..) |tp, i| type_params[i] = tp.name;

    switch (td.def) {
        .adt => |adt| {
            const ctors = try arena_alloc.alloc(CtorDefInfo, adt.constructors.len);
            for (adt.constructors, 0..) |cdef, ci| {
                const field_names = try arena_alloc.alloc(?[]const u8, cdef.fields.len);
                const field_chan_types = try arena_alloc.alloc(ChanType, cdef.fields.len);
                const field_type_names = try arena_alloc.alloc(?[]const u8, cdef.fields.len);
                for (cdef.fields, 0..) |cf, fi| {
                    field_names[fi] = cf.name;
                    field_chan_types[fi] = type_resolver.resolveChanType(cf.ty, &.{}) orelse .ref_chan;
                    field_type_names[fi] = typeNameFromTypeNodeConst(cf.ty);
                }
                ctors[ci] = .{
                    .name = cdef.name,
                    .type_name = td.name,
                    .field_names = field_names,
                    .field_chan_types = field_chan_types,
                    .field_type_names = field_type_names,
                    .return_type_name = null,
                };
            }
            try sema_result.putTypeDef(.{
                .name = td.name,
                .kind = .adt,
                .constructors = ctors,
                .type_params = type_params,
            });
        },
        .record => |r| {
            const field_names = try arena_alloc.alloc(?[]const u8, r.fields.len);
            const field_chan_types = try arena_alloc.alloc(ChanType, r.fields.len);
            const field_type_names = try arena_alloc.alloc(?[]const u8, r.fields.len);
            for (r.fields, 0..) |f, fi| {
                field_names[fi] = f.name;
                field_chan_types[fi] = type_resolver.resolveChanType(f.ty, &.{}) orelse .ref_chan;
                field_type_names[fi] = typeNameFromTypeNodeConst(f.ty);
            }
            const ctors = try arena_alloc.alloc(CtorDefInfo, 1);
            ctors[0] = .{
                .name = td.name,
                .type_name = td.name,
                .field_names = field_names,
                .field_chan_types = field_chan_types,
                .field_type_names = field_type_names,
            };
            try sema_result.putTypeDef(.{
                .name = td.name,
                .kind = .record,
                .constructors = ctors,
                .type_params = type_params,
            });
        },
        .alias => |a| {
            try sema_result.putTypeDef(.{
                .name = td.name,
                .kind = .alias,
                .constructors = &[_]CtorDefInfo{},
                .type_params = type_params,
                .target_type_name = typeNameFromTypeNodeConst(a.target),
                .target_chan_type = type_resolver.resolveChanType(a.target, &.{}),
            });
        },
        .newtype => |nt| {
            const field_chan_types = try arena_alloc.alloc(ChanType, 1);
            const field_type_names = try arena_alloc.alloc(?[]const u8, 1);
            const field_names = try arena_alloc.alloc(?[]const u8, 1);
            field_chan_types[0] = type_resolver.resolveChanType(nt.inner, &.{}) orelse .ref_chan;
            field_type_names[0] = typeNameFromTypeNodeConst(nt.inner);
            field_names[0] = "_0";
            const ctors = try arena_alloc.alloc(CtorDefInfo, 1);
            ctors[0] = .{
                .name = td.name,
                .type_name = td.name,
                .field_names = field_names,
                .field_chan_types = field_chan_types,
                .field_type_names = field_type_names,
                .is_newtype = true,
            };
            try sema_result.putTypeDef(.{
                .name = td.name,
                .kind = .newtype,
                .constructors = ctors,
                .type_params = type_params,
            });
        },
        .error_newtype => |en| {
            const field_names = try arena_alloc.alloc(?[]const u8, en.params.len);
            const field_chan_types = try arena_alloc.alloc(ChanType, en.params.len);
            const field_type_names = try arena_alloc.alloc(?[]const u8, en.params.len);
            for (en.params, 0..) |p, pi| {
                field_names[pi] = p.name;
                field_chan_types[pi] = type_resolver.resolveChanType(p.type_annotation, &.{}) orelse .ref_chan;
                field_type_names[pi] = if (p.type_annotation) |tn| typeNameFromTypeNodeConst(tn) else null;
            }
            const ctors = try arena_alloc.alloc(CtorDefInfo, 1);
            ctors[0] = .{
                .name = en.name,
                .type_name = td.name,
                .field_names = field_names,
                .field_chan_types = field_chan_types,
                .field_type_names = field_type_names,
            };
            try sema_result.putTypeDef(.{
                .name = td.name,
                .kind = .error_newtype,
                .constructors = ctors,
                .type_params = type_params,
            });
        },
    }
}

// ════════════════════════════════════════════════════════════
// 辅助函数（迁自 builder.zig）
// ════════════════════════════════════════════════════════════

/// 判断类型节点是否为 Throw<T, E>
/// 迁自 builder.zig:10233 isThrowType
fn isThrowType(type_node: ?*const ast.TypeNode) bool {
    const tn = type_node orelse return false;
    return switch (tn.*) {
        .generic => |g| std.mem.eql(u8, g.name, "Throw"),
        else => false,
    };
}

/// 从 TypeNode 提取类型名（不分配，用于快速查表）
/// 迁自 builder.zig:10320 typeNameFromTypeNodeConst
/// 包装类型（nullable/ref_type/raw_ptr/kind_annotated）递归取内部名，
/// 复杂类型（function/record/array）返回 "?"。
fn typeNameFromTypeNodeConst(type_node: *const ast.TypeNode) []const u8 {
    return switch (type_node.*) {
        .named => |n| n.name,
        .self_type => "Self",
        .generic => |g| g.name,
        .nullable => |nb| typeNameFromTypeNodeConst(nb.inner),
        .ref_type => |rb| typeNameFromTypeNodeConst(rb.inner),
        .raw_ptr => |rb| typeNameFromTypeNodeConst(rb.inner),
        .kind_annotated => |kb| typeNameFromTypeNodeConst(kb.inner),
        else => "?",
    };
}

// ════════════════════════════════════════════════════════════
// 编译期分析强制引用 + 冒烟测试
// ════════════════════════════════════════════════════════════

/// 强制编译器分析所有函数（Zig 默认懒分析）
const _force_analysis = blk: {
    _ = populateSemaResultFromAst;
    _ = astFunDeclToFuncSig;
    _ = astTraitDeclToTraitDef;
    _ = astTypeDeclToTypeDef;
    _ = isThrowType;
    _ = typeNameFromTypeNodeConst;
    break :blk {};
};

test "populate: 空模块冒烟测试" {
    var sr = SemaResult.init(std.testing.allocator);
    defer sr.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = ast.Module{
        .name = "test",
        .source_path = null,
        .declarations = &.{},
    };

    try populateSemaResultFromAst(&sr, module, arena.allocator());

    // 空模块不应注册任何定义
    try std.testing.expectEqual(@as(usize, 0), sr.type_defs.items.len);
    try std.testing.expectEqual(@as(usize, 0), sr.func_sigs.items.len);
    try std.testing.expectEqual(@as(usize, 0), sr.trait_defs.items.len);
}
