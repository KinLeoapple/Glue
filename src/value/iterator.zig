//! 迭代器值类型模块
//!
//! 定义 Glue 语言中用于遍历集合的迭代器类型：
//! - ArrayIterator 逐元素遍历数组
//! - StringIterator 按 Unicode 码点遍历字符串
//! - RangeIterator 遍历整数区间

const std = @import("std");
const value = @import("mod.zig");
const Value = value.Value;
const int = @import("int.zig");
const Int = int.Int;

/// 数组迭代器，持有序列视图和当前索引
pub const ArrayIterator = struct {
rc: u32 = 1,
array: []Value,
index: usize,

/// 空实现：数组引用由外部管理，迭代器本身无需释放
pub fn deinit(self: *ArrayIterator, allocator: std.mem.Allocator) void {
_ = self;
_ = allocator;
}
};

/// 字符串迭代器，按字节偏移遍历 UTF-8 编码的字符串
pub const StringIterator = struct {
rc: u32 = 1,
string: []const u8,
byte_offset: usize,

/// 空实现：字符串引用由外部管理，迭代器本身无需释放
pub fn deinit(self: *StringIterator, allocator: std.mem.Allocator) void {
_ = self;
_ = allocator;
}
};

/// 区间迭代器，从 current 遍历到 end
pub const RangeIterator = struct {
rc: u32 = 1,
current: Int,
end: Int,
inclusive: bool,

/// 空实现：整数值为内联类型，迭代器本身无需释放
pub fn deinit(self: *RangeIterator, allocator: std.mem.Allocator) void {
_ = self;
_ = allocator;
}
};
