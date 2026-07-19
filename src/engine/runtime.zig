//! 通道运行时存储
//!
//! ChannelSpace 只管理通道的元信息（类型/宽度），实际数据存储由 ChannelRegion 承载。
//! Runtime 负责在执行前为每个通道在 ChannelRegion 中分配存储空间，并提供读写接口。
//!
//! 设计要点：
//! - 通道数据在 ChannelRegion 中按 elem_width 连续分配
//! - 64B 对齐满足 SIMD（AVX-512）
//! - 函数级 reset（基本块结束 O(1) 释放）
//! - 通道索引 → 数据指针映射表（启动时一次性构建）

const std = @import("std");
const ir_mod = @import("ir");
const mem = @import("mem");
const value = @import("value");
const scalar = value.scalar;

const ChannelRegion = mem.ChannelRegion;
const ChannelSpace = ir_mod.ChannelSpace;
const ChanType = ir_mod.ChanType;
const ConstVal = ir_mod.ConstVal;
const ScalarMeta = ir_mod.ScalarMeta;
const ScalarKind = ir_mod.ScalarKind;

/// 通道运行时存储：管理所有通道的实际数据
///
/// 执行前调用 `layout()` 为每个通道分配存储空间，构建索引→指针映射。
/// 执行期间通过 `read*` / `write*` 读写通道值。
pub const Runtime = struct {
    /// 每个通道的数据指针（指向 ChannelRegion 中的内存）
    /// 标量通道：1 个元素；向量通道：多个元素（由调用方管理长度）
    /// null 表示无数据通道（unit/null 类型）
    chan_ptrs: []?[*]u8 = &.{},
    /// 每个通道的元素宽度（字节）
    chan_widths: []u8 = &.{},
    /// 每个通道的元素数量（标量=1，向量=N）
    chan_lengths: []u32 = &.{},
    /// 通道总数
    chan_count: u16 = 0,
    /// ChannelRegion 引用（数据存储）
    region: *ChannelRegion,
    /// backing allocator（用于 chan_ptrs/chan_widths 数组）
    backing: std.mem.Allocator,

    /// 初始化运行时
    pub fn init(region: *ChannelRegion, backing: std.mem.Allocator) Runtime {
        return .{
            .region = region,
            .backing = backing,
        };
    }

    /// 释放运行时资源（不释放 ChannelRegion，由所有者管理）
    pub fn deinit(self: *Runtime) void {
        if (self.chan_ptrs.len > 0) self.backing.free(self.chan_ptrs);
        if (self.chan_widths.len > 0) self.backing.free(self.chan_widths);
        if (self.chan_lengths.len > 0) self.backing.free(self.chan_lengths);
    }

    /// 布局：根据 ChannelSpace 为每个通道分配存储
    /// 必须在执行前调用一次
    pub fn layout(self: *Runtime, channels: *const ChannelSpace) !void {
        const n = channels.count();
        self.chan_count = n;
        self.chan_ptrs = try self.backing.alloc(?[*]u8, n);
        self.chan_widths = try self.backing.alloc(u8, n);
        self.chan_lengths = try self.backing.alloc(u32, n);

        for (0..n) |i| {
            const meta = channels.get(@intCast(i));
            self.chan_widths[i] = meta.elem_width;
            self.chan_lengths[i] = 1; // 默认标量模式
            if (meta.elem_width == 0) {
                self.chan_ptrs[i] = null;
            } else {
                const buf = try self.region.alloc(meta.elem_width);
                @memset(buf, 0);
                self.chan_ptrs[i] = buf.ptr;
                // ChannelRegion 扩容后需 rebase 所有已分配的通道指针
                if (self.region.rebase_info) |ri| {
                    for (self.chan_ptrs[0 .. i + 1]) |*ptr| {
                        if (ptr.*) |p| {
                            const addr = @intFromPtr(p);
                            if (addr >= ri.old_base and addr < ri.old_end) {
                                const new_addr: usize = if (ri.offset >= 0)
                                    addr + @as(usize, @intCast(ri.offset))
                                else
                                    addr - @as(usize, @intCast(-ri.offset));
                                ptr.* = @ptrFromInt(new_addr);
                            }
                        }
                    }
                    self.region.rebase_info = null;
                }
            }
        }
    }

    // ════════════════════════════════════════════
    // 标量读写接口
    // ════════════════════════════════════════════

    /// 读取 i64 值
    pub inline fn readI64(self: *Runtime, chan: u16) i64 {
        const ptr: *i64 = @ptrCast(@alignCast(self.chan_ptrs[chan].?));
        return ptr.*;
    }

    /// 写入 i64 值
    pub inline fn writeI64(self: *Runtime, chan: u16, val: i64) void {
        const ptr: *i64 = @ptrCast(@alignCast(self.chan_ptrs[chan].?));
        ptr.* = val;
    }

    /// 读取 u64 值
    pub inline fn readU64(self: *Runtime, chan: u16) u64 {
        const ptr: *u64 = @ptrCast(@alignCast(self.chan_ptrs[chan].?));
        return ptr.*;
    }

    /// 写入 u64 值
    pub inline fn writeU64(self: *Runtime, chan: u16, val: u64) void {
        const ptr: *u64 = @ptrCast(@alignCast(self.chan_ptrs[chan].?));
        ptr.* = val;
    }

    /// 读取 usize 值
    pub inline fn readUsize(self: *Runtime, chan: u16) usize {
        const ptr: *usize = @ptrCast(@alignCast(self.chan_ptrs[chan].?));
        return ptr.*;
    }

    /// 写入 usize 值（Phase 5: .len() 返回类型从 i64 改为 usize）
    pub inline fn writeUsize(self: *Runtime, chan: u16, val: usize) void {
        const ptr: *usize = @ptrCast(@alignCast(self.chan_ptrs[chan].?));
        ptr.* = val;
    }

    /// 读取 f64 值
    pub inline fn readF64(self: *Runtime, chan: u16) f64 {
        const ptr: *f64 = @ptrCast(@alignCast(self.chan_ptrs[chan].?));
        return ptr.*;
    }

    /// 写入 f64 值
    pub inline fn writeF64(self: *Runtime, chan: u16, val: f64) void {
        const ptr: *f64 = @ptrCast(@alignCast(self.chan_ptrs[chan].?));
        ptr.* = val;
    }

    /// 读取 bool 值
    pub inline fn readBool(self: *Runtime, chan: u16) bool {
        const ptr: *u8 = @ptrCast(@alignCast(self.chan_ptrs[chan].?));
        return ptr.* != 0;
    }

    /// 写入 bool 值
    pub inline fn writeBool(self: *Runtime, chan: u16, val: bool) void {
        const ptr: *u8 = @ptrCast(@alignCast(self.chan_ptrs[chan].?));
        ptr.* = if (val) 1 else 0;
    }

    /// 读取堆对象指针（ref_chan）
    pub inline fn readPtr(self: *Runtime, chan: u16) ?*anyopaque {
        const ptr: *?*anyopaque = @ptrCast(@alignCast(self.chan_ptrs[chan].?));
        return ptr.*;
    }

    /// 写入堆对象指针（ref_chan）
    pub inline fn writePtr(self: *Runtime, chan: u16, val: ?*anyopaque) void {
        const ptr: *?*anyopaque = @ptrCast(@alignCast(self.chan_ptrs[chan].?));
        ptr.* = val;
    }

    /// 泛型标量读取（指定通道）：按 comptime tag 直接指针读写，跳过 16B 中间缓冲
    /// 覆盖所有 int/uint/float 类型，零 memcpy
    pub fn readScalarAt(self: *Runtime, comptime tag: scalar.ScalarTag, chan: u16) scalar.NativeType(tag) {
        const T = scalar.NativeType(tag);
        const ptr: *T = @ptrCast(@alignCast(self.chan_ptrs[chan].?));
        return ptr.*;
    }

    /// 泛型标量写入（指定通道）
    pub fn writeScalarAt(self: *Runtime, comptime tag: scalar.ScalarTag, chan: u16, val: scalar.NativeType(tag)) void {
        const T = scalar.NativeType(tag);
        const ptr: *T = @ptrCast(@alignCast(self.chan_ptrs[chan].?));
        ptr.* = val;
    }

    /// 读取原始字节指针（用于通用访问）
    pub inline fn rawPtr(self: *Runtime, chan: u16) [*]u8 {
        return self.chan_ptrs[chan].?;
    }

    /// 获取通道元素宽度
    pub inline fn elemWidth(self: *Runtime, chan: u16) u8 {
        return self.chan_widths[chan];
    }

    // ════════════════════════════════════════════
    // 向量读写接口
    // ════════════════════════════════════════════

    /// 为通道分配向量缓冲区（覆盖标量缓冲区，旧缓冲区随 region reset 释放）
    pub fn allocVector(self: *Runtime, chan: u16, count: u32) !void {
        const w = self.chan_widths[chan];
        if (w == 0 or count == 0) {
            self.chan_lengths[chan] = 0;
            return;
        }
        const buf = try self.region.alloc(w * @as(usize, count));
        self.chan_ptrs[chan] = buf.ptr;
        self.chan_lengths[chan] = count;
        // 扩容可能使其他通道指针失效（旧 data 被释放），需要 rebase
        if (self.region.rebase_info) |ri| {
            for (self.chan_ptrs) |*ptr| {
                if (ptr.*) |p| {
                    const addr = @intFromPtr(p);
                    if (addr >= ri.old_base and addr < ri.old_end) {
                        const new_addr: usize = if (ri.offset >= 0)
                            addr + @as(usize, @intCast(ri.offset))
                        else
                            addr - @as(usize, @intCast(-ri.offset));
                        ptr.* = @ptrFromInt(new_addr);
                    }
                }
            }
            self.region.rebase_info = null;
        }
    }

    /// 获取通道元素数量（标量=1，向量=N）
    pub fn vectorLen(self: *Runtime, chan: u16) u32 {
        return self.chan_lengths[chan];
    }

    /// 获取向量元素的原始指针
    pub fn vectorElemPtr(self: *Runtime, chan: u16, index: usize) [*]u8 {
        const w = self.chan_widths[chan];
        return self.chan_ptrs[chan].? + index * w;
    }

    /// 读取向量第 i 个元素为 i64
    pub fn readVectorI64(self: *Runtime, chan: u16, index: usize) i64 {
        const ptr: *i64 = @ptrCast(@alignCast(self.chan_ptrs[chan].? + index * 8));
        return ptr.*;
    }

    /// 写入 i64 到向量第 i 个位置
    pub fn writeVectorI64(self: *Runtime, chan: u16, index: usize, val: i64) void {
        const ptr: *i64 = @ptrCast(@alignCast(self.chan_ptrs[chan].? + index * 8));
        ptr.* = val;
    }

    /// 临时设置通道为标量模式（指向向量中的某个元素）
    pub fn pinToElement(self: *Runtime, chan: u16, vec_chan: u16, index: usize) void {
        const w = self.chan_widths[vec_chan];
        self.chan_ptrs[chan] = self.chan_ptrs[vec_chan].? + index * w;
        self.chan_lengths[chan] = 1;
    }

    // ════════════════════════════════════════════
    // 常量初始化
    // ════════════════════════════════════════════

    /// 从 ConstVal 初始化通道值
    pub fn writeConst(self: *Runtime, chan: u16, const_val: ConstVal, kind: ScalarKind) void {
        switch (const_val) {
            .int_val => |v| {
                // 按通道实际宽度截断存储（使用 @truncate 处理超出范围的值）
                const w = self.chan_widths[chan];
                switch (w) {
                    1 => {
                        const ptr: *i8 = @ptrCast(@alignCast(self.chan_ptrs[chan].?));
                        ptr.* = @truncate(v);
                    },
                    2 => {
                        const ptr: *i16 = @ptrCast(@alignCast(self.chan_ptrs[chan].?));
                        ptr.* = @truncate(v);
                    },
                    4 => {
                        const ptr: *i32 = @ptrCast(@alignCast(self.chan_ptrs[chan].?));
                        ptr.* = @truncate(v);
                    },
                    8 => {
                        const ptr: *i64 = @ptrCast(@alignCast(self.chan_ptrs[chan].?));
                        ptr.* = @truncate(v);
                    },
                    16 => {
                        const ptr: *i128 = @ptrCast(@alignCast(self.chan_ptrs[chan].?));
                        ptr.* = v;
                    },
                    else => {},
                }
            },
            .float_val => |bits| {
                const w = self.chan_widths[chan];
                switch (w) {
                    2 => {
                        const ptr: *f16 = @ptrCast(@alignCast(self.chan_ptrs[chan].?));
                        ptr.* = @bitCast(@as(u16, @truncate(bits)));
                    },
                    4 => {
                        const ptr: *f32 = @ptrCast(@alignCast(self.chan_ptrs[chan].?));
                        ptr.* = @bitCast(@as(u32, @truncate(bits)));
                    },
                    8 => {
                        const ptr: *f64 = @ptrCast(@alignCast(self.chan_ptrs[chan].?));
                        ptr.* = @bitCast(@as(u64, @truncate(bits)));
                    },
                    16 => {
                        const ptr: *f128 = @ptrCast(@alignCast(self.chan_ptrs[chan].?));
                        ptr.* = @bitCast(bits);
                    },
                    else => {},
                }
            },
            .bool_val => |v| self.writeBool(chan, v),
            .char_val => |v| {
                // char_chan 宽度为 4 字节，用 u32 写入（u21 只有 3 字节，会留下垃圾）
                const ptr: *u32 = @ptrCast(@alignCast(self.chan_ptrs[chan].?));
                ptr.* = @intCast(v);
            },
        }
        _ = kind;
    }
};

// ════════════════════════════════════════════════════════════════
// 测试
// ════════════════════════════════════════════════════════════════

const testing = std.testing;

test "Runtime 布局与标量读写" {
    var region = ChannelRegion.init(testing.allocator);
    defer region.deinit();

    var channels = ChannelSpace.init(testing.allocator);
    defer channels.deinit();

    const ch0 = try channels.alloc(.i64_chan);
    const ch1 = try channels.alloc(.f64_chan);
    const ch2 = try channels.alloc(.bool_chan);

    var rt = Runtime.init(&region, testing.allocator);
    defer rt.deinit();
    try rt.layout(&channels);

    rt.writeI64(ch0, 42);
    try testing.expectEqual(@as(i64, 42), rt.readI64(ch0));

    rt.writeF64(ch1, 3.14);
    try testing.expectEqual(@as(f64, 3.14), rt.readF64(ch1));

    rt.writeBool(ch2, true);
    try testing.expect(rt.readBool(ch2));
}

test "Runtime writeConst 整数" {
    var region = ChannelRegion.init(testing.allocator);
    defer region.deinit();

    var channels = ChannelSpace.init(testing.allocator);
    defer channels.deinit();

    const ch = try channels.alloc(.i32_chan);

    var rt = Runtime.init(&region, testing.allocator);
    defer rt.deinit();
    try rt.layout(&channels);

    rt.writeConst(ch, .{ .int_val = 123 }, .int);
    const ptr: *i32 = @ptrCast(@alignCast(rt.rawPtr(ch)));
    try testing.expectEqual(@as(i32, 123), ptr.*);
}

test "Runtime writeConst 浮点" {
    var region = ChannelRegion.init(testing.allocator);
    defer region.deinit();

    var channels = ChannelSpace.init(testing.allocator);
    defer channels.deinit();

    const ch = try channels.alloc(.f64_chan);

    var rt = Runtime.init(&region, testing.allocator);
    defer rt.deinit();
    try rt.layout(&channels);

    const val: f64 = 2.718;
    const bits: u64 = @bitCast(val);
    rt.writeConst(ch, .{ .float_val = @as(u128, bits) }, .float);
    try testing.expectEqual(val, rt.readF64(ch));
}
