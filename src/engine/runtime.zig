//! 通道运行时存储
//!
//! ChannelSpace 只管理通道的元信息（类型/宽度），实际数据存储由 ChannelRegion 承载。
//! Runtime 负责在执行前为每个通道在 ChannelRegion 中分配存储空间，并提供读写接口。
//!
//! 设计要点（双 Region 模型）：
//! - GlobalRegion：存储全局通道（程序级），layout 一次，永不 reset
//! - CallStackRegion：存储函数级通道，bump + resetTo 实现函数级回收
//! - chan_slots 单数组覆盖所有通道（v3 阶段 6：替代 chan_ptrs/chan_widths/chan_lengths/chan_types/chan_is_ref 五数组）
//! - enterFunction 设置本地通道的 chan_slots.ptr 指向 per-frame region，并保存 caller 的 slot
//! - leaveFunction 恢复 caller 的 chan_slots 并 resetTo 回收本帧内存

const std = @import("std");
const ir_mod = @import("ir");
const mem = @import("mem");
const value = @import("value");
const profiling = @import("profiling");
const scalar = value.scalar;

const ChannelRegion = mem.ChannelRegion;
const ChannelSpace = ir_mod.ChannelSpace;
const type_descriptor_mod = ir_mod.type_descriptor_mod;
const ConstVal = ir_mod.ConstVal;
const ScalarMeta = ir_mod.ScalarMeta;
const ScalarKind = ir_mod.ScalarKind;
const Function = ir_mod.Function;
const ThreadProfiler = profiling.ThreadProfiler;

/// 单个通道的运行时槽位：数据指针 + 类型描述符 + 长度
///
/// v3 阶段 6：将原 chan_ptrs/chan_widths/chan_lengths/chan_types/chan_is_ref
/// 五个并排数组合并为单一结构体数组，提高缓存局部性，简化扩展。
/// v3 阶段 6（type_desc 统一）：所有类型元信息（is_ref/scalar_ops/is_nullable/...）
/// 统一由 type_desc 携带，运行时通过 type_desc.<field> 获取，无任何通道派分。
/// width 保留：nullable 的实际宽度因 inner_type 而异（size=inner+1），
/// 无法从静态 type_desc.size 获取，故 width 仍为权威宽度来源。
pub const ChanSlot = struct {
    /// 数据指针（指向 ChannelRegion 中的内存）
    /// 标量通道：1 个元素；向量通道：多个元素（由调用方管理长度）
    /// null 表示无数据通道（unit/null 类型）
    ptr: ?[*]u8 = null,
    /// 类型描述符（含 is_ref/scalar_ops/is_nullable/is_null_type/is_unit_type 等编译期元信息）
    /// 所有类型判断统一通过 type_desc.<field> 获取，无任何通道派分
    type_desc: *const ir_mod.type_descriptor_mod.TypeDescriptor = ir_mod.type_descriptor_mod.null_descriptor,
    /// 元素宽度（字节，权威值——nullable 宽度因 inner_type 而异：inner.size + 1 byte flag）
    width: u8 = 0,
    /// 元素数量（标量=1，向量=N）
    length: u32 = 0,
};

/// 帧上下文：每次函数调用压栈一次
pub const FrameContext = struct {
    // TCO 检测和 backtrace
    func_idx: u16 = 0,
    return_chan: u16 = 0,
    return_pc: u32 = 0,
    // region 管理
    caller_frame_offset: usize = 0,
    caller_func: ?*const Function = null,
    // saved_slots 的信息（从 CallStackRegion 分配）
    saved_slots_base: usize = 0, // [*]ChanSlot 的地址
    saved_chan_count: u16 = 0, // 保存的通道数（local_chan_count + 1）
    saved_chan_start: u16 = 0, // 保存的通道起始索引
    saved_return_channel: u16 = 0, // return_channel 索引
    // 泛型类型实参（迁自 Engine.frame_type_args_stack）
    // 切片生命周期挂在 IR arena（与 call_meta.type_args 一致），帧只持有引用
    type_args: []const u16 = &[_]u16{},
    // 帧标量区指针（Task 3 启用，替代 saved_ptrs_* 机制）
    // sync 帧标量区从 scalar_area bump 分配，与协程帧 locals 区结构同构
    // chan_slots[local_chan_start..].ptr 指向此区域，按通道宽度连续布局
    scalar_area_base: ?[*]u8 = null,
    scalar_area_size: u32 = 0,
};

/// 通道运行时存储：管理所有通道的实际数据
///
/// 双 Region 模型：
/// - global_region：全局通道（程序级生命周期），由所有者管理
/// - scalar_area：函数级标量区（bump + resetTo），与协程帧 locals 区结构同构，由所有者管理
///
/// chan_slots 单数组覆盖所有通道：
/// - 全局通道在 layoutGlobals 中设置，指向 global_region
/// - 本地通道在 enterFunction 中设置，指向 scalar_area 中的 per-frame 内存
pub const Runtime = struct {
    /// 通道槽位单数组（v3 阶段 6：替代五数组）
    chan_slots: []ChanSlot = &.{},
    /// 通道总数
    chan_count: u16 = 0,
    /// backing allocator（用于 chan_slots 数组）
    backing: std.mem.Allocator,
    /// ThreadProfiler 引用（channel 分配水位埋点）
    prof: ?*ThreadProfiler = null,

    // ── GlobalRegion ──
    global_slots: []ChanSlot = &.{},
    global_count: u16 = 0,
    global_region: *ChannelRegion,

    // ── ScalarArea（原 CallStackRegion，sync 帧标量区，与协程帧 locals 区结构同构） ──
    scalar_area: *ChannelRegion,
    current_frame_offset: usize = 0,

    // ── FrameStack ──
    frame_stack: []FrameContext = &.{},
    call_depth: u32 = 0,
    current_func: ?*const Function = null,

    // ── ChanSlot 字段访问器（向量切片操作核心 API） ──
    // vector_exec/body_exec 通过这些 accessor 设置子向量视图的 ptr/length，
    // 实现逐元素遍历时将向量通道重定向到单个元素。
    /// 读取通道数据指针
    pub inline fn chanPtrs(self: *Runtime, chan: u16) ?[*]u8 {
        return self.chan_slots[chan].ptr;
    }
    /// 设置通道数据指针（向量切片重定向）
    pub inline fn setChanPtr(self: *Runtime, chan: u16, ptr: ?[*]u8) void {
        self.chan_slots[chan].ptr = ptr;
    }
    /// 读取通道向量长度
    pub inline fn chanLengths(self: *Runtime, chan: u16) u32 {
        return self.chan_slots[chan].length;
    }
    /// 设置通道向量长度
    pub inline fn setChanLength(self: *Runtime, chan: u16, len: u32) void {
        self.chan_slots[chan].length = len;
    }
    /// 读取通道元素宽度
    pub inline fn chanWidths(self: *Runtime, chan: u16) u8 {
        return self.chan_slots[chan].width;
    }

    /// 初始化运行时
    /// global_region/scalar_area 由所有者管理，Runtime 不负责释放
    pub fn init(
        global_region: *ChannelRegion,
        scalar_area: *ChannelRegion,
        backing: std.mem.Allocator,
        prof: ?*ThreadProfiler,
    ) Runtime {
        return .{
            .global_region = global_region,
            .scalar_area = scalar_area,
            .backing = backing,
            .prof = prof,
        };
    }

    /// 释放运行时资源（不释放 global_region/scalar_area，由所有者管理）
    pub fn deinit(self: *Runtime) void {
        if (self.chan_slots.len > 0) self.backing.free(self.chan_slots);
        if (self.global_slots.len > 0) self.backing.free(self.global_slots);
        if (self.frame_stack.len > 0) self.backing.free(self.frame_stack);
    }

    /// 布局全局通道到 GlobalRegion
    /// 必须在执行前调用一次。本地通道的 chan_slots.ptr 在 enterFunction 中设置。
    pub fn layoutGlobals(self: *Runtime, channels: *const ChannelSpace) !void {
        const gc = channels.global_count;
        self.global_count = gc;
        self.chan_count = channels.count();

        // 分配 chan_slots（覆盖所有通道）
        self.chan_slots = try self.backing.alloc(ChanSlot, self.chan_count);
        @memset(self.chan_slots, .{});

        // 为所有通道设置 type_desc/width（静态元信息，不随函数调用变化）
        // 本地通道的 chan_slots.ptr 在 enterFunction 中设置，但 type_desc/width 在此处一次性设置
        for (0..self.chan_count) |i| {
            const meta = channels.get(@intCast(i));
            self.chan_slots[i].type_desc = meta.type_desc;
            self.chan_slots[i].width = meta.elem_width;
        }

        if (gc == 0) return;

        self.global_slots = try self.backing.alloc(ChanSlot, gc);

        for (0..gc) |i| {
            const meta = channels.get(@intCast(i));
            self.global_slots[i].type_desc = meta.type_desc;
            self.global_slots[i].width = meta.elem_width;
            self.global_slots[i].length = 1;
            self.chan_slots[i].type_desc = meta.type_desc;
            self.chan_slots[i].width = meta.elem_width;
            self.chan_slots[i].length = 1;
            if (meta.elem_width == 0) {
                self.global_slots[i].ptr = null;
                self.chan_slots[i].ptr = null;
            } else {
                const buf = try self.global_region.alloc(meta.elem_width);
                // global_region 扩容后重基之前设置的 global_slots/chan_slots 的 ptr
                if (self.global_region.rebase_info) |ri| {
                    self.global_region.rebase_info = null;
                    const old_base = ri.old_base;
                    const old_end = ri.old_end;
                    const offset: i64 = ri.offset;
                    for (0..i) |j| {
                        if (self.global_slots[j].ptr) |p| {
                            const addr = @intFromPtr(p);
                            if (addr >= old_base and addr < old_end) {
                                const new_addr = @as(usize, @bitCast(@as(i64, @bitCast(addr)) + offset));
                                self.global_slots[j].ptr = @ptrFromInt(new_addr);
                                self.chan_slots[j].ptr = @ptrFromInt(new_addr);
                            }
                        }
                    }
                }
                @memset(buf, 0);
                self.global_slots[i].ptr = buf.ptr;
                self.chan_slots[i].ptr = buf.ptr;
            }
        }

        // 记录 channel 总水位（global_region + scalar_area，此时 scalar_area 为空）
        if (self.prof) |p| p.recordAllocatorWatermark(.channel, self.global_region.used + self.scalar_area.used, true);
    }

    /// 检查 scalar_area 是否扩容，如果扩容则重基所有指向 scalar_area 的指针。
    /// scalar_area 扩容后旧内存被释放，所有指向旧内存的 chan_slots.ptr 和 frame_stack 中的
    /// saved_slots_base/saved 指针值都需要按 offset 重基。
    /// 必须在每次 scalar_area.alloc/allocAligned 后调用。
    fn rebaseIfNeeded(self: *Runtime) void {
        const ri = self.scalar_area.rebase_info orelse return;
        self.scalar_area.rebase_info = null;

        const old_base = ri.old_base;
        const old_end = ri.old_end;
        const offset: i64 = ri.offset;

        // 重基 chan_slots.ptr（指向 scalar_area 的本地通道指针）
        for (self.chan_slots) |*slot| {
            if (slot.ptr) |p| {
                const addr = @intFromPtr(p);
                if (addr >= old_base and addr < old_end) {
                    const new_addr = @as(usize, @bitCast(@as(i64, @bitCast(addr)) + offset));
                    slot.ptr = @ptrFromInt(new_addr);
                }
            }
        }

        // 重基 frame_stack 条目
        for (0..self.call_depth) |i| {
            const frame = &self.frame_stack[i];
            // 重基 saved_slots_base（指向 scalar_area 的地址）
            if (frame.saved_slots_base >= old_base and frame.saved_slots_base < old_end) {
                frame.saved_slots_base = @as(usize, @bitCast(@as(i64, @bitCast(frame.saved_slots_base)) + offset));
            }
            // 重基 saved_slots 中保存的指针值（这些是外层帧的 chan_slots，可能指向 scalar_area）
            const saved_slots: [*]ChanSlot = @ptrFromInt(frame.saved_slots_base);
            for (0..frame.saved_chan_count) |j| {
                if (saved_slots[j].ptr) |p| {
                    const addr = @intFromPtr(p);
                    if (addr >= old_base and addr < old_end) {
                        const new_addr = @as(usize, @bitCast(@as(i64, @bitCast(addr)) + offset));
                        saved_slots[j].ptr = @ptrFromInt(new_addr);
                    }
                }
            }
            // 重基 scalar_area_base（帧标量区起点，指向 scalar_area 的指针）
            if (frame.scalar_area_base) |base| {
                const addr = @intFromPtr(base);
                if (addr >= old_base and addr < old_end) {
                    const new_addr = @as(usize, @bitCast(@as(i64, @bitCast(addr)) + offset));
                    frame.scalar_area_base = @ptrFromInt(new_addr);
                }
            }
        }
    }

    /// 函数入口：建立新帧
    /// 在 scalar_area 中分配本函数通道数据（帧标量区），设置 chan_slots.ptr 指向 per-frame 内存
    pub fn enterFunction(
        self: *Runtime,
        func_idx: u16,
        func: *const Function,
        type_args: []const u16,
    ) !void {
        if (self.call_depth >= self.frame_stack.len) return error.CallDepthExceeded;

        const chan_count = @as(usize, func.local_chan_count) + 1; // +1 for return_channel

        // 在 CallStackRegion 中分配 saved_slots（在通道数据之前）
        const saved_total = std.mem.alignForward(usize, chan_count * @sizeOf(ChanSlot), 16);
        const saved_space = try self.scalar_area.allocAligned(saved_total, 16);
        // 扩容后重基所有指向 scalar_area 的指针（必须在保存 chan_slots 之前）
        self.rebaseIfNeeded();
        const saved_slots: [*]ChanSlot = @ptrCast(@alignCast(saved_space.ptr));

        // 保存被覆盖的 chan_slots
        for (0..func.local_chan_count) |i| {
            const chan = func.local_chan_start + @as(u16, @intCast(i));
            saved_slots[i] = self.chan_slots[chan];
        }
        saved_slots[func.local_chan_count] = self.chan_slots[func.return_channel];

        // 保存 frame_stack
        self.frame_stack[self.call_depth] = .{
            .func_idx = func_idx,
            .caller_frame_offset = self.current_frame_offset,
            .caller_func = self.current_func,
            .saved_slots_base = @intFromPtr(saved_slots),
            .saved_chan_count = @intCast(chan_count),
            .saved_chan_start = func.local_chan_start,
            .saved_return_channel = func.return_channel,
            .type_args = type_args,
        };
        self.call_depth += 1;

        // 在 scalar_area 中分配通道数据（帧标量区，与协程帧 locals 区结构同构）
        const alloc_bytes = func.scc_max_chan_bytes;
        if (alloc_bytes > 0) {
            const chan_bytes = try self.scalar_area.allocAligned(alloc_bytes, 16);
            // 扩容后重基所有指向 scalar_area 的指针（包括刚保存的 saved_slots）
            self.rebaseIfNeeded();
            @memset(chan_bytes, 0);

            // 记录帧标量区起点（供后续 reflect/format 直读标量区用）
            self.frame_stack[self.call_depth - 1].scalar_area_base = chan_bytes.ptr;
            self.frame_stack[self.call_depth - 1].scalar_area_size = alloc_bytes;

            // 设置本函数通道的 chan_slots.ptr/length
            // width/type_desc 已在 layoutGlobals 中一次性设置（静态元信息）
            for (0..func.local_chan_count) |i| {
                const chan = func.local_chan_start + @as(u16, @intCast(i));
                self.chan_slots[chan].ptr = chan_bytes.ptr + func.local_offsets[i];
                self.chan_slots[chan].length = 1;
            }
            // return_channel
            self.chan_slots[func.return_channel].ptr = chan_bytes.ptr + func.local_offsets[func.local_chan_count];
            self.chan_slots[func.return_channel].length = 1;
        }

        // current_frame_offset 指向本帧 END（saved_space + 通道数据），
        // leaveFunction 的 resetTo(caller_frame_offset) 据此回收到调用者帧尾，
        // 避免后续分配覆盖调用者通道数据。
        self.current_frame_offset = self.scalar_area.used;
        self.current_func = func;

        if (self.prof) |p| p.recordAllocatorWatermark(.channel, self.global_region.used + self.scalar_area.used, true);
    }

    /// 函数出口：回收帧
    /// 恢复 caller 的 chan_slots，resetTo 回收本帧内存
    pub fn leaveFunction(self: *Runtime) void {
        self.call_depth -= 1;
        const frame = self.frame_stack[self.call_depth];

        // 恢复 chan_slots
        const saved_slots: [*]ChanSlot = @ptrFromInt(frame.saved_slots_base);
        for (0..frame.saved_chan_count - 1) |i| {
            const chan = frame.saved_chan_start + @as(u16, @intCast(i));
            self.chan_slots[chan] = saved_slots[i];
        }
        self.chan_slots[frame.saved_return_channel] = saved_slots[frame.saved_chan_count - 1];

        // 恢复 current_frame_offset 和 current_func
        self.current_frame_offset = frame.caller_frame_offset;
        self.current_func = frame.caller_func;

        // resetTo 回收（包括 saved_slots 和通道数据）
        const before_reset = self.scalar_area.used;
        self.scalar_area.resetTo(frame.caller_frame_offset);
        if (self.prof) |p| {
            const freed = before_reset - self.scalar_area.used;
            // reset 更新计数 + 零化 current_bytes，watermark 再设为 reset 后总和
            p.recordAllocatorReset(.channel, freed);
            p.recordAllocatorWatermark(.channel, self.global_region.used + self.scalar_area.used, false);
        }
    }

    // ════════════════════════════════════════════
    // 协程调度支持：帧自带通道空间安装
    // ════════════════════════════════════════════

    /// 将协程帧的 locals 区安装到 chan_slots，使该函数的本地通道指针指向帧内持久化的通道数据。
    ///
    /// 帧自带通道空间方案：CoroutineFrame 的 locals 区即该函数的通道数据存储
    /// （FrameLayout.total_size = func.chan_total_bytes）。每次段执行前调用此方法，
    /// 将帧的 locals 区按 SlotDesc 布局安装到 chan_slots，通道状态在帧中跨段持久化。
    ///
    /// 参数：
    /// - locals_base：帧 locals 区起始指针（frame.localsPtr()）
    /// - func：async 函数的 IR 元数据（local_chan_start/local_chan_count/return_channel）
    /// - layout：帧布局（slots 描述每个通道在 locals 区的 offset/size）
    pub fn installFrameChannels(
        self: *Runtime,
        locals_base: [*]u8,
        func: *const Function,
        layout: *const ir_mod.FrameLayout,
    ) void {
        // 本地通道：按 layout.slots 安装
        for (0..func.local_chan_count) |i| {
            const chan = func.local_chan_start + @as(u16, @intCast(i));
            const slot = layout.slots[i];
            if (slot.size > 0) {
                self.chan_slots[chan].ptr = locals_base + slot.offset;
                self.chan_slots[chan].length = 1;
            } else {
                self.chan_slots[chan].ptr = null;
                self.chan_slots[chan].length = 0;
            }
        }
        // return_channel（slots[local_chan_count]）
        const ret_idx = func.local_chan_count;
        if (ret_idx < layout.slots.len) {
            const ret_slot = layout.slots[ret_idx];
            if (ret_slot.size > 0) {
                self.chan_slots[func.return_channel].ptr = locals_base + ret_slot.offset;
                self.chan_slots[func.return_channel].length = 1;
            } else {
                self.chan_slots[func.return_channel].ptr = null;
                self.chan_slots[func.return_channel].length = 0;
            }
        }
    }

    // ════════════════════════════════════════════
    // 标量读写接口
    // ════════════════════════════════════════════

    /// 读取 i64 值
    pub inline fn readI64(self: *Runtime, chan: u16) i64 {
        const ptr: *i64 = @ptrCast(@alignCast(self.chan_slots[chan].ptr.?));
        return ptr.*;
    }

    /// 写入 i64 值
    pub inline fn writeI64(self: *Runtime, chan: u16, val: i64) void {
        const ptr: *i64 = @ptrCast(@alignCast(self.chan_slots[chan].ptr.?));
        ptr.* = val;
    }

    /// 读取 u64 值
    pub inline fn readU64(self: *Runtime, chan: u16) u64 {
        const ptr: *u64 = @ptrCast(@alignCast(self.chan_slots[chan].ptr.?));
        return ptr.*;
    }

    /// 写入 u64 值
    pub inline fn writeU64(self: *Runtime, chan: u16, val: u64) void {
        const ptr: *u64 = @ptrCast(@alignCast(self.chan_slots[chan].ptr.?));
        ptr.* = val;
    }

    /// 读取 usize 值
    pub inline fn readUsize(self: *Runtime, chan: u16) usize {
        const ptr: *usize = @ptrCast(@alignCast(self.chan_slots[chan].ptr.?));
        return ptr.*;
    }

    /// 写入 usize 值（Phase 5: .len() 返回类型从 i64 改为 usize）
    pub inline fn writeUsize(self: *Runtime, chan: u16, val: usize) void {
        const ptr: *usize = @ptrCast(@alignCast(self.chan_slots[chan].ptr.?));
        ptr.* = val;
    }

    /// 读取 f64 值
    pub inline fn readF64(self: *Runtime, chan: u16) f64 {
        const ptr: *f64 = @ptrCast(@alignCast(self.chan_slots[chan].ptr.?));
        return ptr.*;
    }

    /// 写入 f64 值
    pub inline fn writeF64(self: *Runtime, chan: u16, val: f64) void {
        const ptr: *f64 = @ptrCast(@alignCast(self.chan_slots[chan].ptr.?));
        ptr.* = val;
    }

    /// 读取 bool 值
    pub inline fn readBool(self: *Runtime, chan: u16) bool {
        const ptr: *u8 = @ptrCast(@alignCast(self.chan_slots[chan].ptr.?));
        return ptr.* != 0;
    }

    /// 写入 bool 值
    pub inline fn writeBool(self: *Runtime, chan: u16, val: bool) void {
        const ptr: *u8 = @ptrCast(@alignCast(self.chan_slots[chan].ptr.?));
        ptr.* = if (val) 1 else 0;
    }

    /// 读取堆对象指针（ref_chan）
    pub inline fn readPtr(self: *Runtime, chan: u16) ?*anyopaque {
        const ptr: *?*anyopaque = @ptrCast(@alignCast(self.chan_slots[chan].ptr.?));
        return ptr.*;
    }

    /// 写入堆对象指针（ref_chan）
    pub inline fn writePtr(self: *Runtime, chan: u16, val: ?*anyopaque) void {
        const ptr: *?*anyopaque = @ptrCast(@alignCast(self.chan_slots[chan].ptr.?));
        ptr.* = val;
    }

    /// 泛型标量读取（指定通道）：按 comptime tag 直接指针读写，跳过 16B 中间缓冲
    /// 覆盖所有 int/uint/float 类型，零 memcpy
    pub fn readScalarAt(self: *Runtime, comptime tag: scalar.ScalarTag, chan: u16) scalar.NativeType(tag) {
        const T = scalar.NativeType(tag);
        const ptr: *T = @ptrCast(@alignCast(self.chan_slots[chan].ptr.?));
        return ptr.*;
    }

    /// 泛型标量写入（指定通道）
    pub fn writeScalarAt(self: *Runtime, comptime tag: scalar.ScalarTag, chan: u16, val: scalar.NativeType(tag)) void {
        const T = scalar.NativeType(tag);
        const ptr: *T = @ptrCast(@alignCast(self.chan_slots[chan].ptr.?));
        ptr.* = val;
    }

    /// 读取原始字节指针（用于通用访问）
    pub inline fn rawPtr(self: *Runtime, chan: u16) [*]u8 {
        return self.chan_slots[chan].ptr.?;
    }

    /// 获取通道元素宽度
    pub inline fn elemWidth(self: *Runtime, chan: u16) u8 {
        return self.chan_slots[chan].width;
    }

    // ════════════════════════════════════════════
    // 统一通道读写接口（基于 type_desc.scalar_ops vtable）
    // ════════════════════════════════════════════

    /// 统一读取通道值为 value.Value（通过 scalar_ops vtable 分派）
    /// 标量类型 + ref + unit/null + nullable 均有专属 vtable，零运行时 switch。
    /// 零字节类型（unit/null）ptr 可能为 null，使用 dummy ptr 调用 vtable。
    /// nullable 通道：通过 nullable<T> 专属 scalar_ops 读写（内含 null flag 检查）。
    pub fn readChannel(self: *Runtime, chan: u16) ?value.Value {
        const slot = &self.chan_slots[chan];
        const ops = slot.type_desc.scalar_ops;
        if (slot.ptr) |p| return ops.read(@ptrCast(p));
        // ptr 为 null：仅对零字节类型（unit/null）合法，使用 dummy ptr
        if (slot.width == 0) return ops.read(@ptrFromInt(@as(usize, 1)));
        return null; // 数据类型但 ptr 未初始化
    }

    /// 统一写入 value.Value 到通道（通过 scalar_ops vtable 分派）
    /// 先 coerce 将 Value 转为通道类型匹配的 Value，再 write 写入。
    /// 零运行时 switch，且安全处理跨类型写入（如 i32 写入 i64 通道）。
    /// nullable 通道：通过 nullable<T> 专属 scalar_ops 读写（内含 null flag 设置）。
    pub fn writeChannel(self: *Runtime, chan: u16, v: value.Value) bool {
        const slot = &self.chan_slots[chan];
        const ops = slot.type_desc.scalar_ops;
        const coerced = ops.coerce(v);
        if (slot.ptr) |p| {
            ops.write(@ptrCast(p), coerced);
            return true;
        }
        // ptr 为 null：仅对零字节类型合法，write 为 no-op
        if (slot.width == 0) return true;
        return false;
    }

    /// 获取通道的类型描述符
    pub inline fn typeDesc(self: *Runtime, chan: u16) *const ir_mod.type_descriptor_mod.TypeDescriptor {
        return self.chan_slots[chan].type_desc;
    }

    /// 统一引用判断：通道是否持有引用类型（堆对象指针）
    /// 通过 type_desc.isRef() 方法获取（替代旧 chan_type 派分）
    pub inline fn isRef(self: *Runtime, chan: u16) bool {
        return self.chan_slots[chan].type_desc.isRef();
    }

    /// 统一标量判断：通道是否持有标量值（有 scalar_ops vtable）
    pub inline fn isScalar(self: *Runtime, chan: u16) bool {
        _ = self;
        _ = chan;
        return true;
    }

    /// 统一 nullable 判断：通道是否为 nullable<T> 类型
    /// 通过 type_desc.isNullable() 方法获取
    pub inline fn isNullable(self: *Runtime, chan: u16) bool {
        return self.chan_slots[chan].type_desc.isNullable();
    }

    /// 统一 null 类型判断：通道是否为 null 类型
    /// 通过 type_desc.type_id 判断（NULL_TYPE_ID=20）
    pub inline fn isNull(self: *Runtime, chan: u16) bool {
        return self.chan_slots[chan].type_desc.isNullType();
    }

    /// 统一 unit 类型判断：通道是否为 unit 类型
    /// 通过 type_desc.type_id 判断（UNIT_TYPE_ID=21）
    pub inline fn isUnit(self: *Runtime, chan: u16) bool {
        return self.chan_slots[chan].type_desc.isUnitType();
    }


    /// 统一格式化通道标量值为字符串（通过 scalar_ops.format vtable 分派）
    /// 标量类型走 vtable 快路径，零运行时 switch；
    /// 非标量类型（ref/nullable/unit/null）返回 null，由调用方处理。
    pub fn formatChannel(self: *Runtime, chan: u16, buf: []u8) ?[]const u8 {
        const slot = &self.chan_slots[chan];
        if (slot.ptr == null) return null;
        const ops = slot.type_desc.scalar_ops;
        return ops.format(@ptrCast(slot.ptr.?), buf);
    }

    /// 统一格式化任意标量指针为字符串（通过 scalar_ops.format vtable 分派）
    /// 用于 ref_chan 内嵌的标量引用场景：指针来自其他通道的 rawPtr，
    /// type_desc 来自源通道。零运行时 switch。
    pub fn formatScalarPtr(_: *Runtime, ptr: *anyopaque, type_desc: *const ir_mod.type_descriptor_mod.TypeDescriptor, buf: []u8) ?[]const u8 {
        const ops = type_desc.scalar_ops;
        return ops.format(ptr, buf);
    }

    // ════════════════════════════════════════════
    // 向量读写接口
    // ════════════════════════════════════════════

    /// 为通道分配向量缓冲区（覆盖标量缓冲区，旧缓冲区随 region reset 释放）
    pub fn allocVector(self: *Runtime, chan: u16, count: u32) !void {
        const w = self.chan_slots[chan].width;
        if (w == 0 or count == 0) {
            self.chan_slots[chan].length = 0;
            return;
        }
        const buf = try self.scalar_area.alloc(w * @as(usize, count));
        // 扩容后重基所有指向 scalar_area 的指针
        self.rebaseIfNeeded();
        // buf.ptr 可能在 rebase 后已失效（如果 buf 本身被重基），但 buf 是本次 alloc 的返回值，
        // 其地址基于新 data，不受 rebase 影响。不过 chan_slots.ptr 可能被 rebase 修改，需在 rebase 后赋值。
        self.chan_slots[chan].ptr = buf.ptr;
        self.chan_slots[chan].length = count;
    }

    /// 获取通道元素数量（标量=1，向量=N）
    pub fn vectorLen(self: *Runtime, chan: u16) u32 {
        return self.chan_slots[chan].length;
    }

    /// 获取向量元素的原始指针
    pub fn vectorElemPtr(self: *Runtime, chan: u16, index: usize) [*]u8 {
        const w = self.chan_slots[chan].width;
        return self.chan_slots[chan].ptr.? + index * w;
    }

    /// 读取向量第 i 个元素为 i64
    pub fn readVectorI64(self: *Runtime, chan: u16, index: usize) i64 {
        const ptr: *i64 = @ptrCast(@alignCast(self.chan_slots[chan].ptr.? + index * 8));
        return ptr.*;
    }

    /// 写入 i64 到向量第 i 个位置
    pub fn writeVectorI64(self: *Runtime, chan: u16, index: usize, val: i64) void {
        const ptr: *i64 = @ptrCast(@alignCast(self.chan_slots[chan].ptr.? + index * 8));
        ptr.* = val;
    }

    /// 临时设置通道为标量模式（指向向量中的某个元素）
    pub fn pinToElement(self: *Runtime, chan: u16, vec_chan: u16, index: usize) void {
        const w = self.chan_slots[vec_chan].width;
        self.chan_slots[chan].ptr = self.chan_slots[vec_chan].ptr.? + index * w;
        self.chan_slots[chan].length = 1;
    }

    // ════════════════════════════════════════════
    // 常量初始化
    // ════════════════════════════════════════════

    /// 从 ConstVal 初始化通道值
    pub fn writeConst(self: *Runtime, chan: u16, const_val: ConstVal, kind: ScalarKind) void {
        switch (const_val) {
            .int_val => |v| {
                // 按通道实际宽度截断存储（使用 @truncate 处理超出范围的值）
                const w = self.chan_slots[chan].width;
                switch (w) {
                    1 => {
                        const ptr: *i8 = @ptrCast(@alignCast(self.chan_slots[chan].ptr.?));
                        ptr.* = @truncate(v);
                    },
                    2 => {
                        const ptr: *i16 = @ptrCast(@alignCast(self.chan_slots[chan].ptr.?));
                        ptr.* = @truncate(v);
                    },
                    4 => {
                        const ptr: *i32 = @ptrCast(@alignCast(self.chan_slots[chan].ptr.?));
                        ptr.* = @truncate(v);
                    },
                    8 => {
                        const ptr: *i64 = @ptrCast(@alignCast(self.chan_slots[chan].ptr.?));
                        ptr.* = @truncate(v);
                    },
                    16 => {
                        const ptr: *i128 = @ptrCast(@alignCast(self.chan_slots[chan].ptr.?));
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
                const w = self.chan_slots[chan].width;
                const f64_val: f64 = @bitCast(@as(u64, @truncate(bits)));
                switch (w) {
                    2 => {
                        const ptr: *f16 = @ptrCast(@alignCast(self.chan_slots[chan].ptr.?));
                        ptr.* = @floatCast(f64_val);
                    },
                    4 => {
                        const ptr: *f32 = @ptrCast(@alignCast(self.chan_slots[chan].ptr.?));
                        ptr.* = @floatCast(f64_val);
                    },
                    8 => {
                        const ptr: *f64 = @ptrCast(@alignCast(self.chan_slots[chan].ptr.?));
                        ptr.* = f64_val;
                    },
                    16 => {
                        const ptr: *f128 = @ptrCast(@alignCast(self.chan_slots[chan].ptr.?));
                        ptr.* = @floatCast(f64_val);
                    },
                    else => {},
                }
            },
            .bool_val => |v| self.writeBool(chan, v),
            .char_val => |v| {
                // char_chan 宽度为 4 字节，用 u32 写入（u21 只有 3 字节，会留下垃圾）
                const ptr: *u32 = @ptrCast(@alignCast(self.chan_slots[chan].ptr.?));
                ptr.* = @intCast(v);
            },
        }
        _ = kind;
    }
};

