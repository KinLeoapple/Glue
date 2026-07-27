//! Glue IR 通道空间
//!
//! 所有节点共享同一通道空间，全局通道索引，无跨图映射。
//! 通道宽度按 SIMD 寄存器对齐（i32→16B, i64→16B），ChannelRegion 64B 对齐。
//! 设计参考：docs/glue-ir-design.md 第 3.4 节、第 11.4 节
//!
//! Phase 1：通道元信息（宽度/类型）+ 通道分配器
//! 通道数据存储复用 src/mem/ChannelRegion（执行引擎阶段）

const std = @import("std");
const type_descriptor_mod = @import("type_descriptor.zig");

/// 通道元信息：描述单个通道的类型与宽度
pub const ChannelMeta = struct {
    /// 元素字节宽度（0 表示无数据通道）
    elem_width: u8,
    /// nullable 通道的内部类型（其他通道为 null）
    inner_type_desc: ?*const type_descriptor_mod.TypeDescriptor = null,
    /// 是否为 Cell 包装通道（var 变量用，支持后续赋值）
    is_cell: bool = false,
    /// 统一类型描述符：唯一类型来源（is_ref 等类型信息从 type_desc 获取）
    type_desc: *const type_descriptor_mod.TypeDescriptor = undefined,
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
    /// 全局通道数量（全局 val/var 通道，索引 [0, global_count)）
    /// 在 IR 构建完成后由 finalizeGlobalCount 填充
    global_count: u16 = 0,

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
    pub fn alloc(self: *ChannelSpace, type_desc: *const type_descriptor_mod.TypeDescriptor) !u16 {
        return self.allocInner(type_desc, null, false);
    }

    /// 分配一个引用类型通道（&T / *T）
    pub fn allocRef(self: *ChannelSpace, type_desc: *const type_descriptor_mod.TypeDescriptor) !u16 {
        return self.allocInner(type_desc, null, false);
    }

    /// 分配一个 Cell 通道（var 变量用）
    pub fn allocCell(self: *ChannelSpace, type_desc: *const type_descriptor_mod.TypeDescriptor) !u16 {
        return self.allocInner(type_desc, null, true);
    }

    /// 分配一个 Nullable 通道
    pub fn allocNullable(self: *ChannelSpace, inner_type_desc: *const type_descriptor_mod.TypeDescriptor) !u16 {
        return self.allocInner(type_descriptor_mod.nullable_descriptor, inner_type_desc, false);
    }

    fn allocInner(self: *ChannelSpace, type_desc: *const type_descriptor_mod.TypeDescriptor, inner_type_desc: ?*const type_descriptor_mod.TypeDescriptor, is_cell: bool) !u16 {
        const idx: u16 = @intCast(self.metas.items.len);
        const elem_w: u8 = if (type_desc.is_nullable) blk: {
            const inner = inner_type_desc orelse type_descriptor_mod.null_descriptor;
            break :blk inner.size + 1;
        } else type_desc.size;
        try self.metas.append(self.allocator, .{
            .elem_width = elem_w,
            .inner_type_desc = inner_type_desc,
            .is_cell = is_cell,
            .type_desc = type_desc,
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

test "ChannelSpace 分配与查询" {
    var cs = ChannelSpace.init(testing.allocator);
    defer cs.deinit();

    const ch0 = try cs.alloc(type_descriptor_mod.i64_descriptor);
    const ch1 = try cs.alloc(type_descriptor_mod.i32_descriptor);
    const ch2 = try cs.alloc(type_descriptor_mod.bool_descriptor);

    try testing.expectEqual(@as(u16, 0), ch0);
    try testing.expectEqual(@as(u16, 1), ch1);
    try testing.expectEqual(@as(u16, 2), ch2);
    try testing.expectEqual(@as(u16, 3), cs.count());

    try testing.expectEqual(type_descriptor_mod.i64_descriptor, cs.get(ch0).type_desc);
    try testing.expectEqual(@as(u8, 8), cs.get(ch0).elem_width);
    try testing.expectEqual(@as(u8, 4), cs.get(ch1).elem_width);
}

test "ChannelSpace.allocCell 与 allocNullable" {
    var cs = ChannelSpace.init(testing.allocator);
    defer cs.deinit();

    const ch = try cs.allocCell(type_descriptor_mod.i32_descriptor);
    try testing.expect(cs.get(ch).is_cell);

    const nch = try cs.allocNullable(type_descriptor_mod.i64_descriptor);
    try testing.expectEqual(type_descriptor_mod.nullable_descriptor, cs.get(nch).type_desc);
    try testing.expectEqual(type_descriptor_mod.i64_descriptor, cs.get(nch).inner_type_desc.?);
    try testing.expectEqual(@as(u8, 9), cs.get(nch).elem_width); // 8 + 1
}
