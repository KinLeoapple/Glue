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
    /// 类型描述符池引用（用于 allocNullable 创建具名 nullable<T> 描述符）
    pool: ?*type_descriptor_mod.TypeDescriptorPool = null,

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

    /// 分配带 inner_type_desc 的通道（用于 Lazy<T>/Channel<T> 等容器，type_desc 为 ref，
    /// inner_type_desc 记录元素类型 T，供 emitLazyForce/recv 等查询）
    pub fn allocWithInner(self: *ChannelSpace, type_desc: *const type_descriptor_mod.TypeDescriptor, inner_type_desc: ?*const type_descriptor_mod.TypeDescriptor) !u16 {
        return self.allocInner(type_desc, inner_type_desc, false);
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
    /// pool 路径创建具名 nullable<T> 描述符（含专属 scalar_ops vtable），
    /// 同时通过 allocInner 保留 inner_type_desc 在 ChannelMeta 中，
    /// 供 IR 编译器（compileElvis/compileSafeAccess 等）查询内部类型。
    pub fn allocNullable(self: *ChannelSpace, inner_type_desc: *const type_descriptor_mod.TypeDescriptor) !u16 {
        if (self.pool) |pool| {
            const nullable_td = try pool.getOrCreateNullableDesc(inner_type_desc);
            return self.allocInner(nullable_td, inner_type_desc, false);
        }
        return self.allocInner(type_descriptor_mod.nullable_descriptor, inner_type_desc, false);
    }

    fn allocInner(self: *ChannelSpace, type_desc: *const type_descriptor_mod.TypeDescriptor, inner_type_desc: ?*const type_descriptor_mod.TypeDescriptor, is_cell: bool) !u16 {
        const idx: u16 = @intCast(self.metas.items.len);
        // nullable 通道宽度：优先用 type_desc.size（具名 nullable<T> 描述符已含 inner.size+1），
        // 回退路径（nullable_descriptor + inner_type_desc）需要手动计算
        const elem_w: u8 = if (type_desc.isNullable() and inner_type_desc != null) blk: {
            const inner = inner_type_desc.?;
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
