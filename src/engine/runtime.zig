//! 通道运行时存储
//!
//! ChannelSpace 只管理通道的元信息（类型/宽度），实际数据存储由 ChannelRegion 承载。
//! Runtime 负责在执行前为每个通道在 ChannelRegion 中分配存储空间，并提供读写接口。
//!
//! 设计要点（双 Region 模型）：
//! - GlobalRegion：存储全局通道（程序级），layout 一次，永不 reset
//! - CallStackRegion：存储函数级通道，bump + resetTo 实现函数级回收
//! - chan_ptrs/chan_widths/chan_lengths 数组覆盖所有通道（保留以兼容 engine.zig）
//! - enterFunction 设置本地通道的 chan_ptrs 指向 per-frame region，并保存 caller 的指针
//! - leaveFunction 恢复 caller 的 chan_ptrs 并 resetTo 回收本帧内存

const std = @import("std");
const ir_mod = @import("ir");
const mem = @import("mem");
const value = @import("value");
const profiling = @import("profiling");
const scalar = value.scalar;

const ChannelRegion = mem.ChannelRegion;
const ChannelSpace = ir_mod.ChannelSpace;
const ChanType = ir_mod.ChanType;
const ConstVal = ir_mod.ConstVal;
const ScalarMeta = ir_mod.ScalarMeta;
const ScalarKind = ir_mod.ScalarKind;
const Function = ir_mod.Function;
const ThreadProfiler = profiling.ThreadProfiler;

/// 帧上下文：每次函数调用压栈一次
pub const FrameContext = struct {
    // TCO 检测和 backtrace
    func_idx: u16 = 0,
    return_chan: u16 = 0,
    return_pc: u32 = 0,
    // region 管理
    caller_frame_offset: usize = 0,
    caller_func: ?*const Function = null,
    // saved_ptrs/saved_lengths 的信息（从 CallStackRegion 分配）
    saved_ptrs_base: usize = 0, // [*]?[*]u8 的地址
    saved_lengths_base: usize = 0, // [*]u32 的地址
    saved_chan_count: u16 = 0, // 保存的通道数（local_chan_count + 1）
    saved_chan_start: u16 = 0, // 保存的通道起始索引
    saved_return_channel: u16 = 0, // return_channel 索引
};

/// 通道运行时存储：管理所有通道的实际数据
///
/// 双 Region 模型：
/// - global_region：全局通道（程序级生命周期），由所有者管理
/// - call_region：函数级通道（bump + resetTo），由所有者管理
///
/// chan_ptrs/chan_widths/chan_lengths 数组覆盖所有通道：
/// - 全局通道在 layoutGlobals 中设置，指向 global_region
/// - 本地通道在 enterFunction 中设置，指向 call_region 中的 per-frame 内存
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
    /// backing allocator（用于 chan_ptrs/chan_widths 数组）
    backing: std.mem.Allocator,
    /// ThreadProfiler 引用（channel 分配水位埋点）
    prof: ?*ThreadProfiler = null,

    // ── GlobalRegion ──
    global_ptrs: []?[*]u8 = &.{},
    global_widths: []u8 = &.{},
    global_lengths: []u32 = &.{},
    global_count: u16 = 0,
    global_region: *ChannelRegion,

    // ── CallStackRegion ──
    call_region: *ChannelRegion,
    current_frame_offset: usize = 0,

    // ── FrameStack ──
    frame_stack: []FrameContext = &.{},
    call_depth: u32 = 0,
    current_func: ?*const Function = null,

    /// 初始化运行时
    /// global_region/call_region 由所有者管理，Runtime 不负责释放
    pub fn init(
        global_region: *ChannelRegion,
        call_region: *ChannelRegion,
        backing: std.mem.Allocator,
        prof: ?*ThreadProfiler,
    ) Runtime {
        return .{
            .global_region = global_region,
            .call_region = call_region,
            .backing = backing,
            .prof = prof,
        };
    }

    /// 释放运行时资源（不释放 global_region/call_region，由所有者管理）
    pub fn deinit(self: *Runtime) void {
        if (self.chan_ptrs.len > 0) self.backing.free(self.chan_ptrs);
        if (self.chan_widths.len > 0) self.backing.free(self.chan_widths);
        if (self.chan_lengths.len > 0) self.backing.free(self.chan_lengths);
        if (self.global_ptrs.len > 0) self.backing.free(self.global_ptrs);
        if (self.global_widths.len > 0) self.backing.free(self.global_widths);
        if (self.global_lengths.len > 0) self.backing.free(self.global_lengths);
        if (self.frame_stack.len > 0) self.backing.free(self.frame_stack);
    }

    /// 布局全局通道到 GlobalRegion
    /// 必须在执行前调用一次。本地通道的 chan_ptrs 在 enterFunction 中设置。
    pub fn layoutGlobals(self: *Runtime, channels: *const ChannelSpace) !void {
        const gc = channels.global_count;
        self.global_count = gc;
        self.chan_count = channels.count();

        // 分配 chan_ptrs/chan_widths/chan_lengths（覆盖所有通道）
        self.chan_ptrs = try self.backing.alloc(?[*]u8, self.chan_count);
        self.chan_widths = try self.backing.alloc(u8, self.chan_count);
        self.chan_lengths = try self.backing.alloc(u32, self.chan_count);
        @memset(self.chan_ptrs, null);
        @memset(self.chan_widths, 0);
        @memset(self.chan_lengths, 0);

        // 为所有通道设置宽度（通道宽度是静态元信息，不随函数调用变化）
        // 本地通道的 chan_ptrs 在 enterFunction 中设置，但 chan_widths 在此处一次性设置
        for (0..self.chan_count) |i| {
            const meta = channels.get(@intCast(i));
            self.chan_widths[i] = meta.elem_width;
        }

        if (gc == 0) return;

        self.global_ptrs = try self.backing.alloc(?[*]u8, gc);
        self.global_widths = try self.backing.alloc(u8, gc);
        self.global_lengths = try self.backing.alloc(u32, gc);

        for (0..gc) |i| {
            const meta = channels.get(@intCast(i));
            self.global_widths[i] = meta.elem_width;
            self.global_lengths[i] = 1;
            self.chan_widths[i] = meta.elem_width;
            self.chan_lengths[i] = 1;
            if (meta.elem_width == 0) {
                self.global_ptrs[i] = null;
                self.chan_ptrs[i] = null;
            } else {
                const buf = try self.global_region.alloc(meta.elem_width);
                // global_region 扩容后重基之前设置的 global_ptrs/chan_ptrs
                if (self.global_region.rebase_info) |ri| {
                    self.global_region.rebase_info = null;
                    const old_base = ri.old_base;
                    const old_end = ri.old_end;
                    const offset: i64 = ri.offset;
                    for (0..i) |j| {
                        if (self.global_ptrs[j]) |p| {
                            const addr = @intFromPtr(p);
                            if (addr >= old_base and addr < old_end) {
                                const new_addr = @as(usize, @bitCast(@as(i64, @bitCast(addr)) + offset));
                                self.global_ptrs[j] = @ptrFromInt(new_addr);
                                self.chan_ptrs[j] = @ptrFromInt(new_addr);
                            }
                        }
                    }
                }
                @memset(buf, 0);
                self.global_ptrs[i] = buf.ptr;
                self.chan_ptrs[i] = buf.ptr;
            }
        }

        // 记录 channel 总水位（global_region + call_region，此时 call_region 为空）
        if (self.prof) |p| p.recordAllocatorWatermark(.channel, self.global_region.used + self.call_region.used, true);
    }

    /// 检查 call_region 是否扩容，如果扩容则重基所有指向 call_region 的指针。
    /// call_region 扩容后旧内存被释放，所有指向旧内存的 chan_ptrs 和 frame_stack 中的
    /// saved_ptrs_base/saved_lengths_base/saved 指针值都需要按 offset 重基。
    /// 必须在每次 call_region.alloc/allocAligned 后调用。
    fn rebaseIfNeeded(self: *Runtime) void {
        const ri = self.call_region.rebase_info orelse return;
        self.call_region.rebase_info = null;

        const old_base = ri.old_base;
        const old_end = ri.old_end;
        const offset: i64 = ri.offset;

        // 重基 chan_ptrs（指向 call_region 的本地通道指针）
        for (self.chan_ptrs) |*ptr| {
            if (ptr.*) |p| {
                const addr = @intFromPtr(p);
                if (addr >= old_base and addr < old_end) {
                    const new_addr = @as(usize, @bitCast(@as(i64, @bitCast(addr)) + offset));
                    ptr.* = @ptrFromInt(new_addr);
                }
            }
        }

        // 重基 frame_stack 条目
        for (0..self.call_depth) |i| {
            const frame = &self.frame_stack[i];
            // 重基 saved_ptrs_base 和 saved_lengths_base（指向 call_region 的地址）
            if (frame.saved_ptrs_base >= old_base and frame.saved_ptrs_base < old_end) {
                frame.saved_ptrs_base = @as(usize, @bitCast(@as(i64, @bitCast(frame.saved_ptrs_base)) + offset));
            }
            if (frame.saved_lengths_base >= old_base and frame.saved_lengths_base < old_end) {
                frame.saved_lengths_base = @as(usize, @bitCast(@as(i64, @bitCast(frame.saved_lengths_base)) + offset));
            }
            // 重基 saved_ptrs 中保存的指针值（这些是外层帧的 chan_ptrs，可能指向 call_region）
            const saved_ptrs: [*]?[*]u8 = @ptrFromInt(frame.saved_ptrs_base);
            for (0..frame.saved_chan_count) |j| {
                if (saved_ptrs[j]) |p| {
                    const addr = @intFromPtr(p);
                    if (addr >= old_base and addr < old_end) {
                        const new_addr = @as(usize, @bitCast(@as(i64, @bitCast(addr)) + offset));
                        saved_ptrs[j] = @ptrFromInt(new_addr);
                    }
                }
            }
        }
    }

    /// 函数入口：建立新帧
    /// 在 CallStackRegion 中分配本函数通道数据，设置 chan_ptrs 指向 per-frame 内存
    pub fn enterFunction(self: *Runtime, func_idx: u16, func: *const Function) !void {
        if (self.call_depth >= self.frame_stack.len) return error.CallDepthExceeded;

        const chan_count = @as(usize, func.local_chan_count) + 1; // +1 for return_channel

        // 在 CallStackRegion 中分配 saved_ptrs/saved_lengths（在通道数据之前）
        const saved_ptrs_size = std.mem.alignForward(usize, chan_count * @sizeOf(?[*]u8), 8);
        const saved_lengths_size = chan_count * @sizeOf(u32);
        const saved_total = std.mem.alignForward(usize, saved_ptrs_size + saved_lengths_size, 16);
        const saved_space = try self.call_region.allocAligned(saved_total, 16);
        // 扩容后重基所有指向 call_region 的指针（必须在保存 chan_ptrs 之前）
        self.rebaseIfNeeded();
        const saved_ptrs: [*]?[*]u8 = @ptrCast(@alignCast(saved_space.ptr));
        const saved_lengths: [*]u32 = @ptrCast(@alignCast(saved_space.ptr + saved_ptrs_size));

        // 保存被覆盖的 chan_ptrs/chan_lengths
        for (0..func.local_chan_count) |i| {
            const chan = func.local_chan_start + @as(u16, @intCast(i));
            saved_ptrs[i] = self.chan_ptrs[chan];
            saved_lengths[i] = self.chan_lengths[chan];
        }
        saved_ptrs[func.local_chan_count] = self.chan_ptrs[func.return_channel];
        saved_lengths[func.local_chan_count] = self.chan_lengths[func.return_channel];

        // 保存 frame_stack
        self.frame_stack[self.call_depth] = .{
            .func_idx = func_idx,
            .caller_frame_offset = self.current_frame_offset,
            .caller_func = self.current_func,
            .saved_ptrs_base = @intFromPtr(saved_ptrs),
            .saved_lengths_base = @intFromPtr(saved_lengths),
            .saved_chan_count = @intCast(chan_count),
            .saved_chan_start = func.local_chan_start,
            .saved_return_channel = func.return_channel,
        };
        self.call_depth += 1;

        // 在 CallStackRegion 中分配通道数据
        const alloc_bytes = func.scc_max_chan_bytes;
        if (alloc_bytes > 0) {
            const chan_bytes = try self.call_region.allocAligned(alloc_bytes, 16);
            // 扩容后重基所有指向 call_region 的指针（包括刚保存的 saved_ptrs）
            self.rebaseIfNeeded();
            @memset(chan_bytes, 0);

            // 设置本函数通道的 chan_ptrs/chan_lengths
            // chan_widths 已在 layoutGlobals 中为所有通道一次性设置（宽度是静态元信息）
            for (0..func.local_chan_count) |i| {
                const chan = func.local_chan_start + @as(u16, @intCast(i));
                self.chan_ptrs[chan] = chan_bytes.ptr + func.local_offsets[i];
                self.chan_lengths[chan] = 1;
            }
            // return_channel
            self.chan_ptrs[func.return_channel] = chan_bytes.ptr + func.local_offsets[func.local_chan_count];
            self.chan_lengths[func.return_channel] = 1;
        }

        // current_frame_offset 指向本帧 END（saved_space + 通道数据），
        // leaveFunction 的 resetTo(caller_frame_offset) 据此回收到调用者帧尾，
        // 避免后续分配覆盖调用者通道数据。
        self.current_frame_offset = self.call_region.used;
        self.current_func = func;

        if (self.prof) |p| p.recordAllocatorWatermark(.channel, self.global_region.used + self.call_region.used, true);
    }

    /// 函数出口：回收帧
    /// 恢复 caller 的 chan_ptrs/chan_lengths，resetTo 回收本帧内存
    pub fn leaveFunction(self: *Runtime) void {
        self.call_depth -= 1;
        const frame = self.frame_stack[self.call_depth];

        // 恢复 chan_ptrs/chan_lengths
        const saved_ptrs: [*]?[*]u8 = @ptrFromInt(frame.saved_ptrs_base);
        const saved_lengths: [*]u32 = @ptrFromInt(frame.saved_lengths_base);
        for (0..frame.saved_chan_count - 1) |i| {
            const chan = frame.saved_chan_start + @as(u16, @intCast(i));
            self.chan_ptrs[chan] = saved_ptrs[i];
            self.chan_lengths[chan] = saved_lengths[i];
        }
        self.chan_ptrs[frame.saved_return_channel] = saved_ptrs[frame.saved_chan_count - 1];
        self.chan_lengths[frame.saved_return_channel] = saved_lengths[frame.saved_chan_count - 1];

        // 恢复 current_frame_offset 和 current_func
        self.current_frame_offset = frame.caller_frame_offset;
        self.current_func = frame.caller_func;

        // resetTo 回收（包括 saved_ptrs/saved_lengths 和通道数据）
        const before_reset = self.call_region.used;
        self.call_region.resetTo(frame.caller_frame_offset);
        if (self.prof) |p| {
            const freed = before_reset - self.call_region.used;
            // reset 更新计数 + 零化 current_bytes，watermark 再设为 reset 后总和
            p.recordAllocatorReset(.channel, freed);
            p.recordAllocatorWatermark(.channel, self.global_region.used + self.call_region.used, false);
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
        const buf = try self.call_region.alloc(w * @as(usize, count));
        // 扩容后重基所有指向 call_region 的指针
        self.rebaseIfNeeded();
        // buf.ptr 可能在 rebase 后已失效（如果 buf 本身被重基），但 buf 是本次 alloc 的返回值，
        // 其地址基于新 data，不受 rebase 影响。不过 chan_ptrs 可能被 rebase 修改，需在 rebase 后赋值。
        self.chan_ptrs[chan] = buf.ptr;
        self.chan_lengths[chan] = count;
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
                // float_val 存储的是 f64 位模式（u128 低 64 位）。
                // 必须先还原为 f64 值，再通过 @floatCast 做值转换到目标宽度。
                // 旧实现用 @truncate 截取位模式再 @bitCast 是位截断，会导致
                // f64→f32 时取到 f64 位模式的低 32 位（垃圾值）。
                const w = self.chan_widths[chan];
                const f64_val: f64 = @bitCast(@as(u64, @truncate(bits)));
                switch (w) {
                    2 => {
                        const ptr: *f16 = @ptrCast(@alignCast(self.chan_ptrs[chan].?));
                        ptr.* = @floatCast(f64_val);
                    },
                    4 => {
                        const ptr: *f32 = @ptrCast(@alignCast(self.chan_ptrs[chan].?));
                        ptr.* = @floatCast(f64_val);
                    },
                    8 => {
                        const ptr: *f64 = @ptrCast(@alignCast(self.chan_ptrs[chan].?));
                        ptr.* = f64_val;
                    },
                    16 => {
                        const ptr: *f128 = @ptrCast(@alignCast(self.chan_ptrs[chan].?));
                        ptr.* = @floatCast(f64_val);
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

test "Runtime 双 Region 分层寻址" {
    var global_region = ChannelRegion.init(testing.allocator);
    defer global_region.deinit();
    var call_region = ChannelRegion.init(testing.allocator);
    defer call_region.deinit();

    var channels = ChannelSpace.init(testing.allocator);
    defer channels.deinit();
    channels.global_count = 1;
    _ = try channels.alloc(.i64_chan); // ch0: 全局
    _ = try channels.alloc(.i64_chan); // ch1: 本地

    var rt = Runtime.init(&global_region, &call_region, testing.allocator, null);
    defer rt.deinit();
    rt.frame_stack = try testing.allocator.alloc(FrameContext, 1024);
    try rt.layoutGlobals(&channels);

    // 全局通道可直接读写
    rt.writeI64(0, 42);
    try testing.expectEqual(@as(i64, 42), rt.readI64(0));

    // 模拟函数 enterFunction
    var func = Function{
        .name = "test",
        .node_start = 0,
        .node_count = 0,
        .param_channels = &.{},
        .return_channel = 1,
        .local_chan_start = 1,
        .local_chan_count = 1,
        .chan_total_bytes = 32,
        .local_offsets = &[_]u32{ 0, 16 },
        .scc_max_chan_bytes = 32,
    };
    // 设置 ch1 的宽度（模拟 layoutGlobals 中未覆盖的本地通道）
    rt.chan_widths[1] = 8;
    try rt.enterFunction(0, &func);
    defer rt.leaveFunction();

    // 本地通道可读写
    rt.writeI64(1, 99);
    try testing.expectEqual(@as(i64, 99), rt.readI64(1));

    // 全局通道仍可读写
    try testing.expectEqual(@as(i64, 42), rt.readI64(0));
}
