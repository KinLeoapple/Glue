//! 重定位表：记录字节码中所有 func/ctor/global idx 引用的位置。
//!
//! 编译时全局合并 func_idx，每模块缓存时需记录本模块字节码中
//! 所有 idx 引用的 (字节码偏移, 引用种类, 模块内局部 idx)。
//! 加载时按累积偏移 patch：绝对 idx = 局部 idx + 模块偏移。

const std = @import("std");

/// 重定位种类
pub const RelocKind = enum(u8) {
    /// op_call <u16 func_idx>
    func,
    /// op_make_adt <u8 ctor_idx>
    ctor,
    /// op_get_global / op_set_global <u16 global_idx>
    global,
    /// op_tail_call <u16 func_idx>
    tail_func,
    /// op_call_memoized <u16 func_idx> <u8 argc> <u16 memo_slot>
    memo_func,
    /// op_make_record <u16 shape_idx>
    record_shape,
};

/// 单条重定位记录
pub const RelocEntry = struct {
    /// 本记录所属函数在 program.functions 中的索引（每函数有独立 chunk，
    /// code_offset 仅在该 chunk 内有效）
    func_idx: u16,
    /// 字节码中的偏移（op 之后 u16/u8 立即数的位置）
    code_offset: u32,
    /// 重定位种类
    kind: RelocKind,
    /// 模块内局部 idx（编译时分配的）
    local_idx: u32,
};

/// 字节读写光标：避免依赖 std.io.Reader/Writer 接口变化
pub const ByteCursor = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn read(self: *ByteCursor, buf: []u8) !void {
        if (self.pos + buf.len > self.data.len) return error.EndOfStream;
        @memcpy(buf, self.data[self.pos .. self.pos + buf.len]);
        self.pos += buf.len;
    }
};

/// 重定位表
pub const RelocTable = struct {
    entries: std.ArrayListUnmanaged(RelocEntry) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RelocTable {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RelocTable) void {
        self.entries.deinit(self.allocator);
    }

    pub fn add(self: *RelocTable, func_idx: u16, code_offset: u32, kind: RelocKind, local_idx: u32) !void {
        try self.entries.append(self.allocator, .{
            .func_idx = func_idx,
            .code_offset = code_offset,
            .kind = kind,
            .local_idx = local_idx,
        });
    }

    /// 序列化到 buffer（u32 count + entries）
    pub fn writeBytes(self: *const RelocTable, buf: *std.ArrayList(u8)) !void {
        const count: u32 = @intCast(self.entries.items.len);
        try buf.appendSlice(self.allocator, std.mem.asBytes(&count));
        for (self.entries.items) |e| {
            try buf.appendSlice(self.allocator, std.mem.asBytes(&e.func_idx));
            try buf.appendSlice(self.allocator, std.mem.asBytes(&e.code_offset));
            try buf.appendSlice(self.allocator, std.mem.asBytes(&e.kind));
            try buf.appendSlice(self.allocator, std.mem.asBytes(&e.local_idx));
        }
    }

    /// 从光标反序列化
    pub fn readBytes(allocator: std.mem.Allocator, cur: *ByteCursor) !RelocTable {
        var table = RelocTable.init(allocator);
        var count: u32 = undefined;
        try cur.read(std.mem.asBytes(&count));
        try table.entries.ensureTotalCapacity(allocator, count);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            var entry: RelocEntry = undefined;
            try cur.read(std.mem.asBytes(&entry.func_idx));
            try cur.read(std.mem.asBytes(&entry.code_offset));
            try cur.read(std.mem.asBytes(&entry.kind));
            try cur.read(std.mem.asBytes(&entry.local_idx));
            try table.entries.append(allocator, entry);
        }
        return table;
    }
};

test "RelocTable 序列化往返" {
    var table = RelocTable.init(std.testing.allocator);
    defer table.deinit();
    try table.add(0, 10, .func, 0);
    try table.add(0, 20, .ctor, 1);
    try table.add(1, 30, .global, 2);

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try table.writeBytes(&buf);

    var cur = ByteCursor{ .data = buf.items };
    var table2 = try RelocTable.readBytes(std.testing.allocator, &cur);
    defer table2.deinit();
    try std.testing.expectEqual(@as(usize, 3), table2.entries.items.len);
    try std.testing.expectEqual(@as(u16, 0), table2.entries.items[0].func_idx);
    try std.testing.expectEqual(@as(u32, 10), table2.entries.items[0].code_offset);
    try std.testing.expectEqual(RelocKind.func, table2.entries.items[0].kind);
    try std.testing.expectEqual(@as(u32, 0), table2.entries.items[0].local_idx);
    try std.testing.expectEqual(@as(u16, 1), table2.entries.items[2].func_idx);
    try std.testing.expectEqual(RelocKind.ctor, table2.entries.items[1].kind);
    try std.testing.expectEqual(RelocKind.global, table2.entries.items[2].kind);
}

test "RelocTable 空" {
    var table = RelocTable.init(std.testing.allocator);
    defer table.deinit();
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try table.writeBytes(&buf);
    var cur = ByteCursor{ .data = buf.items };
    var table2 = try RelocTable.readBytes(std.testing.allocator, &cur);
    defer table2.deinit();
    try std.testing.expectEqual(@as(usize, 0), table2.entries.items.len);
}
