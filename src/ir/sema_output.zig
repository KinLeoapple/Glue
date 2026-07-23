//! SemaResult：sema 的图构建元信息输出
//!
//! sema 从"检查器"升级为"图构建驱动器"，输出不再是"检查通过/失败"，
//! 而是图构建所需的全部元信息。设计参考：docs/glue-ir-design.md 第 4.2 节
//!
//! Phase 1：定义结构骨架，图构建器暂自行做简单类型推导（从字面量/运算符推导通道类型）。
//! 后续 Phase：sema 完成完整类型分析后填充此结构，图构建器从中读取类型/分派信息。

const std = @import("std");
const channel_mod = @import("channel.zig");
const meta_mod = @import("meta.zig");

pub const ChanType = channel_mod.ChanType;
pub const ConstVal = meta_mod.ConstVal;

/// 单个表达式的语义信息
pub const ExprInfo = struct {
    /// 表达式的通道类型（决定通道宽度）
    chan_type: ChanType,
    /// Nullable 内部类型（chan_type == .nullable_chan 时有效）
    inner_type: ChanType = .null_chan,
    /// 编译期常量值（若表达式是常量）
    const_val: ?ConstVal = null,
    /// 表达式的 AST 指针地址（用作 key）
    expr_id: u64 = 0,
    /// 表达式的类型名（若类型是 adt_type/generic_type，用于 IRBuilder 的 field_id 查找）
    /// 解决 method_call 返回值等场景下 inferTypeNameFromExpr 无法从 AST 回溯类型名的问题
    type_name: ?[]const u8 = null,
    /// true 表示表达式类型为 &T / *T，运行时应对 ref_chan 保持引用语义而不深拷贝
    is_ref_type: bool = false,
    /// 区分 &T(false) 与 *T(true)；仅 is_ref_type=true 时有效
    is_raw_ref: bool = false,
    /// 泛型实参的类型名列表（仅 generic_type 的方法调用/构造器调用有效）
    type_args: ?[]const []const u8 = null,
    /// 函数签名（仅对 callee 表达式有效，用于调用点推断返回类型）
    fn_sig: ?FnSigRef = null,
};

/// 类型定义种类
pub const TypeDefKind = enum {
    adt,
    record,
    alias,
    newtype,
    error_newtype,
};

/// 构造器定义信息（压平后的 sema AdtInfo 构造器）
pub const CtorDefInfo = struct {
    name: []const u8,
    type_name: []const u8,
    field_names: []const ?[]const u8,
    field_chan_types: []const ChanType,
    field_type_names: []const ?[]const u8,
    is_newtype: bool = false,
    /// GADT 构造器返回类型名（仅 GADT 有效）
    return_type_name: ?[]const u8 = null,
};

/// 类型定义信息（替代 IRBuilder 的 type_table + ctor_table）
pub const TypeDefInfo = struct {
    name: []const u8,
    kind: TypeDefKind,
    /// adt/newtype/error_newtype：构造器列表
    /// record：constructors[0] 存字段（name == type_name）
    /// alias：空切片
    constructors: []const CtorDefInfo,
    type_params: []const []const u8,
    /// 仅 alias/newtype：目标类型名
    target_type_name: ?[]const u8 = null,
    /// 仅 alias/newtype：目标通道类型
    target_chan_type: ?ChanType = null,
};

/// Trait 方法签名（压平后的 sema TraitInfo 方法）
pub const TraitMethodSig = struct {
    name: []const u8,
    param_count: u8,
    return_chan_type: ChanType,
    is_async: bool = false,
    /// 是否有 default 实现体（IRBuilder 据此决定是否从 AST 取 body）
    has_body: bool,
};

/// Trait 定义信息（替代 IRBuilder 的 trait_table 签名部分）
pub const TraitDefInfo = struct {
    name: []const u8,
    methods: []const TraitMethodSig,
};

/// 函数签名引用（嵌入 ExprInfo，仅对 callee 表达式有效）
pub const FnSigRef = struct {
    param_types: []const ChanType,
    return_type: ChanType,
    is_async: bool = false,
    is_throwing: bool = false,
};

/// 函数签名信息（替代 IRBuilder 的 func_generic_info）
pub const FuncSigInfo = struct {
    /// 函数名或 mangled 名（TypeName.method）
    name: []const u8,
    type_params: []const []const u8,
    param_chan_types: []const ChanType,
    return_chan_type: ChanType,
    /// 每个参数是否为 &T 引用语义
    param_is_ref: []const bool,
    return_is_ref: bool = false,
    is_async: bool = false,
    is_throwing: bool = false,
};

/// Import 别名目标（区分模块引用和符号引用）
pub const AliasTarget = union(enum) {
    /// 模块短名 → 完整模块路径
    /// import std.time.Calendar → "Calendar" → .{ .module = "std.time.Calendar" }
    /// import std.time { Calendar } → "Calendar" → .{ .module = "std.time.Calendar" }
    /// 类型即模块：import std.time.DateTime → "DateTime" → .{ .module = "std.time.DateTime" }
    module: []const u8,
    /// 函数/常量短名 → mangled 名
    /// import std.time.Calendar { is_leap_year } → "is_leap_year" → .{ .symbol = "std.time.Calendar.is_leap_year" }
    /// import std.time.Calendar { is_leap_year as ily } → "ily" → .{ .symbol = "std.time.Calendar.is_leap_year" }
    symbol: []const u8,
};

/// sema 产出的图构建元信息
///
/// Phase 1 仅定义结构，图构建器暂不依赖此结构。
/// 后续 Phase 由 sema 填充，图构建器读取。
pub const SemaResult = struct {
    allocator: std.mem.Allocator,
    /// 表达式 → 类型信息（决定通道宽度）
    /// key = AST 表达式指针地址，value = ExprInfo
    expr_types: std.AutoHashMap(u64, ExprInfo),
    /// 编译期错误
    errors: std.ArrayList(SemaError),
    /// 是否有错误
    has_error: bool = false,
    /// 类型定义表（替代 IRBuilder 的 type_table + ctor_table）
    type_defs: std.ArrayList(TypeDefInfo),
    /// 类型名 → type_defs 索引
    type_def_index: std.StringHashMap(u16),
    /// Trait 定义表（替代 IRBuilder 的 trait_table 签名部分）
    trait_defs: std.ArrayList(TraitDefInfo),
    /// Trait 名 → trait_defs 索引
    trait_def_index: std.StringHashMap(u16),
    /// 函数签名表（替代 IRBuilder 的 func_generic_info）
    func_sigs: std.ArrayList(FuncSigInfo),
    /// 函数名 → func_sigs 索引
    func_sig_index: std.StringHashMap(u16),
    /// 构造器名 → (type_def_index << 16 | ctor_index)
    ctor_def_index: std.StringHashMap(u32),
    /// import 别名表：短名 → 别名目标
    /// 由 sema 阶段的 buildImportAliases 填充，IRBuilder 读取后构建 module_alias_map 和 symbol_alias_map
    import_aliases: std.StringHashMap(AliasTarget),
    /// 从 TypeInferencer 转移而来的 arena 所有权。
    /// sema_result 中的 type_name / field_chan_types / constructors 等切片
    /// 引用了 inferencer arena 分配的 Type 结构体内存，因此 arena 必须与
    /// sema_result 同生命周期。inferencer.deinit() 时若 sema_result 非空，
    /// 将 arena 所有权转移至此字段，由 sema_result.deinit() 统一释放。
    owned_arena: ?std.heap.ArenaAllocator = null,

    pub fn init(allocator: std.mem.Allocator) SemaResult {
        return .{
            .allocator = allocator,
            .expr_types = std.AutoHashMap(u64, ExprInfo).init(allocator),
            .errors = .empty,
            .type_defs = .empty,
            .type_def_index = std.StringHashMap(u16).init(allocator),
            .trait_defs = .empty,
            .trait_def_index = std.StringHashMap(u16).init(allocator),
            .func_sigs = .empty,
            .func_sig_index = std.StringHashMap(u16).init(allocator),
            .ctor_def_index = std.StringHashMap(u32).init(allocator),
            .import_aliases = std.StringHashMap(AliasTarget).init(allocator),
        };
    }

    pub fn deinit(self: *SemaResult) void {
        self.expr_types.deinit();
        self.errors.deinit(self.allocator);
        self.type_defs.deinit(self.allocator);
        self.type_def_index.deinit();
        self.trait_defs.deinit(self.allocator);
        self.trait_def_index.deinit();
        self.func_sigs.deinit(self.allocator);
        self.func_sig_index.deinit();
        self.ctor_def_index.deinit();
        self.import_aliases.deinit();
        if (self.owned_arena) |*arena| {
            arena.deinit();
            self.owned_arena = null;
        }
    }

    /// 记录表达式类型
    pub fn putExpr(self: *SemaResult, expr_id: u64, info: ExprInfo) !void {
        try self.expr_types.put(expr_id, info);
    }

    /// 查询表达式类型
    pub fn getExpr(self: *const SemaResult, expr_id: u64) ?ExprInfo {
        return self.expr_types.get(expr_id);
    }

    /// 注册 import 别名（检测重复）
    pub fn putImportAlias(self: *SemaResult, short_name: []const u8, target: AliasTarget) !void {
        if (self.import_aliases.contains(short_name)) {
            return error.DuplicateImportAlias;
        }
        try self.import_aliases.put(short_name, target);
    }

    /// 查询 import 别名
    pub fn getImportAlias(self: *const SemaResult, short_name: []const u8) ?AliasTarget {
        return self.import_aliases.get(short_name);
    }

    /// 记录错误
    pub fn addError(self: *SemaResult, err: SemaError) !void {
        self.has_error = true;
        try self.errors.append(self.allocator, err);
    }

    /// 添加类型定义并注册 type_def_index 和 ctor_def_index
    pub fn putTypeDef(self: *SemaResult, def: TypeDefInfo) !void {
        const idx: u16 = @intCast(self.type_defs.items.len);
        try self.type_defs.append(self.allocator, def);
        try self.type_def_index.put(def.name, idx);
        for (def.constructors, 0..) |ctor, ci| {
            const packed_idx: u32 = (@as(u32, idx) << 16) | @as(u32, @intCast(ci));
            try self.ctor_def_index.put(ctor.name, packed_idx);
        }
    }

    /// 按名查询类型定义
    pub fn getTypeDef(self: *const SemaResult, name: []const u8) ?TypeDefInfo {
        const idx = self.type_def_index.get(name) orelse return null;
        return self.type_defs.items[idx];
    }

    /// 按构造器名查询构造器定义
    pub fn getCtorDef(self: *const SemaResult, name: []const u8) ?CtorDefInfo {
        const packed_idx = self.ctor_def_index.get(name) orelse return null;
        const type_idx: u16 = @intCast(packed_idx >> 16);
        const ctor_idx: u16 = @intCast(packed_idx & 0xFFFF);
        const def = self.type_defs.items[type_idx];
        return def.constructors[ctor_idx];
    }

    /// 添加 trait 定义并注册索引
    pub fn putTraitDef(self: *SemaResult, def: TraitDefInfo) !void {
        const idx: u16 = @intCast(self.trait_defs.items.len);
        try self.trait_defs.append(self.allocator, def);
        try self.trait_def_index.put(def.name, idx);
    }

    /// 按名查询 trait 定义
    pub fn getTraitDef(self: *const SemaResult, name: []const u8) ?TraitDefInfo {
        const idx = self.trait_def_index.get(name) orelse return null;
        return self.trait_defs.items[idx];
    }

    /// 添加函数签名并注册索引
    pub fn putFuncSig(self: *SemaResult, sig: FuncSigInfo) !void {
        const idx: u16 = @intCast(self.func_sigs.items.len);
        try self.func_sigs.append(self.allocator, sig);
        try self.func_sig_index.put(sig.name, idx);
    }

    /// 按名查询函数签名
    pub fn getFuncSig(self: *const SemaResult, name: []const u8) ?FuncSigInfo {
        const idx = self.func_sig_index.get(name) orelse return null;
        return self.func_sigs.items[idx];
    }
};

/// 语义错误
pub const SemaError = struct {
    message: []const u8,
    line: u32 = 0,
    column: u32 = 0,
};

// ════════════════════════════════════════════════════════════════
// 测试
// ════════════════════════════════════════════════════════════════

const testing = std.testing;

test "SemaResult 基本操作" {
    var sr = SemaResult.init(testing.allocator);
    defer sr.deinit();

    try testing.expect(!sr.has_error);
    try testing.expectEqual(@as(usize, 0), sr.expr_types.count());

    try sr.putExpr(0x1000, .{ .chan_type = .i64_chan });
    try sr.putExpr(0x2000, .{ .chan_type = .f64_chan });

    try testing.expectEqual(@as(usize, 2), sr.expr_types.count());
    try testing.expectEqual(ChanType.i64_chan, sr.getExpr(0x1000).?.chan_type);
    try testing.expectEqual(ChanType.f64_chan, sr.getExpr(0x2000).?.chan_type);
    try testing.expect(sr.getExpr(0x3000) == null);
}

test "SemaResult 错误记录" {
    var sr = SemaResult.init(testing.allocator);
    defer sr.deinit();

    try sr.addError(.{ .message = "type mismatch", .line = 10 });
    try testing.expect(sr.has_error);
    try testing.expectEqual(@as(usize, 1), sr.errors.items.len);
    try testing.expectEqualStrings("type mismatch", sr.errors.items[0].message);
}

test "SemaResult type_defs 查询" {
    var sr = SemaResult.init(testing.allocator);
    defer sr.deinit();

    const field_names = [_]?[]const u8{ "x", "y" };
    const field_chan_types = [_]ChanType{ .i64_chan, .i64_chan };
    const field_type_names = [_]?[]const u8{ "i64", "i64" };
    const ctors = [_]CtorDefInfo{
        .{
            .name = "Point",
            .type_name = "Point",
            .field_names = &field_names,
            .field_chan_types = &field_chan_types,
            .field_type_names = &field_type_names,
        },
    };
    const type_params = [_][]const u8{};
    try sr.putTypeDef(.{
        .name = "Point",
        .kind = .record,
        .constructors = &ctors,
        .type_params = &type_params,
    });

    const def = sr.getTypeDef("Point").?;
    try testing.expectEqualStrings("Point", def.name);
    try testing.expectEqual(TypeDefKind.record, def.kind);
    try testing.expectEqual(@as(usize, 1), def.constructors.len);
    try testing.expectEqualStrings("Point", def.constructors[0].name);

    const ctor = sr.getCtorDef("Point").?;
    try testing.expectEqualStrings("Point", ctor.type_name);
    try testing.expectEqual(@as(usize, 2), ctor.field_names.len);
    try testing.expectEqualStrings("x", ctor.field_names[0].?);
    try testing.expectEqual(ChanType.i64_chan, ctor.field_chan_types[0]);

    try testing.expect(sr.getTypeDef("Missing") == null);
    try testing.expect(sr.getCtorDef("Missing") == null);
}

test "SemaResult trait_defs 查询" {
    var sr = SemaResult.init(testing.allocator);
    defer sr.deinit();

    const methods = [_]TraitMethodSig{
        .{ .name = "next", .param_count = 0, .return_chan_type = .nullable_chan, .has_body = false },
        .{ .name = "has_next", .param_count = 0, .return_chan_type = .bool_chan, .has_body = true },
    };
    try sr.putTraitDef(.{
        .name = "Iterator",
        .methods = &methods,
    });

    const def = sr.getTraitDef("Iterator").?;
    try testing.expectEqualStrings("Iterator", def.name);
    try testing.expectEqual(@as(usize, 2), def.methods.len);
    try testing.expectEqualStrings("next", def.methods[0].name);
    try testing.expectEqual(@as(u8, 0), def.methods[0].param_count);
    try testing.expectEqual(ChanType.bool_chan, def.methods[1].return_chan_type);
    try testing.expect(def.methods[1].has_body);

    try testing.expect(sr.getTraitDef("Missing") == null);
}

test "SemaResult func_sigs 查询" {
    var sr = SemaResult.init(testing.allocator);
    defer sr.deinit();

    const param_chan_types = [_]ChanType{ .i64_chan, .i64_chan };
    const param_is_ref = [_]bool{ false, false };
    const type_params = [_][]const u8{};
    try sr.putFuncSig(.{
        .name = "add",
        .type_params = &type_params,
        .param_chan_types = &param_chan_types,
        .return_chan_type = .i64_chan,
        .param_is_ref = &param_is_ref,
    });

    const sig = sr.getFuncSig("add").?;
    try testing.expectEqualStrings("add", sig.name);
    try testing.expectEqual(@as(usize, 2), sig.param_chan_types.len);
    try testing.expectEqual(ChanType.i64_chan, sig.param_chan_types[0]);
    try testing.expectEqual(ChanType.i64_chan, sig.return_chan_type);
    try testing.expect(!sig.is_async);
    try testing.expect(!sig.is_throwing);

    try testing.expect(sr.getFuncSig("missing") == null);
}
