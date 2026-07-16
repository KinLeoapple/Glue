//! Glue IR 打印器
//!
//! 将 GlueIR 结构格式化为可读文本，用于调试和验证。
//! Phase 1：基础打印（节点流 + 通道 + 函数表）

const std = @import("std");
const ir_mod = @import("ir.zig");
const node_mod = @import("node.zig");

pub const GlueIR = ir_mod.GlueIR;
pub const Node = node_mod.Node;
pub const NodeOp = node_mod.NodeOp;

/// 将 IR 打印到 ArrayList 缓冲区
pub fn printIR(ir: *const GlueIR, allocator: std.mem.Allocator, buf: *std.ArrayList(u8)) !void {
    try buf.print(allocator, "=== Glue IR ===\n", .{});
    try buf.print(allocator, "节点数: {d}\n", .{ir.nodes.len});
    try buf.print(allocator, "通道数: {d}\n", .{ir.channels.count()});
    try buf.print(allocator, "函数数: {d}\n", .{ir.functions.len});
    try buf.print(allocator, "入口函数: {d}\n\n", .{ir.entry_index});

    // 打印通道
    try buf.appendSlice(allocator, "--- 通道空间 ---\n");
    for (ir.channels.metas.items, 0..) |meta, i| {
        try buf.print(allocator, "  ch{d}: type={s} width={d}", .{
            i,
            @tagName(meta.chan_type),
            meta.elem_width,
        });
        if (meta.is_cell) try buf.appendSlice(allocator, " [cell]");
        if (meta.chan_type == .nullable_chan) {
            try buf.print(allocator, " inner={s}", .{@tagName(meta.inner_type)});
        }
        try buf.appendSlice(allocator, "\n");
    }

    // 打印节点流
    try buf.appendSlice(allocator, "\n--- 节点流 ---\n");
    for (ir.nodes, 0..) |node, i| {
        try buf.print(allocator, "  N{d}: {s}", .{ i, @tagName(node.op) });
        if (node.input_count > 0) {
            try buf.appendSlice(allocator, " inputs=[");
            var j: u8 = 0;
            while (j < node.input_count) : (j += 1) {
                if (j > 0) try buf.appendSlice(allocator, ",");
                try buf.print(allocator, "ch{d}", .{node.inputs[j]});
            }
            try buf.appendSlice(allocator, "]");
        }
        try buf.print(allocator, " -> ch{d}", .{node.output});
        if (node.meta_index > 0) {
            try buf.print(allocator, " meta={d}", .{node.meta_index});
        }
        try buf.appendSlice(allocator, "\n");
    }

    // 打印函数表
    if (ir.functions.len > 0) {
        try buf.appendSlice(allocator, "\n--- 函数表 ---\n");
        for (ir.functions, 0..) |func, i| {
            try buf.print(allocator, "  func[{d}]: {s} nodes=[{d}..{d}) params={d} ret=ch{d}", .{
                i,
                func.name,
                func.node_start,
                func.node_start + func.node_count,
                func.param_channels.len,
                func.return_channel,
            });
            if (func.is_entry) try buf.appendSlice(allocator, " [entry]");
            if (func.is_async) try buf.appendSlice(allocator, " [async]");
            try buf.appendSlice(allocator, "\n");
        }
    }

    // 打印标量元数据表
    if (ir.scalar_metas.len > 0) {
        try buf.appendSlice(allocator, "\n--- 标量元数据 ---\n");
        for (ir.scalar_metas, 0..) |meta, i| {
            try buf.print(allocator, "  meta[{d}]: kind={s}", .{ i, @tagName(meta.kind) });
            switch (meta.kind) {
                .int => try buf.print(allocator, " int_kind={s}", .{@tagName(meta.int_kind)}),
                .float => try buf.print(allocator, " float_kind={s}", .{@tagName(meta.float_kind)}),
                else => {},
            }
            if (meta.const_val) |cv| {
                switch (cv) {
                    .int_val => |v| try buf.print(allocator, " const={d}", .{v}),
                    .float_val => |v| try buf.print(allocator, " const_bits=0x{x}", .{v}),
                    .bool_val => |v| try buf.print(allocator, " const={}", .{v}),
                    .char_val => |v| try buf.print(allocator, " const='\\u{{{x}}}'", .{v}),
                }
            }
            try buf.appendSlice(allocator, "\n");
        }
    }

    // 打印向量元数据表
    if (ir.vector_metas.len > 0) {
        try buf.appendSlice(allocator, "\n--- 向量元数据 ---\n");
        for (ir.vector_metas, 0..) |meta, i| {
            try buf.print(allocator, "  vmeta[{d}]: vec_op={s} inner_op={s} elem_type={s}", .{
                i,
                @tagName(meta.vec_op),
                @tagName(meta.inner_op),
                @tagName(meta.elem_type),
            });
            if (meta.length) |len| {
                try buf.print(allocator, " length={d}", .{len});
            }
            if (meta.body_len > 0) {
                try buf.print(allocator, " body=[{d}..{d})", .{
                    meta.body_start,
                    meta.body_start + meta.body_len,
                });
            }
            try buf.appendSlice(allocator, "\n");
        }
    }

    // 打印门控元数据表
    if (ir.gate_metas.len > 0) {
        try buf.appendSlice(allocator, "\n--- 门控元数据 ---\n");
        for (ir.gate_metas, 0..) |meta, i| {
            try buf.print(allocator, "  gmeta[{d}]: kind={s} error_type={d}", .{
                i,
                @tagName(meta.gate_kind),
                meta.error_type,
            });
            if (meta.gate_kind == .propagate) {
                try buf.print(allocator, " from=ch{d}", .{meta.propagate_from});
            }
            try buf.appendSlice(allocator, "\n");
        }
    }

    // 打印路由元数据表
    if (ir.route_metas.len > 0) {
        try buf.appendSlice(allocator, "\n--- 路由元数据 ---\n");
        for (ir.route_metas, 0..) |meta, i| {
            try buf.print(allocator, "  rmeta[{d}]: trait={d} method={d} targets={d}", .{
                i,
                meta.trait_id,
                meta.method_id,
                meta.target_count,
            });
            try buf.appendSlice(allocator, "\n");
        }
    }

    // 打印竞争元数据表
    if (ir.race_metas.len > 0) {
        try buf.appendSlice(allocator, "\n--- 竞争元数据 ---\n");
        for (ir.race_metas, 0..) |meta, i| {
            try buf.print(allocator, "  racemeta[{d}]: sources={d}", .{
                i,
                meta.source_count,
            });
            if (meta.timeout_ms) |ms| {
                try buf.print(allocator, " timeout={d}ms", .{ms});
            }
            try buf.appendSlice(allocator, "\n");
        }
    }

    // 打印清理元数据表
    if (ir.cleanup_metas.len > 0) {
        try buf.appendSlice(allocator, "\n--- 清理元数据 ---\n");
        for (ir.cleanup_metas, 0..) |meta, i| {
            try buf.print(allocator, "  cmeta[{d}]: trigger={s} body=[{d}..{d}) order={d}\n", .{
                i,
                @tagName(meta.trigger),
                meta.body_start,
                meta.body_start + meta.body_len,
                meta.order,
            });
        }
    }

    // 打印星轨元数据表
    if (ir.orbit_metas.len > 0) {
        try buf.appendSlice(allocator, "\n--- 星轨元数据 ---\n");
        for (ir.orbit_metas, 0..) |meta, i| {
            try buf.print(allocator, "  ometa[{d}]: func={d} args={d} result={s}", .{
                i,
                meta.func_index,
                meta.arg_count,
                @tagName(meta.result_type),
            });
            if (meta.is_spawn) {
                try buf.appendSlice(allocator, " [spawn]");
            }
            try buf.appendSlice(allocator, "\n");
        }
    }
}

/// 将 IR 打印为字符串（调用方负责释放）
pub fn irToString(allocator: std.mem.Allocator, ir: *const GlueIR) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try printIR(ir, allocator, &buf);
    return buf.toOwnedSlice(allocator);
}

// ════════════════════════════════════════════════════════════════
// 测试
// ════════════════════════════════════════════════════════════════

const testing = std.testing;
const channel_mod = @import("channel.zig");
const meta_mod = @import("meta.zig");

test "printIR 基本输出" {
    var cs = channel_mod.ChannelSpace.init(testing.allocator);
    _ = try cs.alloc(.i64_chan);
    _ = try cs.alloc(.i64_chan);

    const nodes = [_]Node{
        Node.makeSink(.const_i, 0, 1),
        Node.makeBinary(.int_add, 1, 0, 0, 0),
        Node.makeUnary(.halt_return, 0, 0, 1),
    };
    const metas = [_]meta_mod.ScalarMeta{
        .{ .kind = .int, .int_kind = .i64, .const_val = .{ .int_val = 42 } },
    };

    var ir = GlueIR{
        .nodes = @constCast(&nodes),
        .scalar_metas = @constCast(&metas),
        .channels = cs,
        .backing = testing.allocator,
    };
    defer ir.channels.deinit();

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    try printIR(&ir, testing.allocator, &buf);

    try testing.expect(buf.items.len > 0);
    // 验证关键内容存在
    try testing.expect(std.mem.indexOf(u8, buf.items, "Glue IR") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "const_i") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "int_add") != null);
}
