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

    pub fn init(allocator: std.mem.Allocator) SemaResult {
        return .{
            .allocator = allocator,
            .expr_types = std.AutoHashMap(u64, ExprInfo).init(allocator),
            .errors = .empty,
        };
    }

    pub fn deinit(self: *SemaResult) void {
        self.expr_types.deinit();
        self.errors.deinit(self.allocator);
    }

    /// 记录表达式类型
    pub fn putExpr(self: *SemaResult, expr_id: u64, info: ExprInfo) !void {
        try self.expr_types.put(expr_id, info);
    }

    /// 查询表达式类型
    pub fn getExpr(self: *const SemaResult, expr_id: u64) ?ExprInfo {
        return self.expr_types.get(expr_id);
    }

    /// 记录错误
    pub fn addError(self: *SemaResult, err: SemaError) !void {
        self.has_error = true;
        try self.errors.append(self.allocator, err);
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
