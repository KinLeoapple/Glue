//! 迭代器值类型模块
//!
//! 定义 Glue 语言中用于遍历集合的迭代器类型：
//! - ArrayIterator 逐元素遍历数组
//! - StringIterator 按 Unicode 码点遍历字符串
//! - RangeIterator 遍历整数区间

const std = @import("std");
const obj_header = @import("obj_header.zig");
const ObjHeader = obj_header.ObjHeader;
const ThreadContext = obj_header.ThreadContext;
const value = @import("mod.zig");
const Value = value.Value;

/// 数组迭代器，持有序列视图和当前索引
pub const ArrayIterator = struct {
    header: ObjHeader = .{ .type_tag = .array_iter },
    array: []Value,
    index: usize,

    /// 空实现：数组引用由外部管理，迭代器本身无需释放
    pub fn deinit(self: *ArrayIterator, tctx: *ThreadContext) void {
        _ = self;
        _ = tctx;
    }
};

/// 字符串迭代器，按字节偏移遍历 UTF-8 编码的字符串
pub const StringIterator = struct {
    header: ObjHeader = .{ .type_tag = .string_iter },
    string: []const u8,
    byte_offset: usize,

    /// 空实现：字符串引用由外部管理，迭代器本身无需释放
    pub fn deinit(self: *StringIterator, tctx: *ThreadContext) void {
        _ = self;
        _ = tctx;
    }
};

/// 区间迭代器，从 current 遍历到 end
pub const RangeIterator = struct {
    header: ObjHeader = .{ .type_tag = .range_iter },
    current: [16]u8,
    end: [16]u8,
    inclusive: bool,

    /// 空实现：整数值为内联类型，迭代器本身无需释放
    pub fn deinit(self: *RangeIterator, tctx: *ThreadContext) void {
        _ = self;
        _ = tctx;
    }
};

// ── deinit_table 注册函数 ──

pub fn arrayIterDeinit(obj: *ObjHeader, tctx: *ThreadContext) void {
    const self: *ArrayIterator = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(tctx);
    tctx.freeObj(@ptrCast(self));
}

pub fn stringIterDeinit(obj: *ObjHeader, tctx: *ThreadContext) void {
    const self: *StringIterator = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(tctx);
    tctx.freeObj(@ptrCast(self));
}

pub fn rangeIterDeinit(obj: *ObjHeader, tctx: *ThreadContext) void {
    const self: *RangeIterator = @alignCast(@fieldParentPtr("header", obj));
    self.deinit(tctx);
    tctx.freeObj(@ptrCast(self));
}

/// 注册所有迭代器类型的 deinit 函数
pub fn registerDeinits() void {
    obj_header.registerDeinit(.array_iter, arrayIterDeinit);
    obj_header.registerDeinit(.string_iter, stringIterDeinit);
    obj_header.registerDeinit(.range_iter, rangeIterDeinit);
}
