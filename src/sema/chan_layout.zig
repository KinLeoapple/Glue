//! 通道布局推导
//!
//! v3 spec §5.3: 为每个单态化实例推导 ChanLayout。
//! 职责：根据通道类型列表，计算每通道在帧标量区的偏移和总字节需求。
//!
//! 迁自 builder.zig:743 computeFunctionChannelLayout 的核心算法：
//! - 16 字节对齐（SIMD 友好）
//! - elem_width=0 的通道不占空间（null/unit/nullable_chan）
//! - local_offsets 长度 = local_chan_count + 1（含 return_channel 在末尾）

const std = @import("std");
const ir_mod = @import("ir");
const type_descriptor_mod = @import("type_descriptor.zig");

const TypeDescriptor = type_descriptor_mod.TypeDescriptor;
const ChanLayout = @import("sema_output.zig").ChanLayout;

/// 为通道类型列表推导布局
///
/// 算法（迁自 builder.zig:743 computeFunctionChannelLayout）：
/// 1. 遍历所有通道类型描述符
/// 2. 取 elem_width = type_desc.size
/// 3. 宽度为 0 → 偏移 = current_offset，不前进
/// 4. 宽度非 0 → current_offset = alignForward(current_offset, 16)，写入 offsets[i]，current_offset += w
/// 5. chan_total_bytes = alignForward(current_offset, 16)
///
/// 参数：
/// - allocator: 用于分配 local_offsets 和 chan_type_descs
/// - chan_type_descs: 通道类型描述符列表（local_chan_count + 1 个，末尾为 return_channel）
/// - return_channel_idx: return_channel 在 chan_type_descs 中的索引（通常是 chan_type_descs.len - 1）
///
/// 返回：ChanLayout { local_chan_count, return_channel, local_offsets, chan_type_descs, chan_total_bytes }
pub fn deriveChanLayout(
    allocator: std.mem.Allocator,
    chan_type_descs: []const *const TypeDescriptor,
    return_channel_idx: u16,
) !ChanLayout {
    const chan_count: u16 = @intCast(chan_type_descs.len);
    const local_chan_count: u16 = chan_count - 1;

    // 计算偏移
    const offsets = try allocator.alloc(u32, chan_count);
    var current_offset: usize = 0;

    for (chan_type_descs, 0..) |td, i| {
        const w: usize = td.size;
        if (w == 0) {
            // null/unit/nullable_chan 不占空间
            offsets[i] = @intCast(current_offset);
            continue;
        }
        current_offset = std.mem.alignForward(usize, current_offset, 16);
        offsets[i] = @intCast(current_offset);
        current_offset += w;
    }

    const chan_total_bytes: u32 = @intCast(std.mem.alignForward(usize, current_offset, 16));

    return ChanLayout{
        .local_chan_count = local_chan_count,
        .return_channel = return_channel_idx,
        .local_offsets = offsets,
        .chan_type_descs = chan_type_descs,
        .chan_total_bytes = chan_total_bytes,
    };
}

/// 便捷方法：从 ChanType 列表推导布局
/// 适用于 IRBuilder 已有 ChannelSpace 通道元信息的场景
pub fn deriveChanLayoutFromMetas(
    allocator: std.mem.Allocator,
    elem_widths: []const u8,
    return_channel_idx: u16,
) !ChanLayout {
    const chan_count: u16 = @intCast(elem_widths.len);
    const local_chan_count: u16 = chan_count - 1;

    const offsets = try allocator.alloc(u32, chan_count);
    var current_offset: usize = 0;

    for (elem_widths, 0..) |w, i| {
        if (w == 0) {
            offsets[i] = @intCast(current_offset);
            continue;
        }
        current_offset = std.mem.alignForward(usize, current_offset, 16);
        offsets[i] = @intCast(current_offset);
        current_offset += w;
    }

    const chan_total_bytes: u32 = @intCast(std.mem.alignForward(usize, current_offset, 16));

    // chan_type_descs 暂用空切片（IRBuilder 路径不使用）
    const chan_type_descs = try allocator.alloc(*const TypeDescriptor, 0);

    return ChanLayout{
        .local_chan_count = local_chan_count,
        .return_channel = return_channel_idx,
        .local_offsets = offsets,
        .chan_type_descs = chan_type_descs,
        .chan_total_bytes = chan_total_bytes,
    };
}
