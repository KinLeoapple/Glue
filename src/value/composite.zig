//! 复合类型装箱 struct——ArrayValue/RecordValue/AdtValue/AdtField/NewtypeValue/Cell/Range
//!
//! 每个 struct 首字段 rc:u32，Value union 持 *T 指针。
//! deinit 递归 release 子 Value + free 切片 + deinit map。
//! type_name/constructor 假设为字面量（外部管理），deinit 不释放。
//!
//! 命名规范：方法名全部使用完整单词，不使用缩写。

const std = @import("std");
const value = @import("mod.zig");
const Value = value.Value;
const int = @import("int.zig");
const Int = int.Int;

/// ADT 字段（内联在 AdtValue.fields 切片里，无独立 rc）
pub const AdtField = struct {
    name: ?[]const u8,
    value: Value,
};

/// ADT 值：type_name::constructor(fields)
pub const AdtValue = struct {
    rc: u32 = 1,
    type_name: []const u8,
    constructor: []const u8,
    fields: []AdtField,

    pub fn deinit(self: *AdtValue, allocator: std.mem.Allocator) void {
        for (self.fields) |*f| f.value.release(allocator);
        if (self.fields.len > 0) allocator.free(self.fields);
    }
};

/// Newtype 值：Name(inner)
pub const NewtypeValue = struct {
    rc: u32 = 1,
    type_name: []const u8,
    inner: Value,

    pub fn deinit(self: *NewtypeValue, allocator: std.mem.Allocator) void {
        self.inner.release(allocator);
    }
};

/// 数组值（capacity 用于 amortized O(1) push 扩容）
pub const ArrayValue = struct {
    rc: u32 = 1,
    elements: []Value,
    capacity: usize = 0,
    fixed_size: ?u64 = null,

    pub fn deinit(self: *ArrayValue, allocator: std.mem.Allocator) void {
        for (self.elements) |*e| e.release(allocator);
        // 【Pre-existing 修复】用 capacity 而非 elements.len 释放底层内存。
        // op_push_inplace 扩容后 elements 是 [0..old_len+1] 切片，len < capacity。
        // 若用 len 释放，size 与分配时不匹配，污染 slab free_list。
        if (self.capacity > 0) {
            allocator.free(self.elements.ptr[0..self.capacity]);
        } else if (self.elements.len > 0) {
            allocator.free(self.elements);
        }
    }
};

/// 记录值：T{ k: v, ... }
pub const RecordValue = struct {
    rc: u32 = 1,
    type_name: []const u8,
    fields: std.StringHashMap(Value),

    pub fn deinit(self: *RecordValue, allocator: std.mem.Allocator) void {
        var it = self.fields.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.release(allocator);
        }
        self.fields.deinit();
    }
};

/// Cell：可变引用容器
pub const Cell = struct {
    rc: u32 = 1,
    inner: Value,

    pub fn deinit(self: *Cell, allocator: std.mem.Allocator) void {
        self.inner.release(allocator);
    }
};

/// 范围：start..end 或 start..=end（start/end 用 Int 软件实现，规避 i128 codegen bug）
pub const Range = struct {
    rc: u32 = 1,
    start: Int,
    end: Int,
    inclusive: bool,
    /// 【P1-5 循环不变量提离】预计算的 i64 缓存，在 makeRange 时一次性 coerceTo(.i64)。
    /// doForNext 每次迭代直接读取，省去 coerceTo + toNative 调用。
    /// null 表示该值超出 i64 范围（迭代时报错）。
    start_i64: ?i64 = null,
    end_i64: ?i64 = null,

    pub fn deinit(self: *Range, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
        // Int 是内联 [N]u8，无堆数据
    }
};
