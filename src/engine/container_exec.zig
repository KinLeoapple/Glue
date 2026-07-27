//! 容器（字符串/数组/记录）执行函数（v3 阶段 5.3：从 engine.zig 物理拆分）
//!
//! 包含 execString* / execArray* / execRecord* 等执行函数，以及 UTF-8 辅助函数
//! utf8SeqLen / decodeUtf8Codepoint。
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
const ScalarTag = value.scalar.ScalarTag;

pub const Methods = struct {
    // ════════════════════════════════════════════
    // 字符串操作
    // ════════════════════════════════════════════

    /// string_len：返回字符串 Unicode 标量值数量（字符数）
    /// inputs[0] = str 通道，output = usize 通道
    pub fn execStringLen(self: *Engine, node: *const Node) EngineError!void {
        const src_chan = node.inputs[0];
        const src_meta = self.ir.channels.get(src_chan);

        // nullable_chan：检查 null flag，null 时返回 0
        if (src_meta.chan_type == .nullable_chan) {
            const inner_w = src_meta.inner_type.elemWidth();
            const src = self.runtime.rawPtr(src_chan);
            if (src[inner_w] != 0) {
                self.runtime.writeUsize(node.output, 0);
                return;
            }
            // 非 null：读取 inner ref 指针
            const inner_ptr: usize = std.mem.bytesToValue(usize, src[0..@sizeOf(usize)]);
            if (inner_ptr < 0x1000) {
                self.runtime.writeUsize(node.output, 0);
                return;
            }
            const header: *value.obj_header.ObjHeader = @ptrFromInt(inner_ptr);
            if (header.type_tag != .str) {
                self.runtime.writeUsize(node.output, 0);
                return;
            }
            const sv: *value.str_mod.Str = @alignCast(@fieldParentPtr("header", header));
            const count = sv.codepointCount() catch sv.byteLength();
            self.runtime.writeUsize(node.output, count);
            return;
        }

        // null_chan 或无指针：返回 0
        if (src_meta.chan_type == .null_chan or src_chan >= self.runtime.chan_count or self.runtime.chanPtrs(src_chan) == null) {
            self.runtime.writeUsize(node.output, 0);
            return;
        }

        const s = self.readStr(src_chan) orelse {
            self.runtime.writeUsize(node.output, 0);
            return;
        };
        const count = s.codepointCount() catch s.byteLength();
        self.runtime.writeUsize(node.output, count);
    }

    /// string_concat：拼接两个字符串
    /// inputs[0] = left, inputs[1] = right, output = ref_chan
    /// 快速路径：left 为堆模式且 rc==1 时，realloc 就地追加 right，零全量拷贝
    pub fn execStringConcat(self: *Engine, node: *const Node) EngineError!void {
        const left = self.readStr(node.inputs[0]) orelse return error.InvalidChannel;
        const right = self.readStr(node.inputs[1]) orelse return error.InvalidChannel;

        // 就地追加快速路径：复用 left 对象（已 tracked），无需新建 Str、无需 trackObj
        if (left.concatInPlace(self.tctx.?, right)) {
            self.runtime.writePtr(node.output, @ptrCast(&left.header));
            return;
        }

        // 常规路径：创建新 Str 对象（连续内存 [header | buffer]）
        const obj = value.str_mod.Str.concatContiguous(self.tctx.?, left.*, right.*) catch return error.OutOfMemory;
        try self.trackObj(&obj.header);
        self.runtime.writePtr(node.output, @ptrCast(&obj.header));
    }

    /// string_cmp：字符串字典序比较
    /// inputs[0] = left, inputs[1] = right, output = bool_chan
    /// _pad 编码比较种类：0=lt, 1=le, 2=gt, 3=ge
    pub fn execStringCmp(self: *Engine, node: *const Node) EngineError!void {
        const left = self.readStr(node.inputs[0]) orelse return error.InvalidChannel;
        const right = self.readStr(node.inputs[1]) orelse return error.InvalidChannel;
        const order = left.compare(right.*);
        const result: bool = switch (node._pad) {
            0 => order == .lt,
            1 => order != .gt,
            2 => order == .gt,
            3 => order != .lt,
            else => return error.InvalidChannel,
        };
        self.runtime.writeBool(node.output, result);
    }

    /// string_index：按字符索引获取 UTF-8 码点
    /// inputs[0] = str, inputs[1] = index, output = char_chan
    pub fn execStringIndex(self: *Engine, node: *const Node) EngineError!void {
        const s = self.readStr(node.inputs[0]) orelse return error.InvalidChannel;
        const idx = try self.readIntAsI64(node.inputs[1]);
        const bytes = s.bytes();
        if (idx < 0) return error.Overflow;

        // UTF-8 解码：按码点序列索引
        var byte_pos: usize = 0;
        var char_idx: i64 = 0;
        while (byte_pos < bytes.len) {
            if (char_idx == idx) {
                const codepoint = decodeUtf8Codepoint(bytes[byte_pos..]) catch {
                    // 解码失败，回退到单字节
                    const cp: u32 = @intCast(bytes[byte_pos]);
                    const ptr: *u32 = @ptrCast(@alignCast(self.runtime.rawPtr(node.output)));
                    ptr.* = cp;
                    return;
                };
                const ptr: *u32 = @ptrCast(@alignCast(self.runtime.rawPtr(node.output)));
                ptr.* = codepoint;
                return;
            }
            const seq_len = utf8SeqLen(bytes[byte_pos]);
            byte_pos += seq_len;
            char_idx += 1;
        }
        return error.Overflow;
    }

    /// 返回 UTF-8 序列长度（1-4），无效首字节返回 1
    pub fn utf8SeqLen(byte: u8) usize {
        if (byte < 0x80) return 1;
        if (byte & 0xE0 == 0xC0) return 2;
        if (byte & 0xF0 == 0xE0) return 3;
        if (byte & 0xF8 == 0xF0) return 4;
        return 1; // 无效首字节，按 1 处理
    }

    /// 手动解码 UTF-8 码点，避免 std.unicode.utf8Decode 的 unreachable
    pub fn decodeUtf8Codepoint(bytes: []const u8) !u32 {
        if (bytes.len == 0) return error.InvalidUtf8;
        const b0 = bytes[0];
        if (b0 < 0x80) return @intCast(b0);
        if (b0 & 0xE0 == 0xC0) {
            if (bytes.len < 2) return error.InvalidUtf8;
            return @as(u32, @intCast(b0 & 0x1F)) << 6 | @as(u32, @intCast(bytes[1] & 0x3F));
        }
        if (b0 & 0xF0 == 0xE0) {
            if (bytes.len < 3) return error.InvalidUtf8;
            return @as(u32, @intCast(b0 & 0x0F)) << 12 |
                @as(u32, @intCast(bytes[1] & 0x3F)) << 6 |
                @as(u32, @intCast(bytes[2] & 0x3F));
        }
        if (b0 & 0xF8 == 0xF0) {
            if (bytes.len < 4) return error.InvalidUtf8;
            return @as(u32, @intCast(b0 & 0x07)) << 18 |
                @as(u32, @intCast(bytes[1] & 0x3F)) << 12 |
                @as(u32, @intCast(bytes[2] & 0x3F)) << 6 |
                @as(u32, @intCast(bytes[3] & 0x3F));
        }
        return error.InvalidUtf8;
    }

    // ════════════════════════════════════════════
    // 数组操作
    // ════════════════════════════════════════════

    /// array_make：创建数组
    /// inputs[0] = length 通道（i64），output = ref_chan
    /// 逃逸分析驱动：非逃逸函数内的数组走 ShadowArena，endFunction 时 O(1) reset
    pub fn execArrayMake(self: *Engine, node: *const Node) EngineError!void {
        const len = try self.readIntAsI64(node.inputs[0]);
        if (len < 0) return error.Overflow;
        const n: usize = @intCast(len);
        // _pad bit 0：元素类型是否为 &T / *T
        const elem_is_ref = (node._pad & 1) != 0;
        // 临时元素切片（makeArray 会拷贝到连续内存，此处仅临时用）
        const elements = self.tctx.?.backing.alloc(value.Value, n) catch return error.OutOfMemory;
        defer self.tctx.?.backing.free(elements);
        for (elements) |*e| e.* = value.Value.fromUnit();

        const use_arena = self.currentFuncUseArena();
        const v = if (use_arena) blk: {
            // arena 分配：header + elements 连续，均从 ShadowArena 分配
            // n 极大时 n*sizeOf(Value) 和 +sizeOf(ArrayValue) 会溢出 usize，
            // 导致分配小缓冲后越界写入。用 std.math.mul/add 检测溢出返回 OOM。
            const elems_size = std.math.mul(usize, n, @sizeOf(value.Value)) catch return error.OutOfMemory;
            const total = std.math.add(usize, @sizeOf(value.ArrayValue), elems_size) catch return error.OutOfMemory;
            const arena_mem = self.tctx.?.allocObjArena(total) catch return error.OutOfMemory;
            const arr: *value.ArrayValue = @ptrCast(@alignCast(arena_mem.ptr));
            const elems_ptr: [*]value.Value = @ptrCast(@alignCast(arena_mem.ptr + @sizeOf(value.ArrayValue)));
            @memcpy(elems_ptr[0..n], elements);
            arr.* = .{ .elements = elems_ptr[0..n], .capacity = n, .fixed_size = null, .elem_is_ref = elem_is_ref };
            value.obj_header.initObjHeader(&arr.header, .array, total, true, self.tctx.?);
            break :blk value.Value.fromRef(&arr.header);
        } else
            value.Value.makeArrayEx(self.tctx.?, elements, null, elem_is_ref) catch return error.OutOfMemory;
        try self.trackObj(v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(v.asRef()));
    }

    /// array_get：按索引获取元素
    /// inputs[0] = array, inputs[1] = index, output = 元素通道
    pub fn execArrayGet(self: *Engine, node: *const Node) EngineError!void {
        const arr = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
        const idx = try self.readIntAsI64(node.inputs[1]);
        if (idx < 0 or @as(usize, @intCast(idx)) >= arr.elements.len) return error.Overflow;
        const v = arr.elements[@intCast(idx)];
        const copied = try self.cloneValueForContainer(v, arr.elem_is_ref);
        self.valueToChan(node.output, copied);
    }

    /// array_set：按索引设置元素
    /// inputs[0] = array, inputs[1] = index, inputs[2] = value
    pub fn execArraySet(self: *Engine, node: *const Node) EngineError!void {
        const arr = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
        const idx = try self.readIntAsI64(node.inputs[1]);
        if (idx < 0 or @as(usize, @intCast(idx)) >= arr.elements.len) return error.Overflow;
        const v = self.chanToValue(node.inputs[2]);
        const copied = try self.cloneValueForContainer(v, arr.elem_is_ref);
        const old = arr.elements[@intCast(idx)];
        arr.elements[@intCast(idx)] = copied;
        old.release(self.tctx.?);
    }

    /// array_len：返回数组长度
    /// inputs[0] = array, output = usize（Phase 5: 从 i64 改为 usize）
    pub fn execArrayLen(self: *Engine, node: *const Node) EngineError!void {
        const arr = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
        self.runtime.writeUsize(node.output, arr.elements.len);
    }

    /// array_push：向数组追加元素（扩容）
    /// inputs[0] = array, inputs[1] = value
    /// arena 数组扩容：新 elements 也从 arena 分配，旧 elements 不释放（arena.reset 统一回收）
    pub fn execArrayPush(self: *Engine, node: *const Node) EngineError!void {
        const arr = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
        const v = self.chanToValue(node.inputs[1]);
        const copied = try self.cloneValueForContainer(v, arr.elem_is_ref);
        const old_len = arr.elements.len;
        const new_len = old_len + 1;
        const use_arena = arr.header.isArenaAllocated();
        const new_size = new_len * @sizeOf(value.Value);
        // alloc 失败时必须释放已克隆的 copied，避免泄漏
        const buf = if (use_arena)
            self.tctx.?.allocObjArena(new_size) catch {
                copied.release(self.tctx.?);
                return error.OutOfMemory;
            }
        else
            self.tctx.?.allocObj(new_size) catch {
                copied.release(self.tctx.?);
                return error.OutOfMemory;
            };
        const new_elements: []value.Value = @as([*]value.Value, @ptrCast(@alignCast(buf.ptr)))[0..new_len];
        @memcpy(new_elements[0..old_len], arr.elements);
        new_elements[old_len] = copied;
        // arena 数组的旧 elements 由 arena.reset 统一回收，跳过 freeObj
        if (!use_arena and arr.elements.len > 0) {
            self.tctx.?.freeObj(@ptrCast(arr.elements.ptr));
        }
        arr.elements = new_elements;
        arr.capacity = new_len;
        self.runtime.writePtr(node.output, @ptrCast(&arr.header));
    }

    /// array_concat：拼接两个数组，返回新数组
    /// inputs[0] = left, inputs[1] = right, output = ref_chan
    /// 逃逸分析驱动：非逃逸函数内的拼接结果走 ShadowArena
    pub fn execArrayConcat(self: *Engine, node: *const Node) EngineError!void {
        const left = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
        const right = self.readArray(node.inputs[1]) orelse return error.InvalidChannel;
        const new_len = left.elements.len + right.elements.len;
        const elem_is_ref = left.elem_is_ref;
        // 临时元素切片（makeArray 会拷贝到自有缓冲区）
        const new_elements = self.tctx.?.backing.alloc(value.Value, new_len) catch return error.OutOfMemory;
        defer self.tctx.?.backing.free(new_elements);
        var i: usize = 0;
        // 元素所有权未转移给新数组前（clone 失败或 makeArrayEx/arena 失败），需释放已克隆元素
        var elements_consumed = false;
        errdefer {
            if (!elements_consumed) {
                for (new_elements[0..i]) |elem| elem.release(self.tctx.?);
            }
        }
        for (left.elements) |elem| {
            new_elements[i] = try self.cloneValueForContainer(elem, elem_is_ref);
            i += 1;
        }
        for (right.elements) |elem| {
            new_elements[i] = try self.cloneValueForContainer(elem, elem_is_ref);
            i += 1;
        }

        const use_arena = self.currentFuncUseArena();
        const v = if (use_arena) blk: {
            const elems_size = new_len * @sizeOf(value.Value);
            const total = @sizeOf(value.ArrayValue) + elems_size;
            const arena_mem = self.tctx.?.allocObjArena(total) catch return error.OutOfMemory;
            const arr: *value.ArrayValue = @ptrCast(@alignCast(arena_mem.ptr));
            const elems_ptr: [*]value.Value = @ptrCast(@alignCast(arena_mem.ptr + @sizeOf(value.ArrayValue)));
            @memcpy(elems_ptr[0..new_len], new_elements);
            arr.* = .{ .elements = elems_ptr[0..new_len], .capacity = new_len, .fixed_size = null, .elem_is_ref = elem_is_ref };
            value.obj_header.initObjHeader(&arr.header, .array, total, true, self.tctx.?);
            break :blk value.Value.fromRef(&arr.header);
        } else
            value.Value.makeArrayEx(self.tctx.?, new_elements, null, elem_is_ref) catch return error.OutOfMemory;
        // makeArrayEx/arena 成功，元素所有权已转移给新数组 v，失败时不再释放 new_elements
        elements_consumed = true;
        try self.trackObj(v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(v.asRef()));
    }

    /// array_fill：创建 count 个 value 副本的数组
    /// inputs[0] = count, inputs[1] = value, output = ref_chan
    pub fn execArrayFill(self: *Engine, node: *const Node) EngineError!void {
        const count = try self.readIntAsI64(node.inputs[0]);
        if (count < 0) return error.Overflow;
        const n: usize = @intCast(count);
        const fill_value = self.chanToValue(node.inputs[1]);
        // 元素类型是否为 &T / *T：优先从 fill_value 通道的 is_ref 读取
        const elem_is_ref = self.ir.channels.get(node.inputs[1]).is_ref;

        const use_arena = self.currentFuncUseArena();
        const v = if (use_arena) blk: {
            // n 极大时 n*sizeOf(Value) 和 +sizeOf(ArrayValue) 会溢出 usize，
            // 导致分配小缓冲后越界写入。用 std.math.mul/add 检测溢出返回 OOM。
            const elems_size = std.math.mul(usize, n, @sizeOf(value.Value)) catch return error.OutOfMemory;
            const total = std.math.add(usize, @sizeOf(value.ArrayValue), elems_size) catch return error.OutOfMemory;
            const arena_mem = self.tctx.?.allocObjArena(total) catch return error.OutOfMemory;
            const arr: *value.ArrayValue = @ptrCast(@alignCast(arena_mem.ptr));
            const elems_ptr: [*]value.Value = @ptrCast(@alignCast(arena_mem.ptr + @sizeOf(value.ArrayValue)));
            // 按元素类型语义逐个填充；失败时释放已克隆元素（arena 内存由 reset 回收，但堆引用需 release）
            var filled: usize = 0;
            errdefer {
                for (elems_ptr[0..filled]) |elem| elem.release(self.tctx.?);
            }
            if (n > 0) {
                for (0..n) |j| {
                    elems_ptr[j] = try self.cloneValueForContainer(fill_value, elem_is_ref);
                    filled = j + 1;
                }
            }
            arr.* = .{ .elements = elems_ptr[0..n], .capacity = n, .fixed_size = null, .elem_is_ref = elem_is_ref };
            value.obj_header.initObjHeader(&arr.header, .array, total, true, self.tctx.?);
            break :blk value.Value.fromRef(&arr.header);
        } else blk: {
            // 非 arena 路径：先分配临时数组，按元素类型语义填充
            const tmp = self.tctx.?.backing.alloc(value.Value, n) catch return error.OutOfMemory;
            defer self.tctx.?.backing.free(tmp);
            var filled: usize = 0;
            errdefer {
                for (tmp[0..filled]) |elem| elem.release(self.tctx.?);
            }
            for (0..n) |j| {
                tmp[j] = try self.cloneValueForContainer(fill_value, elem_is_ref);
                filled = j + 1;
            }
            // makeArrayEx 拷贝 tmp 到自有缓冲区；失败时 errdefer 释放 tmp 元素
            break :blk value.Value.makeArrayEx(self.tctx.?, tmp, null, elem_is_ref) catch return error.OutOfMemory;
        };
        try self.trackObj(v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(v.asRef()));
    }

    /// array_slice：数组切片
    /// inputs[0] = arr, inputs[1] = start, inputs[2] = end
    /// _pad: 0 = 左闭右开 [start, end)，1 = 左闭右闭 [start, end]
    pub fn execArraySlice(self: *Engine, node: *const Node) EngineError!void {
        const arr = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
        const start = try self.readIntAsI64(node.inputs[1]);
        const end_raw = try self.readIntAsI64(node.inputs[2]);
        if (start < 0) return error.Overflow;
        const s: usize = @intCast(start);
        // 计算实际结束位置
        const e: usize = if (node._pad == 1) blk: {
            // 左闭右闭 [start, end]
            if (end_raw < 0) return error.Overflow;
            break :blk @as(usize, @intCast(end_raw)) + 1;
        } else blk: {
            // 左闭右开 [start, end)
            if (end_raw < 0) return error.Overflow;
            break :blk @as(usize, @intCast(end_raw));
        };
        if (s > arr.elements.len or e > arr.elements.len or s > e) return error.Overflow;
        const new_len = e - s;
        const elem_is_ref = arr.elem_is_ref;
        const new_elements = self.tctx.?.backing.alloc(value.Value, new_len) catch return error.OutOfMemory;
        defer self.tctx.?.backing.free(new_elements);
        var j: usize = 0;
        // 元素所有权未转移给新数组前（clone 失败或 makeArrayEx/arena 失败），需释放已克隆元素
        var elements_consumed = false;
        errdefer {
            if (!elements_consumed) {
                for (new_elements[0..j]) |elem| elem.release(self.tctx.?);
            }
        }
        for (arr.elements[s..e]) |elem| {
            new_elements[j] = try self.cloneValueForContainer(elem, elem_is_ref);
            j += 1;
        }

        const use_arena = self.currentFuncUseArena();
        const v = if (use_arena) blk: {
            const elems_size = new_len * @sizeOf(value.Value);
            const total = @sizeOf(value.ArrayValue) + elems_size;
            const arena_mem = self.tctx.?.allocObjArena(total) catch return error.OutOfMemory;
            const new_arr: *value.ArrayValue = @ptrCast(@alignCast(arena_mem.ptr));
            const elems_ptr: [*]value.Value = @ptrCast(@alignCast(arena_mem.ptr + @sizeOf(value.ArrayValue)));
            @memcpy(elems_ptr[0..new_len], new_elements);
            new_arr.* = .{ .elements = elems_ptr[0..new_len], .capacity = new_len, .fixed_size = null, .elem_is_ref = elem_is_ref };
            value.obj_header.initObjHeader(&new_arr.header, .array, total, true, self.tctx.?);
            break :blk value.Value.fromRef(&new_arr.header);
        } else
            value.Value.makeArrayEx(self.tctx.?, new_elements, null, elem_is_ref) catch return error.OutOfMemory;
        // makeArrayEx/arena 成功，元素所有权已转移给新数组 v，失败时不再释放 new_elements
        elements_consumed = true;
        try self.trackObj(v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(v.asRef()));
    }

    /// array_first：返回数组首元素（nullable 输出，空数组返回 null）
    pub fn execArrayFirst(self: *Engine, node: *const Node) EngineError!void {
        const arr = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
        const inner_w = self.nullableInnerWidth(node.output);
        const dst = self.runtime.rawPtr(node.output);
        if (arr.elements.len == 0) {
            if (inner_w > 0) dst[inner_w] = 1; // null 标志
            return;
        }
        self.valueToRawPtr(dst, inner_w, arr.elements[0]);
        if (inner_w > 0) dst[inner_w] = 0; // 清除 null 标志
    }

    /// array_last：返回数组末尾元素（nullable 输出，空数组返回 null）
    pub fn execArrayLast(self: *Engine, node: *const Node) EngineError!void {
        const arr = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
        const inner_w = self.nullableInnerWidth(node.output);
        const dst = self.runtime.rawPtr(node.output);
        if (arr.elements.len == 0) {
            if (inner_w > 0) dst[inner_w] = 1; // null 标志
            return;
        }
        self.valueToRawPtr(dst, inner_w, arr.elements[arr.elements.len - 1]);
        if (inner_w > 0) dst[inner_w] = 0; // 清除 null 标志
    }

    /// array_contains：检查数组是否包含某值
    pub fn execArrayContains(self: *Engine, node: *const Node) EngineError!void {
        const arr = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
        const target = self.chanToValue(node.inputs[1]);
        var found = false;
        for (arr.elements) |elem| {
            if (value.equals(elem, target)) {
                found = true;
                break;
            }
        }
        self.runtime.writeBool(node.output, found);
    }

    /// array_get_safe：安全索引，越界返回 null
    pub fn execArrayGetSafe(self: *Engine, node: *const Node) EngineError!void {
        const arr = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
        const idx = try self.readIntAsI64(node.inputs[1]);
        const inner_w = self.nullableInnerWidth(node.output);
        const dst = self.runtime.rawPtr(node.output);
        if (idx < 0 or @as(usize, @intCast(idx)) >= arr.elements.len) {
            dst[inner_w] = 1;
            return;
        }
        const v = arr.elements[@intCast(idx)];
        self.valueToRawPtr(dst, inner_w, v);
        dst[inner_w] = 0;
    }

    /// array_drop_last：返回去掉末尾元素的新数组（空数组返回空数组）
    pub fn execArrayDropLast(self: *Engine, node: *const Node) EngineError!void {
        const arr = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
        if (arr.elements.len == 0) {
            // 空数组 → 返回空数组
            const v = value.Value.makeArray(self.tctx.?, &[_]value.Value{}, null) catch return error.OutOfMemory;
            try self.trackObj(v.asRef());
            self.runtime.writePtr(node.output, @ptrCast(v.asRef()));
            return;
        }
        const new_len = arr.elements.len - 1;
        // 临时元素切片（makeArray 会拷贝到自有缓冲区）
        const new_elements = self.tctx.?.backing.alloc(value.Value, new_len) catch return error.OutOfMemory;
        defer self.tctx.?.backing.free(new_elements);
        @memcpy(new_elements, arr.elements[0..new_len]);
        const v = value.Value.makeArray(self.tctx.?, new_elements, null) catch return error.OutOfMemory;
        try self.trackObj(v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(v.asRef()));
    }

    /// array_pop：弹出末尾元素并返回（空数组返回 null）
    pub fn execArrayPop(self: *Engine, node: *const Node) EngineError!void {
        const arr = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
        if (arr.elements.len == 0) {
            // 空数组 → 返回 null
            self.runtime.writePtr(node.output, null);
            return;
        }
        const last_idx = arr.elements.len - 1;
        const v = arr.elements[last_idx];
        const new_len = last_idx;
        // arena 数组扩容/缩容与 push 保持一致：arena 分配新 elements，旧 elements 由 reset 回收
        const use_arena = arr.header.isArenaAllocated();
        if (new_len == 0) {
            if (!use_arena and arr.elements.len > 0) {
                self.tctx.?.freeObj(@ptrCast(arr.elements.ptr));
            }
            arr.elements = &.{};
            arr.capacity = 0;
        } else {
            const new_size = new_len * @sizeOf(value.Value);
            const buf = if (use_arena)
                self.tctx.?.allocObjArena(new_size) catch return error.OutOfMemory
            else
                self.tctx.?.allocObj(new_size) catch return error.OutOfMemory;
            const new_elements: []value.Value = @as([*]value.Value, @ptrCast(@alignCast(buf.ptr)))[0..new_len];
            @memcpy(new_elements, arr.elements[0..new_len]);
            if (!use_arena) {
                self.tctx.?.freeObj(@ptrCast(arr.elements.ptr));
            }
            arr.elements = new_elements;
            arr.capacity = new_len;
        }
        self.valueToChan(node.output, v);
    }

    /// string_contains：检查字符串是否包含子串
    pub fn execStringContains(self: *Engine, node: *const Node) EngineError!void {
        const haystack = self.readStr(node.inputs[0]) orelse return error.InvalidChannel;
        const needle = self.readStr(node.inputs[1]) orelse return error.InvalidChannel;
        self.runtime.writeBool(node.output, std.mem.indexOf(u8, haystack.bytes(), needle.bytes()) != null);
    }

    /// string_slice：字符串切片（按 Unicode 标量值索引）
    /// inputs[0] = s, inputs[1] = start, inputs[2] = end
    /// _pad: 0 = 左闭右开 [start, end)，1 = 左闭右闭 [start, end]
    /// start/end 是字符索引（不是字节索引），内部按 UTF-8 解码定位字节位置
    pub fn execStringSlice(self: *Engine, node: *const Node) EngineError!void {
        const s = self.readStr(node.inputs[0]) orelse return error.InvalidChannel;
        const start = try self.readIntAsI64(node.inputs[1]);
        const end_raw = try self.readIntAsI64(node.inputs[2]);
        if (start < 0) return error.Overflow;
        const start_idx: usize = @intCast(start);
        const end_idx: usize = if (node._pad == 1) blk: {
            if (end_raw < 0) return error.Overflow;
            break :blk @as(usize, @intCast(end_raw)) + 1;
        } else blk: {
            if (end_raw < 0) return error.Overflow;
            break :blk @as(usize, @intCast(end_raw));
        };
        if (start_idx > end_idx) return error.Overflow;
        const bytes = s.bytes();
        // 定位 start 字节位置
        var byte_pos: usize = 0;
        var char_idx: usize = 0;
        while (byte_pos < bytes.len and char_idx < start_idx) {
            byte_pos += utf8SeqLen(bytes[byte_pos]);
            char_idx += 1;
        }
        if (char_idx != start_idx) return error.Overflow;
        const start_byte = byte_pos;
        // 定位 end 字节位置
        while (byte_pos < bytes.len and char_idx < end_idx) {
            byte_pos += utf8SeqLen(bytes[byte_pos]);
            char_idx += 1;
        }
        // end 超出字符数时报错（与 start 越界行为一致），而非静默截断到字符串末尾
        if (char_idx != end_idx) return error.Overflow;
        const end_byte = byte_pos;
        // 创建子字符串
        const sub_bytes = bytes[start_byte..end_byte];
        const new_str = value.str_mod.Str.createContiguous(self.tctx.?, sub_bytes) catch return error.OutOfMemory;
        try self.trackObj(&new_str.header);
        self.runtime.writePtr(node.output, @ptrCast(&new_str.header));
    }

    /// string_bytes：字符串转 u8[]（UTF-8 编码）
    /// inputs[0] = s, output = ref_chan (ArrayValue<u8>)
    pub fn execStringBytes(self: *Engine, node: *const Node) EngineError!void {
        const s = self.readStr(node.inputs[0]) orelse return error.InvalidChannel;
        const bytes = s.bytes();
        const n = bytes.len;
        // 临时 u8 Value 数组
        const tmp = self.tctx.?.backing.alloc(value.Value, n) catch return error.OutOfMemory;
        defer self.tctx.?.backing.free(tmp);
        for (bytes, 0..) |b, i| {
            tmp[i] = value.Value.fromU8(b);
        }
        const use_arena = self.currentFuncUseArena();
        const v = if (use_arena) blk: {
            // n 极大时 n*sizeOf(Value) 和 +sizeOf(ArrayValue) 会溢出 usize，
            // 导致分配小缓冲后越界写入。用 std.math.mul/add 检测溢出返回 OOM。
            const elems_size = std.math.mul(usize, n, @sizeOf(value.Value)) catch return error.OutOfMemory;
            const total = std.math.add(usize, @sizeOf(value.ArrayValue), elems_size) catch return error.OutOfMemory;
            const arena_mem = self.tctx.?.allocObjArena(total) catch return error.OutOfMemory;
            const arr: *value.ArrayValue = @ptrCast(@alignCast(arena_mem.ptr));
            const elems_ptr: [*]value.Value = @ptrCast(@alignCast(arena_mem.ptr + @sizeOf(value.ArrayValue)));
            @memcpy(elems_ptr[0..n], tmp);
            arr.* = .{ .elements = elems_ptr[0..n], .capacity = n, .fixed_size = null };
            value.obj_header.initObjHeader(&arr.header, .array, total, true, self.tctx.?);
            break :blk value.Value.fromRef(&arr.header);
        } else
            value.Value.makeArray(self.tctx.?, tmp, null) catch return error.OutOfMemory;
        try self.trackObj(v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(v.asRef()));
    }

    /// array_to_str：u8[] 转字符串（UTF-8 解码）
    /// inputs[0] = arr (ArrayValue<u8>), output = ref_chan (Str)
    pub fn execArrayToStr(self: *Engine, node: *const Node) EngineError!void {
        const arr = self.readArray(node.inputs[0]) orelse return error.InvalidChannel;
        // 收集字节数据
        const n = arr.elements.len;
        const tmp_bytes = self.tctx.?.backing.alloc(u8, n) catch return error.OutOfMemory;
        defer self.tctx.?.backing.free(tmp_bytes);
        for (arr.elements, 0..) |elem, i| {
            tmp_bytes[i] = elem.asU8();
        }
        const new_str = value.str_mod.Str.createContiguous(self.tctx.?, tmp_bytes) catch return error.OutOfMemory;
        try self.trackObj(&new_str.header);
        self.runtime.writePtr(node.output, @ptrCast(&new_str.header));
    }

    // ════════════════════════════════════════════
    // 记录操作
    // ════════════════════════════════════════════

    /// record_make：创建空记录，预分配 field_count 个槽位
    /// meta.const_val.int_val 编码：(field_count << 32) | type_name_pool_idx
    /// 字段表初始化为 unit（后续 record_set 覆写）
    /// 优化：直接在 allocObj 连续内存上初始化 fields，跳过临时数组 alloc/free + memcpy
    /// 逃逸分析驱动：非逃逸函数内的记录走 ShadowArena，endFunction 时 O(1) reset
    pub inline fn execRecordMake(self: *Engine, node: *const Node) EngineError!void {
        const meta = if (node.meta_index < self.ir.scalar_metas.len) self.ir.scalar_metas[node.meta_index] else return error.InvalidMetaIndex;
        const packed_val = if (meta.const_val) |cv| switch (cv) {
            .int_val => |iv| iv,
            else => return error.InvalidMetaIndex,
        } else return error.InvalidMetaIndex;
        // meta 编码：(field_ref_bits << 64) | (field_count << 32) | type_name_pool_idx
        const bits: u128 = @bitCast(packed_val);
        const type_name_idx: usize = @intCast(@as(u32, @truncate(bits)));
        const field_count: u32 = @truncate(bits >> 32);
        const field_ref_bits: u64 = @truncate(bits >> 64);
        const type_name = if (type_name_idx < self.ir.string_pool.len) self.ir.string_pool[type_name_idx] else "";

        // 直接分配连续内存：[RecordValue header | Value fields[]]
        // 在连续内存上直接初始化 fields 为 unit，无需临时数组 + memcpy
        const f_size = field_count * @sizeOf(value.Value);
        const total = @sizeOf(value.RecordValue) + f_size;
        const use_arena = self.currentFuncUseArena();
        const obj_mem = if (use_arena)
            self.tctx.?.allocObjArena(total) catch return error.OutOfMemory
        else
            self.tctx.?.allocObj(total) catch return error.OutOfMemory;
        const rec: *value.RecordValue = @ptrCast(@alignCast(obj_mem.ptr));
        const f_ptr: [*]value.Value = @ptrCast(@alignCast(obj_mem.ptr + @sizeOf(value.RecordValue)));
        // 初始化 fields 为 unit（连续内存，单次 memset）
        @memset(f_ptr[0..field_count], value.Value.unit);
        rec.* = .{ .type_name = type_name, .fields = f_ptr[0..field_count], .field_ref_bits = field_ref_bits };
        value.obj_header.initObjHeader(&rec.header, .record, total, use_arena, self.tctx.?);
        const v = value.Value.fromRef(&rec.header);
        try self.trackObj(v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(v.asRef()));
    }

    /// record_get：按 field_id 读取字段值
    /// meta.const_val.int_val = field_id（u16 范围）
    /// inputs[0] = record_chan
    /// null/无效记录时安全写零（用于 ?. 安全访问中 unwrap null 后的 record_get）
    /// 优化：_pad 预计算 field_id（< 256 时），scalar_tag 预计算输出通道类型
    pub inline fn execRecordGet(self: *Engine, node: *const Node) EngineError!void {
        // 快速路径：_pad 预计算了 field_id（< 256）
        const field_id: u16 = if (node._pad != 0xFF) node._pad else blk: {
            const meta = if (node.meta_index < self.ir.scalar_metas.len) self.ir.scalar_metas[node.meta_index] else return error.InvalidMetaIndex;
            if (meta.const_val) |cv| switch (cv) {
                .int_val => |iv| break :blk @intCast(@as(u32, @truncate(@as(u64, @bitCast(@as(i64, @truncate(iv))))))),
                else => return error.InvalidMetaIndex,
            } else return error.InvalidMetaIndex;
        };
        const in_chan = node.inputs[0];
        const rec = self.readRecord(in_chan) orelse {
            // null/无效记录：写零到输出（safe access 场景，vec_select 会选择 null 分支）
            const w = self.runtime.elemWidth(node.output);
            if (w > 0) {
                const dst = self.runtime.rawPtr(node.output);
                @memset(dst[0..w], 0);
            }
            return;
        };
        if (field_id >= rec.fields.len) {
            return error.InvalidChannel;
        }
        const v = rec.fields[field_id];
        // 按字段类型语义复制：&T / *T 共享，普通类型深拷贝
        const copied = try self.cloneValueForContainer(v, rec.fieldIsRef(field_id));

        // 快速路径：scalar_tag 预计算了输出通道类型（标量类型）
        // 且 Value variant 与输出通道类型匹配时，直接 payload 字节复制
        // 跳过 valueToChan 的 17 分支 switch
        if (node.scalar_tag != 0xFF) {
            const tag: ScalarTag = @enumFromInt(node.scalar_tag);
            const dst = self.runtime.rawPtr(node.output);
            // 检查 Value variant 是否与 tag 匹配
            // variant tag 可通过 @intFromEnum(v) 获取（Value 是 tagged union）
            const variant_matches: bool = switch (copied) {
                .boolean => tag == .boolean,
                .char => tag == .char,
                .i8 => tag == .i8, .i16 => tag == .i16, .i32 => tag == .i32,
                .i64 => tag == .i64, .i128 => tag == .i128,
                .u8 => tag == .u8, .u16 => tag == .u16, .u32 => tag == .u32,
                .u64 => tag == .u64, .u128 => tag == .u128,
                .isize => tag == .isize, .usize => tag == .usize,
                .f16 => tag == .f16, .f32 => tag == .f32, .f64 => tag == .f64, .f128 => tag == .f128,
                else => false,
            };
            if (variant_matches) {
                const w: usize = switch (tag) {
                    .boolean, .i8, .u8 => 1,
                    .char, .i16, .u16, .f16 => 2,
                    .i32, .u32, .f32 => 4,
                    .i64, .u64, .f64, .isize, .usize => @sizeOf(isize),
                    .i128, .u128, .f128 => 16,
                };
                const src: [*]const u8 = switch (tag) {
                    .boolean => @ptrCast(&copied.boolean),
                    .char => @ptrCast(&copied.char),
                    .i8 => @ptrCast(&copied.i8),
                    .i16 => @ptrCast(&copied.i16),
                    .i32 => @ptrCast(&copied.i32),
                    .i64 => @ptrCast(&copied.i64),
                    .i128 => @ptrCast(&copied.i128),
                    .u8 => @ptrCast(&copied.u8),
                    .u16 => @ptrCast(&copied.u16),
                    .u32 => @ptrCast(&copied.u32),
                    .u64 => @ptrCast(&copied.u64),
                    .u128 => @ptrCast(&copied.u128),
                    .isize => @ptrCast(&copied.isize),
                    .usize => @ptrCast(&copied.usize),
                    .f16 => @ptrCast(&copied.f16),
                    .f32 => @ptrCast(&copied.f32),
                    .f64 => @ptrCast(&copied.f64),
                    .f128 => @ptrCast(&copied.f128),
                };
                @memcpy(dst[0..w], src[0..w]);
                return;
            }
            // variant 不匹配：回退到 valueToChan（处理类型转换）
        }
        // 回退：非标量通道或 variant 不匹配
        self.valueToChan(node.output, copied);
    }

    /// record_set：按 field_id 写入字段值
    /// meta.const_val.int_val = field_id（u16 范围）
    /// inputs[0] = record_chan, inputs[1] = value_chan
    /// 优化：_pad 预计算 field_id，scalar_tag 预计算 inputs[1] 类型，直接指针读取
    pub inline fn execRecordSet(self: *Engine, node: *const Node) EngineError!void {
        const rec = self.readRecord(node.inputs[0]) orelse return error.InvalidChannel;
        const field_id: u16 = if (node._pad != 0xFF) node._pad else blk: {
            const meta = if (node.meta_index < self.ir.scalar_metas.len) self.ir.scalar_metas[node.meta_index] else return error.InvalidMetaIndex;
            if (meta.const_val) |cv| switch (cv) {
                .int_val => |iv| break :blk @intCast(@as(u32, @truncate(@as(u64, @bitCast(@as(i64, @truncate(iv))))))),
                else => return error.InvalidMetaIndex,
            } else return error.InvalidMetaIndex;
        };
        if (field_id >= rec.fields.len) return error.InvalidChannel;

        // 快速路径：scalar_tag 预计算了 inputs[1] 类型（标量类型）
        // 直接指针读取，构造 Value，跳过 chanToValue 的 17 分支 switch
        const v: value.Value = if (node.scalar_tag != 0xFF) blk: {
            const tag: ScalarTag = @enumFromInt(node.scalar_tag);
            const src = self.runtime.rawPtr(node.inputs[1]);
            break :blk switch (tag) {
                .boolean => value.Value.fromBool(src[0] != 0),
                .char => value.Value{ .char = @bitCast(@as(*u32, @ptrCast(@alignCast(src))).*) },
                .i8 => value.Value.fromI8(@bitCast(src[0])),
                .u8 => value.Value.fromU8(src[0]),
                .i16 => value.Value.fromI16(@bitCast(@as(*i16, @ptrCast(@alignCast(src))).*)),
                .u16 => value.Value.fromU16(@bitCast(@as(*u16, @ptrCast(@alignCast(src))).*)),
                .i32 => value.Value.fromI32(@bitCast(@as(*i32, @ptrCast(@alignCast(src))).*)),
                .u32 => value.Value.fromU32(@bitCast(@as(*u32, @ptrCast(@alignCast(src))).*)),
                .i64 => value.Value.fromI64(@bitCast(@as(*i64, @ptrCast(@alignCast(src))).*)),
                .u64 => value.Value.fromU64(@bitCast(@as(*u64, @ptrCast(@alignCast(src))).*)),
                .i128 => value.Value.fromI128(@bitCast(@as(*i128, @ptrCast(@alignCast(src))).*)),
                .u128 => value.Value.fromU128(@bitCast(@as(*u128, @ptrCast(@alignCast(src))).*)),
                .isize => value.Value.fromIsize(@bitCast(@as(*isize, @ptrCast(@alignCast(src))).*)),
                .usize => value.Value.fromUsize(@bitCast(@as(*usize, @ptrCast(@alignCast(src))).*)),
                .f16 => value.Value.fromF16(@bitCast(@as(*f16, @ptrCast(@alignCast(src))).*)),
                .f32 => value.Value.fromF32(@bitCast(@as(*f32, @ptrCast(@alignCast(src))).*)),
                .f64 => value.Value.fromF64(@bitCast(@as(*f64, @ptrCast(@alignCast(src))).*)),
                .f128 => value.Value.fromF128(@bitCast(@as(*f128, @ptrCast(@alignCast(src))).*)),
            };
        } else self.chanToValue(node.inputs[1]);

        // 按字段类型语义复制新值：&T / *T 共享，普通类型深拷贝
        const copied = try self.cloneValueForContainer(v, rec.fieldIsRef(field_id));
        // release 旧值
        rec.fields[field_id].release(self.tctx.?);
        rec.fields[field_id] = copied;
    }

    /// record_clone：深拷贝记录（用于记录扩展 (...base, field: value)）
    /// inputs[0] = base record_chan，output = new record_chan
    /// meta.const_val.int_val = extra_count（扩展字段数，默认 0）
    /// 优化：直接在 allocObj 连续内存上初始化，跳过临时数组 alloc/free + memcpy
    pub inline fn execRecordClone(self: *Engine, node: *const Node) EngineError!void {
        const base_rec = self.readRecord(node.inputs[0]) orelse return error.InvalidChannel;
        // 读取扩展字段数（_pad 预计算优先，回退到 meta）
        const extra_count: u32 = if (node._pad != 0xFF) node._pad else blk: {
            if (node.meta_index == 0 or node.meta_index >= self.ir.scalar_metas.len) break :blk 0;
            const meta = self.ir.scalar_metas[node.meta_index];
            if (meta.const_val) |cv| switch (cv) {
                .int_val => |iv| break :blk @intCast(@as(u32, @truncate(@as(u64, @bitCast(@as(i64, @truncate(iv))))))),
                else => break :blk 0,
            } else break :blk 0;
        };
        const total = base_rec.fields.len + extra_count;

        // 直接分配连续内存：[RecordValue header | Value fields[]]
        const f_size = total * @sizeOf(value.Value);
        const alloc_total = @sizeOf(value.RecordValue) + f_size;
        const obj_mem = self.tctx.?.allocObj(alloc_total) catch return error.OutOfMemory;
        const new_rec: *value.RecordValue = @ptrCast(@alignCast(obj_mem.ptr));
        const f_ptr: [*]value.Value = @ptrCast(@alignCast(obj_mem.ptr + @sizeOf(value.RecordValue)));
        // 拷贝 base 字段：&T / *T 共享，普通类型深拷贝
        for (base_rec.fields, 0..) |src, i| {
            f_ptr[i] = try self.cloneValueForContainer(src, base_rec.fieldIsRef(@intCast(i)));
        }
        // extra 槽位初始化为 unit
        @memset(f_ptr[base_rec.fields.len..total], value.Value.unit);
        new_rec.* = .{
            .type_name = base_rec.type_name,
            .fields = f_ptr[0..total],
            .field_names = base_rec.field_names,
            .field_ref_bits = base_rec.field_ref_bits,
        };
        value.obj_header.initObjHeader(&new_rec.header, .record, alloc_total, false, self.tctx.?);
        const v = value.Value.fromRef(&new_rec.header);
        try self.trackObj(v.asRef());
        self.runtime.writePtr(node.output, @ptrCast(v.asRef()));
    }
};
