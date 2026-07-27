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
        self.runtime.writePtr(node.output, @ptrCast(nt_v.asRef()));
    }

    /// newtype_unwrap：从 NewtypeValue 提取内部值
    /// inputs[0] = ref_chan（NewtypeValue 指针）
    /// output = 内部值通道
    pub fn execNewtypeUnwrap(self: *Engine, node: *const Node) EngineError!void {
        const ref_chan = node.inputs[0];
        const header = self.readRefObj(ref_chan) orelse return error.Panic;
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
    /// - 复合类型（operand 是 ref_chan）：operand 已经持有 *ObjHeader，直接复制指针到 output
    /// - 标量（operand 是标量通道）：编码为 tagged pointer (channel_index << 1) | 1
    ///   无需堆分配，output ref_chan 直接存储编码后的标量引用
    /// - operand 是 ref_chan（已是引用）：复制引用本身（实现引用的引用）
    pub fn execRefOf(self: *Engine, node: *const Node) EngineError!void {
        const src_chan = node.inputs[0];
        const src_w = self.runtime.elemWidth(src_chan);
        const dst = self.runtime.rawPtr(node.output);
        const src_meta = self.ir.channels.get(src_chan);

        // ref_chan（复合对象/已有引用）：src 通道持有 8 字节指针，直接复制
        // 标量类型（usize/u64/i64/f64 等也是 8 字节）必须走编码路径，否则会把标量值误当指针。
        if (src_meta.chan_type == .ref_chan) {
            const src = self.runtime.rawPtr(src_chan);
            @memcpy(dst[0..8], src[0..8]);
            // retain 引用计数（堆对象共享）— 仅对真实堆对象，标量引用无需 retain
            const obj_ptr: ?*anyopaque = @ptrCast(@alignCast(@as(*?*anyopaque, @ptrCast(@alignCast(src))).*));
            if (obj_ptr) |p| {
                const addr = @intFromPtr(p);
                if (!Engine.isScalarRef(addr)) {
                    const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(p));
                    _ = value.obj_header.retain(header, self.tctx.?);
                }
            }
        } else if (src_w > 0 and src_w <= 16) {
            // 标量：编码为 tagged pointer (channel_index << 1) | 1，无需堆分配
            const encoded = Engine.encodeScalarRef(src_chan);
            const dst_ptr: *?*anyopaque = @ptrCast(@alignCast(dst));
            dst_ptr.* = @ptrFromInt(encoded);
        } else if (src_w == 0) {
            // unit 类型：ref 无意义，写 null
            const dst_ptr: *?*anyopaque = @ptrCast(@alignCast(dst));
            dst_ptr.* = null;
        }
    }

    /// ref_get：解引用 *expr
    /// 读取引用指向的值到 output 通道
    /// - 标量引用（tagged pointer）：解码通道索引，从原始通道读取标量值（支持回写）
    /// - 复合对象：直接复制对象指针（result 是 ref_chan）
    pub fn execRefGet(self: *Engine, node: *const Node) EngineError!void {
        const ref_chan = node.inputs[0];
        const dst_w = self.runtime.elemWidth(node.output);
        if (dst_w == 0) return;

        const obj_ptr = self.runtime.readPtr(ref_chan) orelse return error.Panic;
        const ptr_bits = @intFromPtr(obj_ptr);
        const dst = self.runtime.rawPtr(node.output);

        // 标量引用（tagged pointer，bit 0 = 1）：从原始通道读取标量值
        // 注意：标量值位模式可能 bit 0 = 1，必须用 tryDecodeScalarRef 验证合法性
        if (self.tryDecodeScalarRef(ptr_bits)) |src_chan| {
            const src = self.runtime.rawPtr(src_chan);
            const copy_w = @min(dst_w, 16);
            @memcpy(dst[0..copy_w], src[0..copy_w]);
            return;
        }

        // 复合对象：复制对象指针本身（ref_get 对复合对象 = 取对象引用）
        const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(obj_ptr));
        if (dst_w == 8) {
            const dst_ptr: *?*anyopaque = @ptrCast(@alignCast(dst));
            dst_ptr.* = obj_ptr;
            _ = value.obj_header.retain(header, self.tctx.?);
        }
    }

    /// ref_set：通过引用写入 *ref = value
    /// inputs[0] = 引用通道，inputs[1] = 值通道
    /// - 标量引用（tagged pointer）：解码通道索引，写入原始通道（实现回写）
    /// - 复合对象：无操作（复合对象本身是共享的，赋值语义不适用）
    pub fn execRefSet(self: *Engine, node: *const Node) EngineError!void {
        const ref_chan = node.inputs[0];
        const val_chan = node.inputs[1];

        const obj_ptr = self.runtime.readPtr(ref_chan) orelse return error.Panic;
        const ptr_bits = @intFromPtr(obj_ptr);

        // 标量引用（tagged pointer，bit 0 = 1）：写入原始通道（实现回写）
        // 注意：标量值位模式可能 bit 0 = 1，必须用 tryDecodeScalarRef 验证合法性
        if (self.tryDecodeScalarRef(ptr_bits)) |dst_chan| {
            const val_w = self.runtime.elemWidth(val_chan);
            if (val_w == 0 or val_w > 16) return;
            const dst = self.runtime.rawPtr(dst_chan);
            const src = self.runtime.rawPtr(val_chan);
            @memcpy(dst[0..val_w], src[0..val_w]);
            return;
        }

        // 复合对象的 ref_set：替换引用本身（重新绑定）
        // 暂不实现，复合对象赋值通过 field assignment 完成
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
