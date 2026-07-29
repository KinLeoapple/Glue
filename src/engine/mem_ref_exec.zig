//! 内存/引用/Newtype 执行函数（v3 阶段 5.3：从 engine.zig 物理拆分）
//!
//! 包含 execLoad / execStore / execRefOf / execRefGet / execRefSet /
//! valueToRawPtr / execNewtypeWrap / execNewtypeUnwrap 等执行函数。
//!
//! 拆分模式：pub const Methods = struct { pub fn ... }，
//! engine.zig 通过 pub const 别名注入 Engine 结构体。

const std = @import("std");
const ir_mod = @import("ir");
const value = @import("value");

const engine_mod = @import("engine.zig");
const Engine = engine_mod.Engine;
const EngineError = engine_mod.EngineError;

const Node = ir_mod.Node;

pub const Methods = struct {
    // ════════════════════════════════════════════
    // Newtype 执行
    // ════════════════════════════════════════════

    /// newtype_wrap：将值包装为 NewtypeValue
    /// inputs[0] = 值通道
    /// meta_index 指向 ScalarMeta（const_val.int_val 存储类型名字符串池索引）
    /// output = ref_chan（NewtypeValue 指针）
    pub fn execNewtypeWrap(self: *Engine, node: *const Node) EngineError!void {
        const val_chan = node.inputs[0];
        const inner = self.chanToValue(val_chan);
        _ = inner.retain(self.tctx.?);

        // 从 meta 获取类型名
        var type_name: []const u8 = "Newtype";
        if (node.meta_index > 0 and node.meta_index <= self.ir.scalar_metas.len) {
            const meta = self.ir.scalar_metas[node.meta_index];
            if (meta.const_val) |cv| {
                if (cv == .int_val) {
                    const str_idx: usize = @intCast(cv.int_val);
                    if (str_idx < self.ir.string_pool.len) {
                        type_name = self.ir.string_pool[str_idx];
                    }
                }
            }
        }

        const nt_v = value.Value.makeNewtype(self.tctx.?, type_name, inner) catch return error.OutOfMemory;
        try self.trackObj(nt_v.asRef());
        _ = self.runtime.writeChannel(node.output, value.Value.fromRef(@ptrCast(nt_v.asRef())));
    }

    /// newtype_unwrap：从 NewtypeValue 提取内部值
    /// inputs[0] = ref_chan（NewtypeValue 指针）
    /// output = 内部值通道
    pub fn execNewtypeUnwrap(self: *Engine, node: *const Node) EngineError!void {
        const ref_chan = node.inputs[0];
        const v = self.runtime.readChannel(ref_chan) orelse return error.Panic;
        if (v != .ref) return error.Panic;
        const header = v.ref;
        if (header.type_tag != .newtype) return error.Panic;
        const nt: *value.NewtypeValue = @alignCast(@fieldParentPtr("header", header));
        self.writeScalarValue(node.output, nt.inner);
    }

    // ════════════════════════════════════════════
    // 内存操作（var 变量 load/store）
    // ════════════════════════════════════════════

    /// load：将输入通道的值复制到输出通道（var 初始化）
    /// node._pad bit 0 为 1 表示源为 &T / *T，保持引用语义；否则普通复合类型走深拷贝
    pub fn execLoad(self: *Engine, node: *const Node) EngineError!void {
        const src_chan = node.inputs[0];
        const is_ref = (node._pad & 1) != 0;
        try self.cloneValueBetweenChannels(node.output, src_chan, is_ref);
    }

    /// store：将输入通道的值写入 cell 通道（var 赋值）
    /// node._pad bit 0 为 1 表示源为 &T / *T，保持引用语义；否则普通复合类型走深拷贝
    pub fn execStore(self: *Engine, node: *const Node) EngineError!void {
        const src_chan = node.inputs[0];
        const is_ref = (node._pad & 1) != 0;
        try self.cloneValueBetweenChannels(node.output, src_chan, is_ref);
    }

    // ════════════════════════════════════════════
    // 借用引用（&T / *expr / ref_get / ref_set）
    // ════════════════════════════════════════════

    /// ref_of：取引用 &expr
    /// - 复合类型（operand 是 ref_chan）：operand 已持有 *ObjHeader，直接复制指针到 output
    /// - 标量（operand 是标量通道）：装箱为 Cell，写入 Cell 指针到 ref_chan
    ///   （废除 tagged scalar ref 后，标量引用统一通过 Cell 装箱实现回写语义）
    /// - unit 类型：ref 无意义，写 null
    pub fn execRefOf(self: *Engine, node: *const Node) EngineError!void {
        const src_chan = node.inputs[0];
        const src_w = self.runtime.elemWidth(src_chan);
        const dst = self.runtime.rawPtr(node.output);

        if (self.runtime.isRef(src_chan)) {
            // ref_chan（复合对象/已有引用）：src 通道持有 8 字节指针，直接复制
            const src = self.runtime.rawPtr(src_chan);
            @memcpy(dst[0..8], src[0..8]);
            // retain 引用计数（仅对真实堆对象，标量位模式跳过）
            const obj_ptr: ?*anyopaque = @ptrCast(@alignCast(@as(*?*anyopaque, @ptrCast(@alignCast(src))).*));
            if (obj_ptr) |p| {
                const addr = @intFromPtr(p);
                // 过滤内核空间地址（高位置 1，含负 i64 符号扩展），防止标量位模式误判为堆指针
                if (addr >= 0x1000 and addr < 0x8000000000000000 and addr % @alignOf(value.obj_header.ObjHeader) == 0) {
                    // 使用 msync 安全检查页面是否映射，避免对标量位模式调用 isValidHeapObj 导致段错误
                    if (ir_mod.type_descriptor_mod.isReadable(addr)) {
                        const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(p));
                        if (header.isValidHeapObj()) {
                            _ = value.obj_header.retain(header, self.tctx.?);
                        }
                    }
                }
            }
        } else if (src_w > 0 and src_w <= 16) {
            // 标量：装箱为 Cell，写入 Cell 指针（实现可回写的引用语义）
            const inner = self.chanToValue(src_chan);
            _ = inner.retain(self.tctx.?);
            const cell_v = value.Value.makeCell(self.tctx.?, inner) catch return error.OutOfMemory;
            try self.trackObj(cell_v.asRef());
            _ = self.runtime.writeChannel(node.output, value.Value.fromRef(@ptrCast(cell_v.asRef())));
        } else if (src_w == 0) {
            // unit 类型：ref 无意义，写 null
            const dst_ptr: *?*anyopaque = @ptrCast(@alignCast(dst));
            dst_ptr.* = null;
        }
    }

    /// ref_get：解引用 *expr
    /// 读取引用指向的值到 output 通道
    /// - Cell：提取 inner 值写入 output（标量引用解箱）
    /// - 复合对象：直接复制对象指针（result 是 ref_chan）
    /// - null/标量位模式：error.Panic
    pub fn execRefGet(self: *Engine, node: *const Node) EngineError!void {
        const ref_chan = node.inputs[0];
        const dst_w = self.runtime.elemWidth(node.output);
        if (dst_w == 0) return;

        // 通过 vtable 读取 ref_chan 值（ref_ops.read 返回 ref/null/i64）
        const v = self.chanToValue(ref_chan);
        const dst = self.runtime.rawPtr(node.output);

        switch (v) {
            .ref => |header| {
                if (header.type_tag == .cell) {
                    // Cell：提取 inner 值写入 output（标量引用解箱）
                    const cell: *value.Cell = @alignCast(@fieldParentPtr("header", header));
                    self.writeScalarValue(node.output, cell.inner);
                    return;
                }
                // 复合对象：复制对象指针本身（ref_get 对复合对象 = 取对象引用）
                if (dst_w == 8) {
                    const dst_ptr: *?*anyopaque = @ptrCast(@alignCast(dst));
                    dst_ptr.* = @ptrCast(header);
                    _ = value.obj_header.retain(header, self.tctx.?);
                }
            },
            .null_val => return error.Panic, // 解引用 null
            else => {
                // ref_chan 持有标量位模式（泛型 T = 标量，未走 ref_of 路径）
                self.writeScalarValue(node.output, v);
            },
        }
    }

    /// ref_set：通过引用写入 *ref = value
    /// inputs[0] = 引用通道，inputs[1] = 值通道
    /// - Cell：更新 inner 值（实现标量引用回写）
    /// - 复合对象：无操作（复合对象赋值通过 field assignment 完成）
    /// - null/标量位模式：error.Panic
    pub fn execRefSet(self: *Engine, node: *const Node) EngineError!void {
        const ref_chan = node.inputs[0];
        const val_chan = node.inputs[1];

        // 通过 vtable 读取 ref_chan 值
        const v = self.chanToValue(ref_chan);

        switch (v) {
            .ref => |header| {
                if (header.type_tag == .cell) {
                    // Cell：更新 inner 值（实现回写）
                    const cell: *value.Cell = @alignCast(@fieldParentPtr("header", header));
                    // 先 retain 新值（防止 self-assignment 时旧值被释放）
                    const new_val = self.chanToValue(val_chan);
                    _ = new_val.retain(self.tctx.?);
                    // release 旧值
                    cell.inner.release(self.tctx.?);
                    cell.inner = new_val;
                    return;
                }
                // 复合对象的 ref_set：替换引用本身（暂不实现，通过 field assignment 完成）
            },
            else => return error.Panic, // null 或标量位模式，无法 ref_set
        }
    }

    // ════════════════════════════════════════════
    // 辅助函数
    // ════════════════════════════════════════════

    /// 将 Value 写入原始字节指针（用于向量元素写入）
    pub fn valueToRawPtr(self: *Engine, ptr: [*]u8, w: u8, v: value.Value) void {
        _ = self;
        switch (v) {
            .null_val, .unit => {},
            .boolean => |b| {
                if (w >= 1) ptr[0] = b[0];
            },
            .char => |b| {
                if (w >= 4) {
                    const dst: *u32 = @ptrCast(@alignCast(ptr));
                    dst.* = @bitCast(b);
                }
            },
            .i8 => |b| {
                if (w >= 1) ptr[0] = b[0];
            },
            .i16 => |b| {
                if (w >= 2) {
                    const dst: *i16 = @ptrCast(@alignCast(ptr));
                    dst.* = @bitCast(b);
                }
            },
            .i32 => |b| {
                if (w >= 4) {
                    const dst: *i32 = @ptrCast(@alignCast(ptr));
                    dst.* = @bitCast(b);
                }
            },
            .i64 => |b| {
                if (w >= 8) {
                    const dst: *i64 = @ptrCast(@alignCast(ptr));
                    dst.* = @bitCast(b);
                }
            },
            .u8 => |b| {
                if (w >= 1) ptr[0] = b[0];
            },
            .u16 => |b| {
                if (w >= 2) {
                    const dst: *u16 = @ptrCast(@alignCast(ptr));
                    dst.* = @bitCast(b);
                }
            },
            .u32 => |b| {
                if (w >= 4) {
                    const dst: *u32 = @ptrCast(@alignCast(ptr));
                    dst.* = @bitCast(b);
                }
            },
            .u64 => |b| {
                if (w >= 8) {
                    const dst: *u64 = @ptrCast(@alignCast(ptr));
                    dst.* = @bitCast(b);
                }
            },
            .i128 => |b| {
                if (w >= 16) {
                    const dst: *i128 = @ptrCast(@alignCast(ptr));
                    dst.* = @bitCast(b);
                }
            },
            .u128 => |b| {
                if (w >= 16) {
                    const dst: *u128 = @ptrCast(@alignCast(ptr));
                    dst.* = @bitCast(b);
                }
            },
            .f16 => |b| {
                if (w >= 2) {
                    const dst: *f16 = @ptrCast(@alignCast(ptr));
                    dst.* = @bitCast(b);
                }
            },
            .f32 => |b| {
                if (w >= 4) {
                    const dst: *f32 = @ptrCast(@alignCast(ptr));
                    dst.* = @bitCast(b);
                }
            },
            .f64 => |b| {
                if (w >= 8) {
                    const dst: *f64 = @ptrCast(@alignCast(ptr));
                    dst.* = @bitCast(b);
                }
            },
            .f128 => |b| {
                if (w >= 16) {
                    const dst: *f128 = @ptrCast(@alignCast(ptr));
                    dst.* = @bitCast(b);
                }
            },
            .ref => |obj| {
                if (w >= 8) {
                    const dst: *u64 = @ptrCast(@alignCast(ptr));
                    dst.* = @intFromPtr(obj);
                }
            },
            else => {},
        }
    }
};
