//! 值/通道转换函数（v3 阶段 5.3：从 engine.zig 物理拆分）
//!
//! 包含：
//! - 值转换：chanToValue / valueToChan
//! - 跨通道复制：cloneValueBetweenChannels / copyCrossType / cloneValueForContainer / trackValueTree
//! - 读取辅助：readStr / readArray / currentFuncIdx / restoreVectorChan / readRefObj /
//!   readThrow / readIntAsI64 / readError
//! - 标量值读写：readScalarValue / writeScalarValue / readScalarValueToBytes
//!
//! 标量引用统一通过 Cell 装箱实现（废除 tagged scalar ref 机制后），
//! ref 通道的读写由 ref_ops vtable 统一处理（堆对象/null/标量位模式）。
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
    // 值转换
    // ════════════════════════════════════════════

    /// 从通道读取 Value
    /// 统一通过 type_desc.scalar_ops vtable 读取（零运行时 switch）。
    /// 标量 + ref + unit/null + nullable 均通过 vtable 读写（nullable 使用 inner type 的 scalar_ops）。
    pub fn chanToValue(self: *Engine, chan: u16) value.Value {
        // 统一路径：通过 scalar_ops vtable 读取（标量/ref/unit/null/nullable 全覆盖）
        if (self.runtime.readChannel(chan)) |v| return v;
        return value.Value.fromUnit();
    }

    /// 将 Value 写入通道
    /// 统一通过 type_desc.scalar_ops vtable 写入（coerce + write）。
    /// 标量 + ref + unit/null + nullable 均走 vtable 路径。
    pub fn valueToChan(self: *Engine, chan: u16, v: value.Value) void {
        // 所有类型：统一走 writeChannel（vtable coerce + write）
        if (self.runtime.writeChannel(chan, v)) return;

        // writeChannel 返回 false：理论上不会到达（所有类型已有 vtable 处理）
        self.writeScalarValue(chan, v);
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
        const w = self.runtime.elemWidth(src_chan);
        if (w == 0) return;

        // ref_chan 持有堆引用且需值语义深拷贝
        if (self.runtime.isRef(src_chan) and !is_ref) {
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

        // 源/目标通道 type_desc 不同或宽度不匹配：跨类型复制
        const src_td = self.runtime.typeDesc(src_chan);
        const dst_td = self.runtime.typeDesc(dst_chan);
        if (src_td != dst_td or self.runtime.elemWidth(src_chan) != self.runtime.elemWidth(dst_chan)) {
            try self.copyCrossType(dst_chan, src_chan);
            return;
        }

        // 同类型同宽度：直接复制字节
        if (src_chan == dst_chan) return;
        const src = self.runtime.rawPtr(src_chan);
        const dst = self.runtime.rawPtr(dst_chan);
        @memcpy(dst[0..w], src[0..w]);
    }

    /// 跨通道类型复制：当源/目标 type_desc 或 elem_width 不匹配时使用。
    /// 核心场景：泛型函数的类型参数（A/T）被映射为 ref_chan（8字节），
    /// 但实际值为标量（i32/f32 等）。此时需要：
    /// - 标量 → ref_chan：通过 scalar_ops.read 读取为 Value，再提取 i64 位模式写入
    /// - ref_chan → 标量：读取 8 字节位模式为 Value，通过 scalar_ops.coerce+write 写入
    /// 标量读写均走 vtable，零运行时 switch；ref_chan 特例处理 128 位截断/扩展。
    pub fn copyCrossType(self: *Engine, dst_chan: u16, src_chan: u16) EngineError!void {
        const src_raw = self.runtime.rawPtr(src_chan);
        const dst_raw = self.runtime.rawPtr(dst_chan);
        const src_is_ref = self.runtime.isRef(src_chan);
        const dst_is_ref = self.runtime.isRef(dst_chan);
        const dst_w = self.runtime.elemWidth(dst_chan);

        // 标量 → ref_chan：通过 vtable read 读取为 Value，转为 i64 位模式写入 8 字节
        // i128/u128/f128（16 字节）截断到低 64 位（lossy）；
        // 完整值需走具体标量通道（i128_chan 等），泛型 T 上下文暂不支持 16 字节标量。
        if (dst_is_ref and !src_is_ref) {
            const dst_ptr: *i64 = @ptrCast(@alignCast(dst_raw));
            // 走 vtable read 获取标量 Value，再统一转为 i64 位模式
            if (self.runtime.readChannel(src_chan)) |v| {
                dst_ptr.* = valueToI64Bits(v);
                return;
            }
            // readChannel 返回 null（非标量或 ptr 为空）：回退到字节复制
            const copy_w = @min(dst_w, 8);
            @memcpy(dst_raw[0..copy_w], src_raw[0..copy_w]);
            return;
        }

        // ref_chan → 标量：读取 8 字节位模式，通过 vtable coerce+write 写入目标标量通道
        if (src_is_ref and !dst_is_ref) {
            const src_ptr: *i64 = @ptrCast(@alignCast(src_raw));
            // 128 位特例：低 64 位补零扩展到 16 字节（lossy）
            if (dst_w == 16) {
                const dp: *[16]u8 = @ptrCast(@alignCast(dst_raw));
                @memset(dp, 0);
                const low_bytes: [8]u8 = @bitCast(src_ptr.*);
                @memcpy(dp[0..8], &low_bytes);
                return;
            }
            // 其他标量类型：构造 Value 并走 writeChannel（coerce+write）
            const v = i64BitsToValue(src_ptr.*, self.runtime.typeDesc(dst_chan));
            if (self.runtime.writeChannel(dst_chan, v)) return;
            // writeChannel 返回 false（非标量）：回退到字节复制
            const copy_w = @min(dst_w, 8);
            @memcpy(dst_raw[0..copy_w], src_raw[0..copy_w]);
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
    /// - null/低地址过滤：addr < 0x1000 不是合法堆对象（null 指针、小整数）
    /// - 对齐检查：堆对象必须按 ObjHeader 对齐
    /// - isValidHeapObj：type_tag 范围 + rc>=1 + flags 未用位为 0
    ///
    /// 废除 tagged scalar ref 后，ref_chan 中的标量引用统一通过 Cell 装箱，
    /// Cell 是真实堆对象，会被正确识别；标量位模式由 isValidHeapObj 过滤。
    pub fn readRefObj(self: *Engine, chan: u16) ?*value.obj_header.ObjHeader {
        const ptr = self.runtime.readPtr(chan) orelse return null;
        const addr = @intFromPtr(ptr);
        if (addr < 0x1000) return null;
        // 过滤内核空间地址（高位置 1，含负 i64 符号扩展），防止标量位模式误判为堆指针
        if (addr >= 0x8000000000000000) return null;
        if (addr % @alignOf(value.obj_header.ObjHeader) != 0) return null;
        // 使用 msync 安全检查页面是否映射，避免对标量位模式调用 isValidHeapObj 导致段错误
        if (!ir_mod.type_descriptor_mod.isReadable(addr)) return null;
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
    /// 统一通过 scalar_ops vtable 读取（标量/ref/unit/null 全覆盖）。
    /// ref_chan 中若是 LazyValue，会自动强制求值一次并返回其结果（缓存借用）。
    pub fn readScalarValue(self: *Engine, chan: u16) EngineError!value.Value {
        // 统一路径：通过 scalar_ops vtable 读取
        if (self.runtime.readChannel(chan)) |v| {
            // LazyValue 自动求值
            if (v == .ref and v.ref.type_tag == .lazy_val) {
                const lazy: *value.LazyValue = @alignCast(@fieldParentPtr("header", v.ref));
                return try self.forceLazyValue(lazy);
            }
            return v;
        }
        // readChannel 返回 null：
        // - ref_chan ptr 未初始化 → 返回 null
        // - nullable_chan → 返回 unit
        if (self.runtime.isRef(chan)) return value.Value.fromNull();
        return value.Value.fromUnit();
    }

    /// 将标量 Value 转为 i64 位模式（用于写入 ref_chan 8 字节存储）
    /// 整数符号扩展为 i64，浮点按位模式写入（f16/f32 提升为 f64 再转位模式）。
    /// i128/u128/f128（16 字节）截断到低 64 位（lossy）。
    /// ref/null_val/unit 转 0（空指针语义）。
    fn valueToI64Bits(v: value.Value) i64 {
        return switch (v) {
            .ref => |r| @bitCast(@intFromPtr(r)),
            .null_val, .unit => 0,
            // 整数：符号扩展为 i64
            .i8 => |b| @as(i64, @as(i8, @bitCast(b[0]))),
            .u8 => |b| @as(i64, b[0]),
            .i16 => |b| @as(i64, @as(i16, @bitCast(b))),
            .u16 => |b| @as(i64, @as(u16, @bitCast(b))),
            .i32 => |b| @as(i64, @as(i32, @bitCast(b))),
            .u32 => |b| @as(i64, @as(u32, @bitCast(b))),
            .i64 => |b| @bitCast(b),
            .u64 => |b| @bitCast(@as(u64, @bitCast(b))),
            .isize => |b| @as(i64, @as(isize, @bitCast(b))),
            .usize => |b| @bitCast(@as(u64, @as(usize, @bitCast(b)))),
            .boolean => |b| @intFromBool(b[0] != 0),
            .char => |b| @as(i64, @intCast(@as(u32, @bitCast(b)))),
            // 浮点：按位模式写入（f16/f32 提升为 f64）
            .f16 => |b| @bitCast(@as(f64, @floatCast(@as(f16, @bitCast(b))))),
            .f32 => |b| @bitCast(@as(f64, @floatCast(@as(f32, @bitCast(b))))),
            .f64 => |b| @bitCast(@as(f64, @bitCast(b))),
            // i128/u128/f128：截断到低 64 位（lossy）
            .i128 => |b| @truncate(@as(i128, @bitCast(b))),
            .u128 => |b| @bitCast(@as(u64, @truncate(@as(u128, @bitCast(b))))),
            .f128 => |b| @bitCast(@as(f64, @floatCast(@as(f128, @bitCast(b))))),
        };
    }

    /// 将 i64 位模式转为目标标量类型的 Value（用于从 ref_chan 读取后写入标量通道）
    /// 统一通过 type_desc.scalar_ops.coerce vtable 分派，零运行时 switch。
    /// 将 i64 bits 包装为 Value.fromI64，再由目标类型的 coerce 函数转换为目标类型。
    /// 目标为 128 位类型时不调用此函数（由 copyCrossType 特例处理）。
    fn i64BitsToValue(bits: i64, dst_type_desc: *const ir_mod.type_descriptor_mod.TypeDescriptor) value.Value {
        const i64_val = value.Value.fromI64(bits);
        if (dst_type_desc.scalar_ops) |ops| return ops.coerce(i64_val);
        return i64_val;
    }

    /// 将标量值写入通道（统一通过 scalar_ops vtable coerce + write）
    /// 标量 + ref_chan + unit/null 均有 vtable，writeChannel 全覆盖。
    /// ref_ops.write 内部调用 valueToI64Bits，与旧的 ref_chan 特例等价。
    /// nullable_chan 无 scalar_ops，writeChannel 返回 false（由 valueToChan 处理）。
    pub fn writeScalarValue(self: *Engine, chan: u16, v: value.Value) void {
        _ = self.runtime.writeChannel(chan, v);
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
