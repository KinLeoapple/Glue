//! 值/通道转换函数（v3 阶段 5.3：从 engine.zig 物理拆分）
//!
//! 包含：
//! - 值转换：chanToValue / valueToChan / 标量引用编解码（encodeScalarRef 等）
//! - 跨通道复制：cloneValueBetweenChannels / copyCrossType / cloneValueForContainer / trackValueTree
//! - 读取辅助：readStr / readArray / currentFuncIdx / restoreVectorChan / readRefObj /
//!   readThrow / readIntAsI64 / readError
//! - 标量值读写：readScalarValue / writeScalarValue / readScalarValueToBytes
//!
//! 拆分模式：pub const Methods = struct { pub fn ... }，
//! engine.zig 通过 pub const 别名注入 Engine 结构体。

const std = @import("std");
const ir_mod = @import("ir");
const value = @import("value");

const engine_mod = @import("engine.zig");
const Engine = engine_mod.Engine;
const EngineError = engine_mod.EngineError;

pub const Methods = struct {
    // ════════════════════════════════════════════
    // 标量引用编解码（tagged pointer 方案）
    // ════════════════════════════════════════════

    /// 标量通道引用编码：(channel_index << 1) | 1
    /// 真实堆指针 8 字节对齐（bit 0 = 0），bit 0 作为 tag 区分标量引用。
    pub fn encodeScalarRef(chan_idx: u16) usize {
        return (@as(usize, @intCast(chan_idx)) << 1) | 1;
    }

    /// 判断指针位是否为标量引用（tagged pointer，bit 0 = 1）
    pub fn isScalarRef(ptr_bits: usize) bool {
        return (ptr_bits & 1) != 0;
    }

    /// 从标量引用位解码出通道索引
    pub fn decodeScalarRef(ptr_bits: usize) u16 {
        return @intCast(ptr_bits >> 1);
    }

    /// 尝试解码标量引用，验证通道索引有效性。
    /// 标量值（如泛型参数实例化为 i32）直接存入 ref_chan 时位模式可能 bit 0 = 1，
    /// 与 tagged pointer 冲突。此函数额外验证解码后的通道索引合法且指向标量通道，
    /// 避免把标量位模式误判为标量引用。
    /// 返回 null 的情况：
    /// - ptr_bits 不是标量引用（bit 0 = 0）
    /// - 解码后的通道索引越界（>= chan_count）
    /// - 解码后的通道是 ref_chan（标量引用只能指向标量通道，不能指向引用通道）
    pub fn tryDecodeScalarRef(self: *Engine, ptr_bits: usize) ?u16 {
        if (!isScalarRef(ptr_bits)) return null;
        const decoded = decodeScalarRef(ptr_bits);
        if (decoded >= self.runtime.chan_count) return null;
        const decoded_meta = self.ir.channels.get(decoded);
        if (decoded_meta.chan_type == .ref_chan) return null;
        return decoded;
    }

    // ════════════════════════════════════════════
    // 值转换
    // ════════════════════════════════════════════

    /// 从通道读取 Value（标量值）
    pub fn chanToValue(self: *Engine, chan: u16) value.Value {
        const meta = self.ir.channels.get(chan);
        const w = meta.elem_width;
        if (w == 0) return value.Value.fromUnit();
        const ptr = self.runtime.rawPtr(chan);
        return switch (meta.chan_type) {
            .bool_chan, .mask_chan => value.Value.fromBool(self.runtime.readBool(chan)),
            .char_chan => blk: {
                const cp: u32 = @bitCast(@as(*[4]u8, @ptrCast(ptr)).*);
                break :blk value.Value.fromChar(.{ .codepoint = cp });
            },
            .i8_chan => value.Value.fromI8(@bitCast(ptr[0])),
            .i16_chan => value.Value.fromI16(@bitCast(@as(*[2]u8, @ptrCast(ptr)).*)),
            .i32_chan => value.Value.fromI32(@bitCast(@as(*[4]u8, @ptrCast(ptr)).*)),
            .i64_chan => value.Value.fromI64(self.runtime.readI64(chan)),
            .i128_chan => blk: {
                // 128-bit 通道按 16 字节直接读取
                const p: *i128 = @ptrCast(@alignCast(ptr));
                break :blk value.Value.fromI128(p.*);
            },
            .u8_chan => value.Value.fromU8(ptr[0]),
            .u16_chan => value.Value.fromU16(@bitCast(@as(*[2]u8, @ptrCast(ptr)).*)),
            .u32_chan => value.Value.fromU32(@bitCast(@as(*[4]u8, @ptrCast(ptr)).*)),
            .u64_chan => value.Value.fromU64(self.runtime.readU64(chan)),
            .u128_chan => blk: {
                const p: *u128 = @ptrCast(@alignCast(ptr));
                break :blk value.Value.fromU128(p.*);
            },
            .isize_chan => value.Value.fromIsize(@bitCast(self.runtime.readUsize(chan))),
            .usize_chan => value.Value.fromUsize(@bitCast(self.runtime.readUsize(chan))),
            .f16_chan => blk: {
                const p: *f16 = @ptrCast(@alignCast(ptr));
                break :blk value.Value.fromF16(p.*);
            },
            .f32_chan => value.Value.fromF32(@bitCast(@as(*[4]u8, @ptrCast(ptr)).*)),
            .f64_chan => value.Value.fromF64(self.runtime.readF64(chan)),
            .f128_chan => blk: {
                const p: *f128 = @ptrCast(@alignCast(ptr));
                break :blk value.Value.fromF128(p.*);
            },
            .ref_chan => blk: {
                // 标量引用（tagged pointer，bit 0 = 1）：解码通道索引并递归读取标量值
                // 注意：标量值（泛型参数实例化为 i32 等）直接存入 ref_chan 时位模式可能 bit 0 = 1，
                // 必须用 tryDecodeScalarRef 验证解码后的通道索引合法性，避免误判。
                if (self.runtime.readPtr(chan)) |raw_ptr| {
                    const ptr_bits = @intFromPtr(raw_ptr);
                    if (self.tryDecodeScalarRef(ptr_bits)) |src_chan| {
                        break :blk self.chanToValue(src_chan);
                    }
                }
                if (self.readRefObj(chan)) |header| {
                    break :blk value.Value.fromRef(header);
                }
                // readRefObj 失败：ref_chan 持有标量位模式
                const raw = self.runtime.readI64(chan);
                if (raw == 0) break :blk value.Value.fromNull();
                break :blk value.Value.fromI64(raw);
            },
            else => value.Value.fromUnit(),
        };
    }

    /// 将 Value 写入通道
    pub fn valueToChan(self: *Engine, chan: u16, v: value.Value) void {
        // ref_chan 通道（8 字节）接收标量值时，必须扩展到完整 8 字节
        // （整数符号扩展为 i64，浮点提升为 f64），否则只写标量宽度字节，
        // 高字节残留旧数据导致值损坏（类型参数实例化为标量时的核心问题）
        const meta = self.ir.channels.get(chan);
        if (meta.chan_type == .ref_chan) {
            self.writeScalarValue(chan, v);
            return;
        }
        switch (v) {
            .null_val, .unit => {},
            .boolean => |b| self.runtime.writeBool(chan, b[0] != 0),
            .char => |b| {
                const ptr: *u32 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .i8 => |b| {
                const ptr = self.runtime.rawPtr(chan);
                ptr[0] = b[0];
            },
            .i16 => |b| {
                const ptr: *i16 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .i32 => |b| {
                const ptr: *i32 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .i64 => |b| {
                // 按 chan_type 派发：整数通道直接写，浮点通道走转换，ref_chan 走位模式
                const ptr = self.runtime.rawPtr(chan);
                const val: i64 = @bitCast(b);
                switch (meta.chan_type) {
                    .i64_chan, .u64_chan, .isize_chan, .usize_chan, .ref_chan => {
                        const dst: *i64 = @ptrCast(@alignCast(ptr));
                        dst.* = val;
                    },
                    .i32_chan, .u32_chan => {
                        const dst: *i32 = @ptrCast(@alignCast(ptr));
                        dst.* = @truncate(val);
                    },
                    .i16_chan, .u16_chan => {
                        const dst: *i16 = @ptrCast(@alignCast(ptr));
                        dst.* = @truncate(val);
                    },
                    .i8_chan, .u8_chan => {
                        ptr[0] = @truncate(@as(u64, @bitCast(val)));
                    },
                    .f64_chan => {
                        const dst: *f64 = @ptrCast(@alignCast(ptr));
                        dst.* = @floatFromInt(val);
                    },
                    .f32_chan => {
                        const dst: *f32 = @ptrCast(@alignCast(ptr));
                        dst.* = @floatFromInt(@as(i32, @truncate(val)));
                    },
                    .f16_chan => {
                        const dst: *f16 = @ptrCast(@alignCast(ptr));
                        dst.* = @floatFromInt(@as(i16, @truncate(val)));
                    },
                    .f128_chan => {
                        const dst: *f128 = @ptrCast(@alignCast(ptr));
                        dst.* = @floatFromInt(val);
                    },
                    .i128_chan, .u128_chan => {
                        const dst: *i128 = @ptrCast(@alignCast(ptr));
                        dst.* = val; // 符号扩展到 i128
                    },
                    .bool_chan, .mask_chan => self.runtime.writeBool(chan, val != 0),
                    .char_chan => {
                        const dst: *u32 = @ptrCast(@alignCast(ptr));
                        dst.* = @truncate(@as(u64, @bitCast(val)));
                    },
                    else => {},
                }
            },
            .u8 => |b| {
                const ptr = self.runtime.rawPtr(chan);
                ptr[0] = b[0];
            },
            .u16 => |b| {
                const ptr: *u16 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .u32 => |b| {
                const ptr: *u32 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .u64 => |b| {
                const ptr: *u64 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .usize => |b| {
                const ptr: *usize = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .isize => |b| {
                const ptr: *isize = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .i128 => |b| {
                // 128-bit 值直接写入 16 字节通道
                const ptr: *i128 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .u128 => |b| {
                const ptr: *u128 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .f16 => |b| {
                const ptr: *f16 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .f32 => |b| {
                const ptr: *f32 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .f64 => |b| {
                const ptr: *f64 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .f128 => |b| {
                const ptr: *f128 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = @bitCast(b);
            },
            .ref => |obj| {
                if (meta.chan_type == .nullable_chan) {
                    const inner_w = meta.inner_type.elemWidth();
                    const ptr = self.runtime.rawPtr(chan);
                    const dst_obj: *?*anyopaque = @ptrCast(@alignCast(ptr));
                    dst_obj.* = @ptrCast(obj);
                    ptr[inner_w] = 0; // non-null flag
                } else {
                    self.runtime.writePtr(chan, @ptrCast(obj));
                }
            },
        }
    }

    // ════════════════════════════════════════════
    // 跨通道复制
    // ════════════════════════════════════════════

    /// 按统一值语义在通道间复制值。
    /// - 同类型同宽度：直接 @memcpy
    /// - ref_chan + 引用类型（is_ref=true）：共享指针（同宽度 @memcpy）
    /// - ref_chan + 普通复合类型（is_ref=false）：深拷贝 Value 后写入目标通道
    /// - 类型/宽度不匹配（含类型参数实例化为标量时标量存入 ref_chan）：走 copyCrossType
    pub fn cloneValueBetweenChannels(self: *Engine, dst_chan: u16, src_chan: u16, is_ref: bool) EngineError!void {
        const src_meta = self.ir.channels.get(src_chan);
        const dst_meta = self.ir.channels.get(dst_chan);
        const w = src_meta.elem_width;
        if (w == 0) return;

        // ref_chan 持有堆引用且需值语义深拷贝
        if (src_meta.chan_type == .ref_chan and !is_ref) {
            if (self.readRefObj(src_chan)) |header| {
                const v = value.Value.fromRef(header);
                const copied = v.deepCopy(self.tctx.?) catch return error.OutOfMemory;
                try self.trackValueTree(copied);
                self.valueToChan(dst_chan, copied);
                return;
            }
            // readRefObj 失败：ref_chan 持有标量位模式（类型参数实例化为标量），
            // 走跨类型复制路径
        }

        // 源/目标通道类型或宽度不匹配：跨类型复制
        if (src_meta.chan_type != dst_meta.chan_type or src_meta.elem_width != dst_meta.elem_width) {
            try self.copyCrossType(dst_chan, src_chan);
            return;
        }

        // 同类型同宽度：直接复制字节
        if (src_chan == dst_chan) return;
        const src = self.runtime.rawPtr(src_chan);
        const dst = self.runtime.rawPtr(dst_chan);
        @memcpy(dst[0..w], src[0..w]);
    }

    /// 跨通道类型复制：当源/目标 chan_type 或 elem_width 不匹配时使用。
    /// 核心场景：泛型函数的类型参数（A/T）被映射为 ref_chan（8字节），
    /// 但实际值为标量（i32/f32 等）。此时需要：
    /// - 标量 → ref_chan：整数符号扩展为 i64，浮点提升为 f64，写入 8 字节
    /// - ref_chan → 标量：按目标类型解释 8 字节（i64 截断为整数，f64 转换为浮点）
    /// 这样保证标量值在 ref_chan 中转后能正确还原（i32→i64→i32, f32→f64→f32）。
    pub fn copyCrossType(self: *Engine, dst_chan: u16, src_chan: u16) EngineError!void {
        const src_meta = self.ir.channels.get(src_chan);
        const dst_meta = self.ir.channels.get(dst_chan);
        const src_raw = self.runtime.rawPtr(src_chan);
        const dst_raw = self.runtime.rawPtr(dst_chan);

        // 标量 → ref_chan：按源类型读取标量，扩展为 8 字节写入
        // i128/u128/f128（16 字节）无法塞入 8 字节 ref_chan，截断到低 64 位（lossy）；
        // 完整值需走具体标量通道（i128_chan 等），泛型 T 上下文暂不支持 16 字节标量。
        // f16/f32/f64 可经 f64 无损往返，走 8 字节提升路径即可。
        if (dst_meta.chan_type == .ref_chan and src_meta.chan_type != .ref_chan) {
            const dst_ptr: *i64 = @ptrCast(@alignCast(dst_raw));
            dst_ptr.* = switch (src_meta.chan_type) {
                .i8_chan => @as(i64, @as(i8, @bitCast(src_raw[0]))),
                .u8_chan => @as(i64, src_raw[0]),
                .i16_chan => blk: {
                    const p: *i16 = @ptrCast(@alignCast(src_raw));
                    break :blk @as(i64, p.*);
                },
                .u16_chan => blk: {
                    const p: *u16 = @ptrCast(@alignCast(src_raw));
                    break :blk @as(i64, p.*);
                },
                .i32_chan => blk: {
                    const p: *i32 = @ptrCast(@alignCast(src_raw));
                    break :blk @as(i64, p.*);
                },
                .u32_chan => blk: {
                    const p: *u32 = @ptrCast(@alignCast(src_raw));
                    break :blk @as(i64, p.*);
                },
                .i64_chan => blk: {
                    const p: *i64 = @ptrCast(@alignCast(src_raw));
                    break :blk p.*;
                },
                .u64_chan => blk: {
                    const p: *u64 = @ptrCast(@alignCast(src_raw));
                    break :blk @bitCast(p.*);
                },
                .isize_chan => blk: {
                    const p: *isize = @ptrCast(@alignCast(src_raw));
                    break :blk @as(i64, p.*);
                },
                .usize_chan => blk: {
                    const p: *usize = @ptrCast(@alignCast(src_raw));
                    break :blk @bitCast(@as(u64, p.*));
                },
                .bool_chan, .mask_chan => @intFromBool(src_raw[0] != 0),
                .char_chan => blk: {
                    const p: *u32 = @ptrCast(@alignCast(src_raw));
                    break :blk @as(i64, p.*);
                },
                .f16_chan => blk: {
                    const p: *f16 = @ptrCast(@alignCast(src_raw));
                    break :blk @bitCast(@as(f64, @floatCast(p.*)));
                },
                .f32_chan => blk: {
                    const p: *f32 = @ptrCast(@alignCast(src_raw));
                    const f64_val: f64 = @floatCast(p.*);
                    break :blk @bitCast(f64_val);
                },
                .f64_chan => blk: {
                    const p: *f64 = @ptrCast(@alignCast(src_raw));
                    break :blk @bitCast(p.*);
                },
                // i128/u128/f128：截断到低 64 位（lossy），完整值需走具体标量通道
                .i128_chan => blk: {
                    const p: *i128 = @ptrCast(@alignCast(src_raw));
                    break :blk @truncate(p.*);
                },
                .u128_chan => blk: {
                    const p: *u128 = @ptrCast(@alignCast(src_raw));
                    break :blk @bitCast(@as(u64, @truncate(p.*)));
                },
                .f128_chan => blk: {
                    const p: *f128 = @ptrCast(@alignCast(src_raw));
                    break :blk @bitCast(@as(f64, @floatCast(p.*)));
                },
                else => 0,
            };
            return;
        }

        // ref_chan → 标量：按目标类型解释 8 字节位模式
        // i128/u128/f128（16 字节）从 8 字节位模式扩展，低 64 位补零扩展（lossy）；
        // 完整值需走具体标量通道（i128_chan 等），泛型 T 上下文暂不支持 16 字节标量。
        // f16/f32/f64 经 f64 无损往返，走位模式路径即可。
        if (src_meta.chan_type == .ref_chan and dst_meta.chan_type != .ref_chan) {
            switch (dst_meta.chan_type) {
                .i128_chan, .u128_chan, .f128_chan => {
                    // ref_chan 持有 8 字节位模式，低 64 位补零扩展到 16 字节
                    const sp: *i64 = @ptrCast(@alignCast(src_raw));
                    const dp: *[16]u8 = @ptrCast(@alignCast(dst_raw));
                    @memset(dp, 0);
                    const low_bytes: [8]u8 = @bitCast(sp.*);
                    @memcpy(dp[0..8], &low_bytes);
                    return;
                },
                else => {},
            }
            switch (dst_meta.chan_type) {
                .i8_chan => {
                    const sp: *i64 = @ptrCast(@alignCast(src_raw));
                    dst_raw[0] = @truncate(@as(u64, @bitCast(sp.*)));
                },
                .u8_chan => {
                    const sp: *i64 = @ptrCast(@alignCast(src_raw));
                    dst_raw[0] = @truncate(@as(u64, @bitCast(sp.*)));
                },
                .i16_chan => {
                    const sp: *i64 = @ptrCast(@alignCast(src_raw));
                    const dp: *i16 = @ptrCast(@alignCast(dst_raw));
                    dp.* = @truncate(sp.*);
                },
                .u16_chan => {
                    const sp: *i64 = @ptrCast(@alignCast(src_raw));
                    const dp: *u16 = @ptrCast(@alignCast(dst_raw));
                    dp.* = @truncate(@as(u64, @bitCast(sp.*)));
                },
                .i32_chan => {
                    const sp: *i64 = @ptrCast(@alignCast(src_raw));
                    const dp: *i32 = @ptrCast(@alignCast(dst_raw));
                    dp.* = @truncate(sp.*);
                },
                .u32_chan => {
                    const sp: *i64 = @ptrCast(@alignCast(src_raw));
                    const dp: *u32 = @ptrCast(@alignCast(dst_raw));
                    dp.* = @truncate(@as(u64, @bitCast(sp.*)));
                },
                .i64_chan, .u64_chan, .isize_chan, .usize_chan => {
                    const sp: *i64 = @ptrCast(@alignCast(src_raw));
                    const dp: *i64 = @ptrCast(@alignCast(dst_raw));
                    dp.* = sp.*;
                },
                .char_chan => {
                    const sp: *i64 = @ptrCast(@alignCast(src_raw));
                    const dp: *u32 = @ptrCast(@alignCast(dst_raw));
                    dp.* = @truncate(@as(u64, @bitCast(sp.*)));
                },
                .f16_chan => {
                    const sp: *f64 = @ptrCast(@alignCast(src_raw));
                    const dp: *f16 = @ptrCast(@alignCast(dst_raw));
                    dp.* = @floatCast(sp.*);
                },
                .f32_chan => {
                    const sp: *f64 = @ptrCast(@alignCast(src_raw));
                    const dp: *f32 = @ptrCast(@alignCast(dst_raw));
                    dp.* = @floatCast(sp.*);
                },
                .f64_chan => {
                    const sp: *f64 = @ptrCast(@alignCast(src_raw));
                    const dp: *f64 = @ptrCast(@alignCast(dst_raw));
                    dp.* = sp.*;
                },
                .bool_chan, .mask_chan => {
                    const sp: *i64 = @ptrCast(@alignCast(src_raw));
                    self.runtime.writeBool(dst_chan, sp.* != 0);
                },
                else => {
                    const copy_w = @min(dst_meta.elem_width, 8);
                    @memcpy(dst_raw[0..copy_w], src_raw[0..copy_w]);
                },
            }
            return;
        }

        // 标量 → 标量（不同宽度）：通过 Value 中转
        const v = self.chanToValue(src_chan);
        self.writeScalarValue(dst_chan, v);
    }

    /// 按容器元素/字段的值语义复制 Value。
    /// - is_ref = true：元素/字段类型为 &T / *T，retain 后共享。
    /// - is_ref = false：普通类型，深拷贝生成独立副本。
    pub fn cloneValueForContainer(self: *Engine, v: value.Value, is_ref: bool) EngineError!value.Value {
        if (is_ref) {
            if (v.isBoxed()) _ = v.retain(self.tctx.?);
            return v;
        }
        const copied = v.deepCopy(self.tctx.?) catch return error.OutOfMemory;
        // deepCopy 创建的新堆对象需要递归跟踪，否则 shutdown_mode 下 deinit 不级联
        // release 时这些对象会泄漏
        try self.trackValueTree(copied);
        return copied;
    }

    /// 递归跟踪值及其所有子引用对象
    /// 用于深拷贝后注册所有新建堆对象：shutdown_mode 下 deinit 跳过级联 release，
    /// 未跟踪的子对象（Str、Array、Record 等）会泄漏其页池页
    /// 注意：必须在 trackObj 之前检查 isTracked，避免对自引用闭包/循环引用无限递归
    pub fn trackValueTree(self: *Engine, v: value.Value) EngineError!void {
        if (v != .ref) return;
        // 已跟踪的对象直接返回，避免循环引用导致的无限递归
        // （子树在首次跟踪时已完整递归，无需重复）
        if (v.ref.isTracked()) return;
        try self.trackObj(v.ref);
        // 递归跟踪复合类型的子引用
        switch (v.ref.type_tag) {
            .str, .range, .builtin => {},
            .array => {
                const arr: *value.ArrayValue = @alignCast(@fieldParentPtr("header", v.ref));
                for (arr.elements) |elem| try self.trackValueTree(elem);
            },
            .record => {
                const rec: *value.RecordValue = @alignCast(@fieldParentPtr("header", v.ref));
                for (rec.fields) |f| try self.trackValueTree(f);
            },
            .adt => {
                const adt: *value.AdtValue = @alignCast(@fieldParentPtr("header", v.ref));
                for (adt.fields) |f| try self.trackValueTree(f.value);
            },
            .newtype => {
                const nt: *value.NewtypeValue = @alignCast(@fieldParentPtr("header", v.ref));
                try self.trackValueTree(nt.inner);
            },
            .cell => {
                const cell: *value.Cell = @alignCast(@fieldParentPtr("header", v.ref));
                try self.trackValueTree(cell.inner);
            },
            .throw_val => {
                const tv: *value.ThrowValue = @alignCast(@fieldParentPtr("header", v.ref));
                switch (tv.payload) {
                    .ok => |inner| try self.trackValueTree(inner),
                    .err => |err_ptr| try self.trackObj(&err_ptr.header),
                }
            },
            .error_val => {},
            .closure => {
                const cl: *value.Closure = @alignCast(@fieldParentPtr("header", v.ref));
                for (cl.upvalues) |uv| try self.trackValueTree(uv);
                for (cl.bound_args) |ba| try self.trackValueTree(ba);
            },
            .partial => {
                const pt: *value.PartialApplication = @alignCast(@fieldParentPtr("header", v.ref));
                for (pt.bound_args) |ba| try self.trackValueTree(ba);
            },
            else => {},
        }
    }

    // ════════════════════════════════════════════
    // 读取辅助
    // ════════════════════════════════════════════

    pub fn readStr(self: *Engine, chan: u16) ?*value.str_mod.Str {
        const header = self.readRefObj(chan) orelse return null;
        if (header.type_tag == .lazy_val) {
            const lazy: *value.LazyValue = @alignCast(@fieldParentPtr("header", header));
            const forced = self.forceLazyValue(lazy) catch return null;
            switch (forced) {
                .ref => |r| {
                    const h: *value.obj_header.ObjHeader = @ptrCast(@alignCast(r));
                    if (h.type_tag != .str) return null;
                    return @alignCast(@fieldParentPtr("header", h));
                },
                else => return null,
            }
        }
        if (header.type_tag != .str) return null;
        return @alignCast(@fieldParentPtr("header", header));
    }

    pub fn readArray(self: *Engine, chan: u16) ?*value.ArrayValue {
        const header = self.readRefObj(chan) orelse return null;
        if (header.type_tag != .array) return null;
        return @alignCast(@fieldParentPtr("header", header));
    }

    /// 获取当前正在执行的函数索引
    pub fn currentFuncIdx(self: *Engine) u16 {
        return self.current_func_idx;
    }

    /// 恢复被 pinToElement 修改的向量通道指针
    pub fn restoreVectorChan(self: *Engine, chan: u16, count: u32) void {
        if (count <= 1) return; // 0 或 1 个元素时指针未被移动
        const w = self.runtime.chanWidths(chan);
        self.runtime.setChanPtr(chan, self.runtime.chanPtrs(chan).? - @as(usize, count - 1) * w);
        self.runtime.setChanLength(chan, count);
    }

    /// 读取 ref_chan 中的堆对象，返回 *ObjHeader 或 null
    ///
    /// 通过 ObjHeader 字段语义验证指针合法性（架构无关）：
    /// - 标量引用（tagged pointer，bit 0 = 1）：返回 null（仅用于真实堆对象）
    /// - null/低地址过滤：addr < 0x1000 不是合法堆对象（null 指针、小整数）
    /// - 对齐检查：堆对象必须按 ObjHeader 对齐
    /// - isValidHeapObj：type_tag 范围 + rc>=1 + flags 未用位为 0
    ///
    /// 标量值通过 ref_chan 传输时位模式可能被误判为指针，
    /// ObjHeader 字段语义验证可可靠过滤这类伪指针，不依赖架构相关地址范围假设。
    pub fn readRefObj(self: *Engine, chan: u16) ?*value.obj_header.ObjHeader {
        const ptr = self.runtime.readPtr(chan) orelse return null;
        const addr = @intFromPtr(ptr);
        // 标量引用（tagged pointer，bit 0 = 1）：不是真实堆对象
        if (isScalarRef(addr)) return null;
        if (addr < 0x1000) return null;
        if (addr % @alignOf(value.obj_header.ObjHeader) != 0) return null;
        const header: *value.obj_header.ObjHeader = @ptrCast(@alignCast(ptr));
        if (!header.isValidHeapObj()) return null;
        return header;
    }

    /// 读取 ThrowValue 指针（ref_chan → *ThrowValue）
    pub fn readThrow(self: *Engine, chan: u16) ?*value.ThrowValue {
        const header = self.readRefObj(chan) orelse return null;
        if (header.type_tag != .throw_val) return null;
        return @alignCast(@fieldParentPtr("header", header));
    }

    /// 按通道实际类型读取整数值并符号扩展为 i64。
    /// 这是通用观察点：如果通道中是 LazyValue，会先强制求值，再转为 i64。
    /// 用于索引、长度、select 超时等所有需要把值当作整数观察的场景。
    pub fn readIntAsI64(self: *Engine, chan: u16) EngineError!i64 {
        const v = try self.readScalarValue(chan);
        return switch (v) {
            .i8 => |b| @as(i64, @as(i8, @bitCast(b[0]))),
            .i16 => |b| @as(i64, @as(i16, @bitCast(b))),
            .i32 => |b| @as(i64, @as(i32, @bitCast(b))),
            .i64 => |b| @as(i64, @bitCast(b)),
            .u8 => |b| @as(i64, b[0]),
            .u16 => |b| @as(i64, @as(u16, @bitCast(b))),
            .u32 => |b| @as(i64, @as(u32, @bitCast(b))),
            .u64 => |b| @bitCast(@as(u64, @bitCast(b))),
            .isize => |b| @as(i64, @as(isize, @bitCast(b))),
            .usize => |b| @bitCast(@as(usize, @bitCast(b))),
            .boolean => |b| @intFromBool(b[0] != 0),
            .char => |b| @as(i64, @intCast(@as(u32, @bitCast(b)))),
            // i128/u128 超出 i64 范围时返回 error.Overflow，而非静默归零（else 分支）
            .i128 => |b| blk: {
                const val: i128 = @bitCast(b);
                if (val < std.math.minInt(i64) or val > std.math.maxInt(i64)) break :blk error.Overflow;
                break :blk @intCast(val);
            },
            .u128 => |b| blk: {
                const val: u128 = @bitCast(b);
                if (val > std.math.maxInt(i64)) break :blk error.Overflow;
                break :blk @intCast(val);
            },
            // 浮点转整数：NaN/Inf/超范围时 @intFromFloat 会 panic，先校验
            .f32 => |b| blk: {
                const val: f32 = @bitCast(b);
                if (std.math.isNan(val) or std.math.isInf(val)) break :blk error.Overflow;
                // maxInt(i64) 超出 f32 精确表示范围，用 @floatFromInt 显式转换（允许精度损失）
                const i64_min: f32 = @floatFromInt(std.math.minInt(i64));
                const i64_max: f32 = @floatFromInt(std.math.maxInt(i64));
                if (val < i64_min or val > i64_max) break :blk error.Overflow;
                break :blk @intFromFloat(val);
            },
            .f64 => |b| blk: {
                const val: f64 = @bitCast(b);
                if (std.math.isNan(val) or std.math.isInf(val)) break :blk error.Overflow;
                const i64_min: f64 = @floatFromInt(std.math.minInt(i64));
                const i64_max: f64 = @floatFromInt(std.math.maxInt(i64));
                if (val < i64_min or val > i64_max) break :blk error.Overflow;
                break :blk @intFromFloat(val);
            },
            else => 0,
        };
    }

    /// 读取 ErrorValue 指针（ref_chan → *ErrorValue）
    pub fn readError(self: *Engine, chan: u16) ?*value.ErrorValue {
        const header = self.readRefObj(chan) orelse return null;
        if (header.type_tag != .error_val) return null;
        return @alignCast(@fieldParentPtr("header", header));
    }

    // ════════════════════════════════════════════
    // 标量值读写
    // ════════════════════════════════════════════

    /// 从通道读取标量值（用于 gate 操作、print、return 等观察点）
    /// ref_chan 中若是 LazyValue，会自动强制求值一次并返回其结果（缓存借用）。
    /// 通用实现：ref_chan/bool/char 走快路径，其余所有标量类型复用 chanToValue，
    /// 确保完整覆盖 i8..i128/u8..u128/isize/usize/f16..f128 全部类型变体。
    pub fn readScalarValue(self: *Engine, chan: u16) EngineError!value.Value {
        const meta = self.ir.channels.get(chan);
        if (meta.chan_type == .ref_chan) {
            // 标量引用（tagged pointer，bit 0 = 1）：解码通道索引并读取标量值
            // 注意：标量值位模式可能 bit 0 = 1，必须用 tryDecodeScalarRef 验证合法性
            if (self.runtime.readPtr(chan)) |raw_ptr| {
                const ptr_bits = @intFromPtr(raw_ptr);
                if (self.tryDecodeScalarRef(ptr_bits)) |src_chan| {
                    return self.chanToValue(src_chan);
                }
            }
            if (self.readRefObj(chan)) |header| {
                if (header.type_tag == .lazy_val) {
                    const lazy: *value.LazyValue = @alignCast(@fieldParentPtr("header", header));
                    return try self.forceLazyValue(lazy);
                }
                return value.Value.fromRef(header);
            }
            // readRefObj 失败：ref_chan 持有标量位模式
            const raw = self.runtime.readI64(chan);
            if (raw == 0) return value.Value.fromNull();
            return value.Value.fromI64(raw);
        }
        // 其余所有类型（整数/浮点/bool/char/null/unit/mask/nullable）复用 chanToValue，
        // 它已对全部 23 种 ChanType 穷举派发，避免按位宽派发丢失类型语义。
        return self.chanToValue(chan);
    }

    /// 将标量值写入通道
    /// 将标量值写入通道（按通道类型写入，自动进行类型转换）
    /// 这样 i32 值写入 i64_chan 时会正确符号扩展，避免只写 4 字节导致垃圾值
    pub fn writeScalarValue(self: *Engine, chan: u16, v: value.Value) void {
        const meta = self.ir.channels.get(chan);
        switch (meta.chan_type) {
            .ref_chan => {
                const ptr: *i64 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                switch (v) {
                    .ref => |r| self.runtime.writePtr(chan, @ptrCast(r)),
                    .null_val, .unit => self.runtime.writePtr(chan, null),
                    // 标量值写入 ref_chan（类型参数实例化为标量时）：
                    // 整数符号扩展为 i64，浮点提升为 f64，写入完整 8 字节
                    .i8 => |b| ptr.* = @as(i64, @as(i8, @bitCast(b[0]))),
                    .u8 => |b| ptr.* = @as(i64, b[0]),
                    .i16 => |b| ptr.* = @as(i64, @as(i16, @bitCast(b))),
                    .u16 => |b| ptr.* = @as(i64, @as(u16, @bitCast(b))),
                    .i32 => |b| ptr.* = @as(i64, @as(i32, @bitCast(b))),
                    .u32 => |b| ptr.* = @as(i64, @as(u32, @bitCast(b))),
                    .i64 => |b| ptr.* = @bitCast(b),
                    .u64 => |b| ptr.* = @bitCast(@as(u64, @bitCast(b))),
                    .isize => |b| ptr.* = @as(i64, @as(isize, @bitCast(b))),
                    .usize => |b| ptr.* = @bitCast(@as(u64, @as(usize, @bitCast(b)))),
                    .boolean => |b| ptr.* = @intFromBool(b[0] != 0),
                    .char => |b| ptr.* = @as(i64, @intCast(@as(u32, @bitCast(b)))),
                    .f16 => |b| ptr.* = @bitCast(@as(f64, @floatCast(@as(f16, @bitCast(b))))),
                    .f32 => |b| ptr.* = @bitCast(@as(f64, @floatCast(@as(f32, @bitCast(b))))),
                    .f64 => |b| ptr.* = @bitCast(@as(f64, @bitCast(b))),
                    // i128/u128/f128（16 字节）无法塞入 8 字节 ref_chan：
                    // 截断到 64 位（lossy），完整值需走具体标量通道（i128_chan 等）
                    .i128 => |b| ptr.* = @truncate(@as(i128, @bitCast(b))),
                    .u128 => |b| ptr.* = @bitCast(@as(u64, @truncate(@as(u128, @bitCast(b))))),
                    .f128 => |b| ptr.* = @bitCast(@as(f64, @floatCast(@as(f128, @bitCast(b))))),
                }
            },
            .bool_chan, .mask_chan => {
                const b: bool = switch (v) {
                    .boolean => |bb| bb[0] != 0,
                    .i64 => |bb| @as(i64, @bitCast(bb)) != 0,
                    .i32 => |bb| @as(i32, @bitCast(bb)) != 0,
                    .u64 => |bb| @as(u64, @bitCast(bb)) != 0,
                    .u32 => |bb| @as(u32, @bitCast(bb)) != 0,
                    else => false,
                };
                self.runtime.writeBool(chan, b);
            },
            .char_chan => {
                const cp: u32 = switch (v) {
                    .char => |b| @bitCast(b),
                    .i32 => |b| @bitCast(@as(i32, @bitCast(b))),
                    .u32 => |b| @bitCast(b),
                    .i64 => |b| @truncate(@as(u64, @bitCast(b))),
                    .u64 => |b| @truncate(@as(u64, @bitCast(b))),
                    .boolean => |b| @intFromBool(b[0] != 0),
                    else => 0,
                };
                const ptr: *u32 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = cp;
            },
            .i64_chan, .u64_chan, .isize_chan, .usize_chan => {
                const i: i64 = switch (v) {
                    .i64 => |b| @as(i64, @bitCast(b)),
                    .i32 => |b| @as(i64, @as(i32, @bitCast(b))),
                    .i16 => |b| @as(i64, @as(i16, @bitCast(b))),
                    .i8 => |b| @as(i64, @as(i8, @bitCast(b[0]))),
                    .u64 => |b| @bitCast(@as(u64, @bitCast(b))),
                    .u32 => |b| @as(i64, @as(u32, @bitCast(b))),
                    .u16 => |b| @as(i64, @as(u16, @bitCast(b))),
                    .u8 => |b| @as(i64, b[0]),
                    .i128 => |b| @truncate(@as(i128, @bitCast(b))),
                    .u128 => |b| @bitCast(@as(u64, @truncate(@as(u128, @bitCast(b))))),
                    .isize => |b| @as(i64, @as(isize, @bitCast(b))),
                    .usize => |b| @bitCast(@as(usize, @bitCast(b))),
                    .boolean => |b| @intFromBool(b[0] != 0),
                    .null_val, .unit => 0,
                    .ref => |r| @intCast(@intFromPtr(r)),
                    .f32 => |b| @intFromFloat(@as(f32, @bitCast(b))),
                    .f64 => |b| @intFromFloat(@as(f64, @bitCast(b))),
                    .f16 => |b| @intFromFloat(@as(f16, @bitCast(b))),
                    .f128 => |b| @intFromFloat(@as(f128, @bitCast(b))),
                    else => 0,
                };
                self.runtime.writeI64(chan, @bitCast(i));
            },
            .i32_chan, .u32_chan => {
                const i: i32 = switch (v) {
                    .i32 => |b| @as(i32, @bitCast(b)),
                    .i64 => |b| @truncate(@as(i64, @bitCast(b))),
                    .i16 => |b| @as(i32, @as(i16, @bitCast(b))),
                    .i8 => |b| @as(i32, @as(i8, @bitCast(b[0]))),
                    .u32 => |b| @bitCast(@as(u32, @bitCast(b))),
                    .u16 => |b| @as(i32, @as(u16, @bitCast(b))),
                    .u8 => |b| @as(i32, b[0]),
                    .u64 => |b| @truncate(@as(i64, @bitCast(@as(u64, @bitCast(b))))),
                    .i128 => |b| @truncate(@as(i128, @bitCast(b))),
                    .u128 => |b| @bitCast(@as(u32, @truncate(@as(u128, @bitCast(b))))),
                    .usize => |b| @truncate(@as(i64, @bitCast(@as(usize, @bitCast(b))))),
                    .isize => |b| @truncate(@as(i64, @as(isize, @bitCast(b)))),
                    .boolean => |b| @intFromBool(b[0] != 0),
                    .null_val, .unit => 0,
                    .f32 => |b| @intFromFloat(@as(f32, @bitCast(b))),
                    .f64 => |b| @intFromFloat(@as(f64, @bitCast(b))),
                    .f16 => |b| @intFromFloat(@as(f16, @bitCast(b))),
                    .f128 => |b| @intFromFloat(@as(f128, @bitCast(b))),
                    else => 0,
                };
                const ptr: *i32 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = i;
            },
            .i16_chan, .u16_chan => {
                const i: i16 = switch (v) {
                    .i16 => |b| @as(i16, @bitCast(b)),
                    .i32 => |b| @truncate(@as(i32, @bitCast(b))),
                    .i64 => |b| @truncate(@as(i64, @bitCast(b))),
                    .u16 => |b| @bitCast(@as(u16, @bitCast(b))),
                    .u32 => |b| @truncate(@as(i32, @bitCast(@as(u32, @bitCast(b))))),
                    .u64 => |b| @truncate(@as(i64, @bitCast(@as(u64, @bitCast(b))))),
                    .i128 => |b| @truncate(@as(i128, @bitCast(b))),
                    .u128 => |b| @bitCast(@as(u16, @truncate(@as(u128, @bitCast(b))))),
                    .usize => |b| @truncate(@as(i64, @bitCast(@as(usize, @bitCast(b))))),
                    .isize => |b| @truncate(@as(i64, @as(isize, @bitCast(b)))),
                    .u8 => |b| @as(i16, b[0]),
                    .i8 => |b| @as(i16, @as(i8, @bitCast(b[0]))),
                    .boolean => |b| @intFromBool(b[0] != 0),
                    .f32 => |b| @intFromFloat(@as(f32, @bitCast(b))),
                    .f64 => |b| @intFromFloat(@as(f64, @bitCast(b))),
                    .f16 => |b| @intFromFloat(@as(f16, @bitCast(b))),
                    .f128 => |b| @intFromFloat(@as(f128, @bitCast(b))),
                    else => 0,
                };
                const ptr: *i16 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = i;
            },
            .i8_chan, .u8_chan => {
                const b_val: u8 = switch (v) {
                    .i8 => |b| b[0],
                    .u8 => |b| b[0],
                    .i16 => |b| @truncate(@as(u16, @bitCast(b))),
                    .i32 => |b| @truncate(@as(u32, @bitCast(b))),
                    .i64 => |b| @truncate(@as(u64, @bitCast(b))),
                    .u16 => |b| @truncate(@as(u16, @bitCast(b))),
                    .u32 => |b| @truncate(@as(u32, @bitCast(b))),
                    .u64 => |b| @truncate(@as(u64, @bitCast(b))),
                    .i128 => |b| @bitCast(@as(u8, @truncate(@as(u128, @bitCast(@as(i128, @bitCast(b))))))),
                    .u128 => |b| @truncate(@as(u128, @bitCast(b))),
                    .usize => |b| @truncate(@as(usize, @bitCast(b))),
                    .isize => |b| @truncate(@as(usize, @bitCast(@as(isize, @bitCast(b))))),
                    .boolean => |b| b[0],
                    .f32 => |b| @intFromFloat(@as(f32, @bitCast(b))),
                    .f64 => |b| @intFromFloat(@as(f64, @bitCast(b))),
                    .f16 => |b| @intFromFloat(@as(f16, @bitCast(b))),
                    .f128 => |b| @intFromFloat(@as(f128, @bitCast(b))),
                    else => 0,
                };
                self.runtime.rawPtr(chan)[0] = b_val;
            },
            .f64_chan => {
                const f: f64 = switch (v) {
                    .f64 => |b| @bitCast(b),
                    .f32 => |b| @floatCast(@as(f32, @bitCast(b))),
                    .f16 => |b| @floatCast(@as(f16, @bitCast(b))),
                    .f128 => |b| @floatCast(@as(f128, @bitCast(b))),
                    .i8 => |b| @floatFromInt(@as(i8, @bitCast(b[0]))),
                    .i16 => |b| @floatFromInt(@as(i16, @bitCast(b))),
                    .i32 => |b| @floatFromInt(@as(i32, @bitCast(b))),
                    .i64 => |b| @floatFromInt(@as(i64, @bitCast(b))),
                    .i128 => |b| @floatFromInt(@as(i128, @bitCast(b))),
                    .u8 => |b| @floatFromInt(b[0]),
                    .u16 => |b| @floatFromInt(@as(u16, @bitCast(b))),
                    .u32 => |b| @floatFromInt(@as(u32, @bitCast(b))),
                    .u64 => |b| @floatFromInt(@as(u64, @bitCast(b))),
                    .u128 => |b| @floatFromInt(@as(u128, @bitCast(b))),
                    .boolean => |b| @floatFromInt(@intFromBool(b[0] != 0)),
                    else => 0,
                };
                const ptr: *f64 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = f;
            },
            .f32_chan => {
                const f: f32 = switch (v) {
                    .f32 => |b| @bitCast(b),
                    .f64 => |b| @floatCast(@as(f64, @bitCast(b))),
                    .f16 => |b| @floatCast(@as(f16, @bitCast(b))),
                    .f128 => |b| @floatCast(@as(f128, @bitCast(b))),
                    .i8 => |b| @floatFromInt(@as(i8, @bitCast(b[0]))),
                    .i16 => |b| @floatFromInt(@as(i16, @bitCast(b))),
                    .i32 => |b| @floatFromInt(@as(i32, @bitCast(b))),
                    .i64 => |b| @floatFromInt(@as(i64, @bitCast(b))),
                    .i128 => |b| @floatFromInt(@as(i128, @bitCast(b))),
                    .u8 => |b| @floatFromInt(b[0]),
                    .u16 => |b| @floatFromInt(@as(u16, @bitCast(b))),
                    .u32 => |b| @floatFromInt(@as(u32, @bitCast(b))),
                    .u64 => |b| @floatFromInt(@as(u64, @bitCast(b))),
                    .u128 => |b| @floatFromInt(@as(u128, @bitCast(b))),
                    .boolean => |b| @floatFromInt(@intFromBool(b[0] != 0)),
                    else => 0,
                };
                const ptr: *f32 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = f;
            },
            .f16_chan => {
                const f: f16 = switch (v) {
                    .f16 => |b| @bitCast(b),
                    .f32 => |b| @floatCast(@as(f32, @bitCast(b))),
                    .f64 => |b| @floatCast(@as(f64, @bitCast(b))),
                    .f128 => |b| @floatCast(@as(f128, @bitCast(b))),
                    .i8 => |b| @floatFromInt(@as(i8, @bitCast(b[0]))),
                    .i16 => |b| @floatFromInt(@as(i16, @bitCast(b))),
                    .i32 => |b| @floatFromInt(@as(i32, @bitCast(b))),
                    .i64 => |b| @floatFromInt(@as(i64, @bitCast(b))),
                    .i128 => |b| @floatFromInt(@as(i128, @bitCast(b))),
                    .u8 => |b| @floatFromInt(b[0]),
                    .u16 => |b| @floatFromInt(@as(u16, @bitCast(b))),
                    .u32 => |b| @floatFromInt(@as(u32, @bitCast(b))),
                    .u64 => |b| @floatFromInt(@as(u64, @bitCast(b))),
                    .u128 => |b| @floatFromInt(@as(u128, @bitCast(b))),
                    .boolean => |b| @floatFromInt(@intFromBool(b[0] != 0)),
                    else => 0,
                };
                const ptr: *f16 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = f;
            },
            .f128_chan => {
                const f: f128 = switch (v) {
                    .f128 => |b| @bitCast(b),
                    .f16 => |b| @floatCast(@as(f16, @bitCast(b))),
                    .f32 => |b| @floatCast(@as(f32, @bitCast(b))),
                    .f64 => |b| @floatCast(@as(f64, @bitCast(b))),
                    .i8 => |b| @floatFromInt(@as(i8, @bitCast(b[0]))),
                    .i16 => |b| @floatFromInt(@as(i16, @bitCast(b))),
                    .i32 => |b| @floatFromInt(@as(i32, @bitCast(b))),
                    .i64 => |b| @floatFromInt(@as(i64, @bitCast(b))),
                    .i128 => |b| @floatFromInt(@as(i128, @bitCast(b))),
                    .u8 => |b| @floatFromInt(b[0]),
                    .u16 => |b| @floatFromInt(@as(u16, @bitCast(b))),
                    .u32 => |b| @floatFromInt(@as(u32, @bitCast(b))),
                    .u64 => |b| @floatFromInt(@as(u64, @bitCast(b))),
                    .u128 => |b| @floatFromInt(@as(u128, @bitCast(b))),
                    .boolean => |b| @floatFromInt(@intFromBool(b[0] != 0)),
                    else => 0,
                };
                const ptr: *f128 = @ptrCast(@alignCast(self.runtime.rawPtr(chan)));
                ptr.* = f;
            },
            .i128_chan, .u128_chan => {
                // i128/u128 通道：按 16 字节原样拷贝标量位模式
                const w = meta.elem_width;
                const src: [*]const u8 = @ptrCast(&v);
                const dst = self.runtime.rawPtr(chan);
                @memcpy(dst[0..w], src[0..w]);
            },
            else => {
                // null/unit/char/nullable 等：按字节拷贝
                const w = meta.elem_width;
                if (w > 0 and w <= 16) {
                    const src: [*]const u8 = @ptrCast(&v);
                    const dst = self.runtime.rawPtr(chan);
                    @memcpy(dst[0..w], src[0..w]);
                }
            },
        }
    }

    /// 将标量 Value 转为字节缓冲区（用于 nullable 写入）
    pub fn readScalarValueToBytes(self: *Engine, v: value.Value) [16]u8 {
        _ = self;
        var buf: [16]u8 = [_]u8{0} ** 16;
        switch (v) {
            .i64 => |b| {
                const val: i64 = @bitCast(b);
                @memcpy(buf[0..8], std.mem.asBytes(&val));
            },
            .i32 => |b| {
                const val: i32 = @bitCast(b);
                @memcpy(buf[0..4], std.mem.asBytes(&val));
            },
            .boolean => |b| buf[0] = b[0],
            else => {},
        }
        return buf;
    }
};
