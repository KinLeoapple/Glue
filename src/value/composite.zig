//! 复合值类型模块
//!
//! 定义 Glue 语言中的复合数据结构：
//! - ArrayValue 数组
//! - RecordValue 记录（具名字段集合）
//! - AdtValue 代数数据类型（带构造器）
//! - NewtypeValue 新类型包装
//! - Cell 可变单元格
//! - Range 整数区间

const std = @import("std");
const value = @import("mod.zig");
const Value = value.Value;
const int = @import("int.zig");
const Int = int.Int;

/// ADT 字段，可带名称
pub const AdtField = struct {
name: ?[]const u8,
value: Value,
};

/// 代数数据类型值，由类型名、构造器和字段列表组成
pub const AdtValue = struct {
rc: u32 = 1,
type_name: []const u8,
constructor: []const u8,
fields: []AdtField,

/// 释放所有字段值并回收字段数组内存
pub fn deinit(self: *AdtValue, allocator: std.mem.Allocator) void {
for (self.fields) |*f| f.value.release(allocator);
if (self.fields.len > 0) allocator.free(self.fields);
}
};

/// 新类型值，包装一个内部值并附加类型名
pub const NewtypeValue = struct {
rc: u32 = 1,
type_name: []const u8,
inner: Value,

/// 释放内部值
pub fn deinit(self: *NewtypeValue, allocator: std.mem.Allocator) void {
self.inner.release(allocator);
}
};

/// 数组值，支持定长和变长
pub const ArrayValue = struct {
rc: u32 = 1,
elements: []Value,
capacity: usize = 0,
fixed_size: ?u64 = null,

/// 释放所有元素并回收元素数组内存
pub fn deinit(self: *ArrayValue, allocator: std.mem.Allocator) void {
for (self.elements) |*e| e.release(allocator);
if (self.capacity > 0) {
allocator.free(self.elements.ptr[0..self.capacity]);
} else if (self.elements.len > 0) {
allocator.free(self.elements);
}
}
};

/// 记录值，类型名加具名字段映射
pub const RecordValue = struct {
rc: u32 = 1,
type_name: []const u8,
fields: std.StringHashMap(Value),

/// 释放所有字段的键和值，并清理哈希表
pub fn deinit(self: *RecordValue, allocator: std.mem.Allocator) void {
var it = self.fields.iterator();
while (it.next()) |entry| {
allocator.free(entry.key_ptr.*);
entry.value_ptr.release(allocator);
}
self.fields.deinit();
}
};

/// 可变单元格，提供对内部值的可变引用语义
pub const Cell = struct {
rc: u32 = 1,
inner: Value,

/// 释放内部值
pub fn deinit(self: *Cell, allocator: std.mem.Allocator) void {
self.inner.release(allocator);
}
};

/// 整数区间，支持半开和闭区间
pub const Range = struct {
rc: u32 = 1,
start: Int,
end: Int,
inclusive: bool,
start_i64: ?i64 = null,
end_i64: ?i64 = null,

/// 空实现：整数值为内联类型，区间本身无需释放
pub fn deinit(self: *Range, allocator: std.mem.Allocator) void {
_ = self;
_ = allocator;
}
};
