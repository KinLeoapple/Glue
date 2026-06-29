//! 迭代器类型装箱 struct——ArrayIterator/StringIterator/RangeIterator
//!
//! 每个 struct 首字段 rc:u32，Value union 持 *T 指针。
//! 迭代器不拥有底层数据（array/string 由外部持有），deinit noop。
//! RangeIterator.current/end 用 Int 软件实现，规避 i128 codegen bug。
//!
//! 命名规范：方法名全部使用完整单词，不使用缩写。

const std = @import("std");
const value = @import("mod.zig");
const Value = value.Value;
const int = @import("int.zig");
const Int = int.Int;

/// 数组迭代器（不拥有 array，外部持有所有权）
pub const ArrayIterator = struct {
    rc: u32 = 1,
    array: []Value,
    index: usize,

    pub fn deinit(self: *ArrayIterator, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
        // 不拥有 array
    }
};

/// 字符串迭代器（不拥有 string，外部持有所有权）
pub const StringIterator = struct {
    rc: u32 = 1,
    string: []const u8,
    byte_offset: usize,

    pub fn deinit(self: *StringIterator, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
        // 不拥有 string
    }
};

/// 范围迭代器（current/end 用 Int 软件实现）
pub const RangeIterator = struct {
    rc: u32 = 1,
    current: Int,
    end: Int,
    inclusive: bool,

    pub fn deinit(self: *RangeIterator, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
        // Int 是内联 [N]u8，无堆数据
    }
};
