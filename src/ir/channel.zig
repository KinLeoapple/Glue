//! Glue IR 通道空间
//!
//! 所有节点共享同一通道空间，全局通道索引，无跨图映射。
//! 通道宽度按 SIMD 寄存器对齐（i32→16B, i64→16B），ChannelRegion 64B 对齐。
//! 设计参考：docs/glue-ir-design.md 第 3.4 节、第 11.4 节
//!
//! Phase 1：通道元信息（宽度/类型）+ 通道分配器
//! 通道数据存储复用 src/mem/ChannelRegion（执行引擎阶段）

const std = @import("std");
const scalar = @import("value").scalar;

/// 通道类型：决定通道的数据宽度与存储方式
///
/// 复用 value.scalar 的 IntKind/FloatKind，避免重复定义。
pub const ChanType = enum(u5) {
    // 整数（10 种）
    i8_chan, i16_chan, i32_chan, i64_chan, i128_chan,
    u8_chan, u16_chan, u32_chan, u64_chan, u128_chan,
    // 浮点（4 种）
    f16_chan, f32_chan, f64_chan, f128_chan,
    // 其他标量
    bool_chan, char_chan, null_chan, unit_chan,
    // 堆引用与谓词
    ref_chan, mask_chan,
    // Nullable<T>
    nullable_chan,

    /// 通道类型 → 元素字节宽度
    pub fn elemWidth(self: ChanType) u8 {
        return switch (self) {
            .null_chan, .unit_chan, .nullable_chan => 0,
            .i8_chan, .u8_chan, .bool_chan, .mask_chan => 1,
            .i16_chan, .u16_chan, .f16_chan => 2,
            .i32_chan, .u32_chan, .f32_chan, .char_chan => 4,
            .i64_chan, .u64_chan, .f64_chan, .ref_chan => 8,
            .i128_chan, .u128_chan, .f128_chan => 16,
        };
    }

    /// 是否为整数通道
    pub fn isInt(self: ChanType) bool {
        return switch (self) {
            .i8_chan, .i16_chan, .i32_chan, .i64_chan, .i128_chan,
            .u8_chan, .u16_chan, .u32_chan, .u64_chan, .u128_chan => true,
            else => false,
        };
    }

    /// 是否为浮点通道
    pub fn isFloat(self: ChanType) bool {
        return switch (self) {
            .f16_chan, .f32_chan, .f64_chan, .f128_chan => true,
            else => false,
        };
    }

    /// IntKind → ChanType
    pub fn fromIntKind(kind: scalar.IntKind) ChanType {
        return switch (kind) {
            .i8 => .i8_chan, .i16 => .i16_chan, .i32 => .i32_chan, .i64 => .i64_chan, .i128 => .i128_chan,
            .u8 => .u8_chan, .u16 => .u16_chan, .u32 => .u32_chan, .u64 => .u64_chan, .u128 => .u128_chan,
        };
    }

    /// FloatKind → ChanType
    pub fn fromFloatKind(kind: scalar.FloatKind) ChanType {
        return switch (kind) {
            .f16 => .f16_chan, .f32 => .f32_chan, .f64 => .f64_chan, .f128 => .f128_chan,
        };
    }

    /// ChanType → IntKind（非整数通道返回 null）
    pub fn toIntKind(self: ChanType) ?scalar.IntKind {
        return switch (self) {
            .i8_chan => .i8, .i16_chan => .i16, .i32_chan => .i32, .i64_chan => .i64, .i128_chan => .i128,
            .u8_chan => .u8, .u16_chan => .u16, .u32_chan => .u32, .u64_chan => .u64, .u128_chan => .u128,
            else => null,
        };
    }

    /// ChanType → FloatKind（非浮点通道返回 null）
    pub fn toFloatKind(self: ChanType) ?scalar.FloatKind {
        return switch (self) {
            .f16_chan => .f16, .f32_chan => .f32, .f64_chan => .f64, .f128_chan => .f128,
            else => null,
        };
    }
};

/// Nullable<T> 通道元素字节宽度 = inner_width + 1（1 byte null 标志）
pub inline fn nullableElemWidth(inner: ChanType) u8 {
    return inner.elemWidth() + 1;
}

/// 通道元信息：描述单个通道的类型与宽度
pub const ChannelMeta = struct {
    chan_type: ChanType,
    elem_width: u8, // 元素字节宽度（0 表示无数据通道）
    /// nullable_chan 时的内部类型（其他通道为 .null_chan）
    inner_type: ChanType = .null_chan,
    /// 是否为 Cell 包装通道（var 变量用，支持后续赋值）
    is_cell: bool = false,
};

/// 通道空间：管理全局通道索引的分配
///
/// Phase 1 仅管理元信息（类型/宽度），实际数据存储在执行引擎阶段由 ChannelRegion 提供。
/// 通道索引从 0 开始连续递增，所有节点共享同一空间。
pub const ChannelSpace = struct {
    metas: std.ArrayList(ChannelMeta),
    allocator: std.mem.Allocator,
    /// 入口通道数量（函数参数等，索引 [0, input_count)）
    input_count: u16 = 0,

    pub fn init(allocator: std.mem.Allocator) ChannelSpace {
        return .{
            .metas = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ChannelSpace) void {
        self.metas.deinit(self.allocator);
    }

    /// 分配一个新通道，返回其全局索引
    pub fn alloc(self: *ChannelSpace, chan_type: ChanType) !u16 {
        return self.allocInner(chan_type, .null_chan, false);
    }

    /// 分配一个 Cell 通道（var 变量用）
    pub fn allocCell(self: *ChannelSpace, chan_type: ChanType) !u16 {
        return self.allocInner(chan_type, .null_chan, true);
    }

    /// 分配一个 Nullable 通道
    pub fn allocNullable(self: *ChannelSpace, inner_type: ChanType) !u16 {
        return self.allocInner(.nullable_chan, inner_type, false);
    }

    fn allocInner(self: *ChannelSpace, chan_type: ChanType, inner_type: ChanType, is_cell: bool) !u16 {
        const idx: u16 = @intCast(self.metas.items.len);
        const elem_w = if (chan_type == .nullable_chan) nullableElemWidth(inner_type) else chan_type.elemWidth();
        try self.metas.append(self.allocator, .{
            .chan_type = chan_type,
            .elem_width = elem_w,
            .inner_type = inner_type,
            .is_cell = is_cell,
        });
        return idx;
    }

    /// 获取通道元信息
    pub fn get(self: *const ChannelSpace, idx: u16) ChannelMeta {
        return self.metas.items[idx];
    }

    /// 当前通道总数
    pub fn count(self: *const ChannelSpace) u16 {
        return @intCast(self.metas.items.len);
    }

    /// 标记前 N 个通道为输入通道（函数参数）
    pub fn markInputs(self: *ChannelSpace, n: u16) void {
        self.input_count = n;
    }
};

// ════════════════════════════════════════════════════════════════
// 测试
// ════════════════════════════════════════════════════════════════

const testing = std.testing;

test "ChanType.elemWidth" {
    try testing.expectEqual(@as(u8, 1), ChanType.i8_chan.elemWidth());
    try testing.expectEqual(@as(u8, 4), ChanType.i32_chan.elemWidth());
    try testing.expectEqual(@as(u8, 8), ChanType.i64_chan.elemWidth());
    try testing.expectEqual(@as(u8, 16), ChanType.i128_chan.elemWidth());
    try testing.expectEqual(@as(u8, 0), ChanType.unit_chan.elemWidth());
}

test "ChanType.isInt/isFloat" {
    try testing.expect(ChanType.i32_chan.isInt());
    try testing.expect(!ChanType.f32_chan.isInt());
    try testing.expect(ChanType.f64_chan.isFloat());
    try testing.expect(!ChanType.bool_chan.isFloat());
}

test "ChanType.fromIntKind/toIntKind 往返" {
    try testing.expectEqual(ChanType.i32_chan, ChanType.fromIntKind(.i32));
    try testing.expectEqual(scalar.IntKind.u64, ChanType.u64_chan.toIntKind().?);
    try testing.expect(ChanType.bool_chan.toIntKind() == null);
}

test "ChannelSpace 分配与查询" {
    var cs = ChannelSpace.init(testing.allocator);
    defer cs.deinit();

    const ch0 = try cs.alloc(.i64_chan);
    const ch1 = try cs.alloc(.i32_chan);
    const ch2 = try cs.alloc(.bool_chan);

    try testing.expectEqual(@as(u16, 0), ch0);
    try testing.expectEqual(@as(u16, 1), ch1);
    try testing.expectEqual(@as(u16, 2), ch2);
    try testing.expectEqual(@as(u16, 3), cs.count());

    try testing.expectEqual(ChanType.i64_chan, cs.get(ch0).chan_type);
    try testing.expectEqual(@as(u8, 8), cs.get(ch0).elem_width);
    try testing.expectEqual(@as(u8, 4), cs.get(ch1).elem_width);
}

test "ChannelSpace.allocCell 与 allocNullable" {
    var cs = ChannelSpace.init(testing.allocator);
    defer cs.deinit();

    const ch = try cs.allocCell(.i32_chan);
    try testing.expect(cs.get(ch).is_cell);

    const nch = try cs.allocNullable(.i64_chan);
    try testing.expectEqual(ChanType.nullable_chan, cs.get(nch).chan_type);
    try testing.expectEqual(ChanType.i64_chan, cs.get(nch).inner_type);
    try testing.expectEqual(@as(u8, 9), cs.get(nch).elem_width); // 8 + 1
}
