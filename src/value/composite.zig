//! 复合值类型模块
//!
//! 定义 Glue 语言中的复合数据结构：
//! - ArrayValue 数组（header + elements 分离分配，支持动态扩容）
//! - RecordValue 记录（连续内存：header + fields）
//! - AdtValue 代数数据类型（连续内存：header + fields）
//! - NewtypeValue 新类型包装（固定大小）
//! - Cell 可变单元格（固定大小）
//! - Range 整数区间（固定大小）
//!
//! 所有堆对象以 ObjHeader 作为首字段，统一类型识别与引用计数。

const std = @import("std");
const obj_header = @import("obj_header.zig");
const ObjHeader = obj_header.ObjHeader;
const ThreadContext = obj_header.ThreadContext;
const value = @import("mod.zig");
const Value = value.Value;

/// ADT 字段，可带名称
pub const AdtField = struct {
    name: ?[]const u8,
    value: Value,
};

/// 代数数据类型值，由类型名、构造器和字段列表组成
///
/// 连续内存布局：[AdtValue header | AdtField fields...]
/// fields 切片指向尾部连续区域，单次分配单次释放
pub const AdtValue = struct {
    header: ObjHeader = .{ .type_tag = .adt },
    type_name: []const u8,
    constructor: []const u8,
    fields: []AdtField,
    /// 字段引用标记位图：第 i 位为 1 表示第 i 个字段类型为 &T / *T。
    /// 当前限制：最多 64 个字段；超出 64 的字段保守按值语义处理。
    field_ref_bits: u64 = 0,

    /// 释放所有字段值
    /// fields 是连续内存的一部分，由 adtDeinit 中的 freeObj 统一释放
    pub fn deinit(self: *AdtValue, tctx: *ThreadContext) void {
        if (!obj_header.shutdown_mode) {
            for (self.fields) |*f| f.value.release(tctx);
        }
    }

    /// 判断指定字段是否为引用类型（&T / *T）
    pub inline fn fieldIsRef(self: *const AdtValue, field_id: u16) bool {
        if (field_id >= 64) return false;
        return (self.field_ref_bits & (@as(u64, 1) << @intCast(field_id))) != 0;
    }
};

/// 新类型值，包装一个内部值并附加类型名
pub const NewtypeValue = struct {
    header: ObjHeader = .{ .type_tag = .newtype },
    type_name: []const u8,
    inner: Value,

    /// 释放内部值
    pub fn deinit(self: *NewtypeValue, tctx: *ThreadContext) void {
        if (!obj_header.shutdown_mode) {
            self.inner.release(tctx);
        }
    }
};

/// 数组值，支持定长和变长
///
/// header 和 elements 分离分配：header 固定大小（页池），elements 可独立扩容
/// 这是唯一不使用连续内存的变长类型，因为 array_push/pop 需要替换 elements 切片
/// 同时保持 header 地址不变（tracked_objs 引用 header 指针）
pub const ArrayValue = struct {
    header: ObjHeader = .{ .type_tag = .array },
    elements: []Value,
    capacity: usize = 0,
    fixed_size: ?u64 = null,
    /// 元素类型是否为 &T / *T 引用类型。
    /// true 时元素保持引用语义（retain），false 时按值语义深拷贝。
    elem_is_ref: bool = false,

    /// 释放所有元素并回收元素数组内存
    /// header 由 arrayDeinit 中的 freeObj 释放
    /// arena 分配的对象：elements 也从 arena 分配，跳过 freeObj（arena.reset 统一回收）
    pub fn deinit(self: *ArrayValue, tctx: *ThreadContext) void {
        if (!obj_header.shutdown_mode) {
            for (self.elements) |*e| e.release(tctx);
        }
        if (self.elements.len > 0 and !self.header.isArenaAllocated()) {
            tctx.freeObj(@ptrCast(self.elements.ptr));
        }
    }
};

/// 记录值，类型名加具名字段映射
///
/// 连续内存布局：[RecordValue header | Value fields...]
/// fields 切片指向尾部连续区域，单次分配单次释放
/// 字段值可通过 set 替换（in-place 写入连续区域中的槽位）
///
/// 字段存储改为连续 `[]Value` 切片，field_id 即切片索引：
/// - ADT/newtype/error_newtype：field_id=0 是 `__tag`，1..N 是构造器字段
/// - Record literal：field_id=0..N-1 按声明顺序
/// 字段名 → field_id 的映射在 IR builder 阶段完成，运行时零字符串比较。
pub const RecordValue = struct {
    header: ObjHeader = .{ .type_tag = .record },
    type_name: []const u8,
    /// 字段值连续存储，field_id 即索引
    fields: []Value,
    /// 字段名表（与 fields 同长，仅 format/调试用；运行时热路径不访问）
    /// 索引与 fields 对齐：field_names[i] 对应 fields[i] 的名字
    field_names: []const ?[]const u8 = &.{},
    /// 字段引用标记位图：第 i 位为 1 表示第 i 个字段类型为 &T / *T。
    /// 当前限制：最多 64 个字段；超出 64 的字段保守按值语义处理。
    field_ref_bits: u64 = 0,

    /// 释放字段值
    /// fields 是连续内存的一部分，由 recordDeinit 中的 freeObj 统一释放
    /// field_names 指向源码 arena 或 string_pool，无需释放
    pub fn deinit(self: *RecordValue, tctx: *ThreadContext) void {
        if (!obj_header.shutdown_mode) {
            for (self.fields) |*f| f.release(tctx);
        }
    }

    /// 判断指定字段是否为引用类型（&T / *T）
    pub inline fn fieldIsRef(self: *const RecordValue, field_id: u16) bool {
        if (field_id >= 64) return false;
        return (self.field_ref_bits & (@as(u64, 1) << @intCast(field_id))) != 0;
    }

    /// 按 field_id 读取字段值（运行时热路径）
    pub inline fn get(self: *const RecordValue, field_id: u16) ?Value {
        if (field_id >= self.fields.len) return null;
        return self.fields[field_id];
    }

    /// 按 field_id 写入字段值（运行时热路径）
    /// 替换语义：release 旧值，retain 新值由调用方负责
    pub inline fn set(self: *RecordValue, field_id: u16, v: Value, tctx: *ThreadContext) bool {
        if (field_id >= self.fields.len) return false;
        const slot = &self.fields[field_id];
        slot.release(tctx);
        slot.* = v;
        return true;
    }
};

/// 可变单元格，提供对内部值的可变引用语义
pub const Cell = struct {
    header: ObjHeader = .{ .type_tag = .cell },
    inner: Value,

    /// 释放内部值
    pub fn deinit(self: *Cell, tctx: *ThreadContext) void {
        if (!obj_header.shutdown_mode) {
            self.inner.release(tctx);
        }
    }
};

/// 整数区间，支持半开和闭区间
pub const Range = struct {
    header: ObjHeader = .{ .type_tag = .range },
    start: [16]u8,
    end: [16]u8,
    inclusive: bool,
    start_i64: ?i64 = null,
    end_i64: ?i64 = null,

    /// 空实现：整数值为内联类型，区间本身无需释放
    pub fn deinit(self: *Range, tctx: *ThreadContext) void {
        _ = self;
        _ = tctx;
    }
};

// ── deinit_table 注册函数 ──
// 所有 deinit 包装函数：执行 Type.deinit（释放内部 RC 子对象/独立缓冲区），
// 若对象非 arena 分配则 freeObj 释放对象本体；arena 分配的对象由 arena.reset 统一回收。

pub fn adtDeinit(obj: *ObjHeader, tctx: *ThreadContext) void {
    const self: *AdtValue = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(tctx);
    if (!obj.isArenaAllocated()) tctx.freeObj(@ptrCast(self));
}

pub fn newtypeDeinit(obj: *ObjHeader, tctx: *ThreadContext) void {
    const self: *NewtypeValue = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(tctx);
    if (!obj.isArenaAllocated()) tctx.freeObj(@ptrCast(self));
}

pub fn arrayDeinit(obj: *ObjHeader, tctx: *ThreadContext) void {
    const self: *ArrayValue = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(tctx);
    if (!obj.isArenaAllocated()) tctx.freeObj(@ptrCast(self));
}

pub fn recordDeinit(obj: *ObjHeader, tctx: *ThreadContext) void {
    const self: *RecordValue = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(tctx);
    if (!obj.isArenaAllocated()) tctx.freeObj(@ptrCast(self));
}

pub fn cellDeinit(obj: *ObjHeader, tctx: *ThreadContext) void {
    const self: *Cell = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(tctx);
    if (!obj.isArenaAllocated()) tctx.freeObj(@ptrCast(self));
}

pub fn rangeDeinit(obj: *ObjHeader, tctx: *ThreadContext) void {
    const self: *Range = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(tctx);
    if (!obj.isArenaAllocated()) tctx.freeObj(@ptrCast(self));
}

/// 注册所有复合类型的 deinit 函数
pub fn registerDeinits() void {
    obj_header.registerDeinit(.adt, adtDeinit);
    obj_header.registerDeinit(.newtype, newtypeDeinit);
    obj_header.registerDeinit(.array, arrayDeinit);
    obj_header.registerDeinit(.record, recordDeinit);
    obj_header.registerDeinit(.cell, cellDeinit);
    obj_header.registerDeinit(.range, rangeDeinit);
}
