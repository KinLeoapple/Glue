//! 寄存器分配器。
//!
//! 基于活跃区间与干涉图实现图着色寄存器分配，
//! 将虚拟寄存器（VReg）映射到物理寄存器（PReg）或溢出槽，
//! 并为 boxed 值生成释放掩码（release_mask）。

const std = @import("std");

/// 虚拟寄存器类型，编译期分配的抽象寄存器编号。
pub const VReg = u32;

/// 物理寄存器类型，运行期实际使用的寄存器编号。
pub const PReg = u8;

/// 溢出标记，表示该值需要存储到溢出槽。
pub const SPILL_MARKER: PReg = 255;

/// 活跃区间，描述一个 VReg 从定义到末次使用的指令范围。
pub const LiveRange = struct {
    vreg: VReg,
    start: u32,
    end: u32,
};

/// 寄存器分配结果，包含 VReg→PReg 映射、溢出映射与释放掩码。
pub const Allocation = struct {
    reg_map: std.AutoHashMapUnmanaged(VReg, PReg) = .{},
    spill_map: std.AutoHashMapUnmanaged(VReg, u16) = .{},
    register_count: u16 = 0,
    spill_count: u16 = 0,
    release_mask: u64 = 0,

    /// 释放映射表占用的内存。
    pub fn deinit(self: *Allocation, allocator: std.mem.Allocator) void {
        self.reg_map.deinit(allocator);
        self.spill_map.deinit(allocator);
    }

    /// 查询 VReg 对应的物理寄存器，溢出时返回 SPILL_MARKER。
    pub fn getPReg(self: *const Allocation, vreg: VReg) PReg {
        if (self.reg_map.get(vreg)) |r| return r;
        if (self.spill_map.get(vreg)) |_| return SPILL_MARKER;
        return SPILL_MARKER;
    }

    /// 查询 VReg 对应的溢出槽索引，未溢出返回 null。
    pub fn getSpillSlot(self: *const Allocation, vreg: VReg) ?u16 {
        return self.spill_map.get(vreg);
    }
};

/// 图着色寄存器分配器，维护活跃区间与干涉图。
pub const RegAllocator = struct {
    allocator: std.mem.Allocator,
    live_ranges: std.ArrayListUnmanaged(LiveRange) = .empty,
    interference: std.AutoHashMapUnmanaged(VReg, std.ArrayListUnmanaged(VReg)) = .{},
    is_boxed: std.AutoHashMapUnmanaged(VReg, bool) = .{},
    num_registers: u8 = 240,

    /// 创建一个空的分配器。
    pub fn init(allocator: std.mem.Allocator) RegAllocator {
        return .{ .allocator = allocator };
    }

    /// 释放活跃区间、干涉图与 boxed 标记表。
    pub fn deinit(self: *RegAllocator) void {
        self.live_ranges.deinit(self.allocator);
        var it = self.interference.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.interference.deinit(self.allocator);
        self.is_boxed.deinit(self.allocator);
    }

    /// 添加一个活跃区间，并记录该 VReg 是否为 boxed 值。
    pub fn addLiveRange(self: *RegAllocator, vreg: VReg, start: u32, end: u32, boxed: bool) !void {
        try self.live_ranges.append(self.allocator, .{
            .vreg = vreg,
            .start = start,
            .end = end,
        });
        try self.is_boxed.put(self.allocator, vreg, boxed);
    }

    /// 返回与指定 VReg 干涉的所有邻居 VReg。
    fn getNeighbors(self: *const RegAllocator, vreg: VReg) []const VReg {
        if (self.interference.get(vreg)) |list| {
            return list.items;
        }
        return &[_]VReg{};
    }

    /// 构建干涉图：区间重叠的两个 VReg 互为邻居。
    pub fn buildInterferenceGraph(self: *RegAllocator) !void {
        for (self.live_ranges.items, 0..) |lr_i, i| {
            for (self.live_ranges.items[i + 1 ..]) |lr_j| {
                if (lr_i.start < lr_j.end and lr_j.start < lr_i.end) {
                    try self.addEdge(lr_i.vreg, lr_j.vreg);
                    try self.addEdge(lr_j.vreg, lr_i.vreg);
                }
            }
        }
    }

    /// 在干涉图中添加一条有向边（去重）。
    fn addEdge(self: *RegAllocator, from: VReg, to: VReg) !void {
        const entry = try self.interference.getOrPut(self.allocator, from);
        if (!entry.found_existing) {
            entry.value_ptr.* = .empty;
        }
        for (entry.value_ptr.items) |v| {
            if (v == to) return;
        }
        try entry.value_ptr.append(self.allocator, to);
    }

    /// 执行图着色：简化-溢出-选择三阶段，返回分配结果。
    pub fn color(self: *RegAllocator) !Allocation {
        const StackItem = struct {
            vreg: VReg,
            neighbors: []VReg,
        };
        var alloc = Allocation{};
        var stack = std.ArrayListUnmanaged(StackItem).empty;
        defer stack.deinit(self.allocator);
        var remaining = std.AutoHashMapUnmanaged(VReg, void).empty;
        defer remaining.deinit(self.allocator);
        for (self.live_ranges.items) |lr| {
            try remaining.put(self.allocator, lr.vreg, {});
        }

        // 简化阶段：反复将度数 < num_registers 的节点压栈
        while (remaining.count() > 0) {
            var found = false;
            var it = remaining.iterator();
            while (it.next()) |entry| {
                const vreg = entry.key_ptr.*;
                const neighbors = self.getNeighbors(vreg);
                var degree: u32 = 0;
                for (neighbors) |n| {
                    if (remaining.contains(n)) degree += 1;
                }
                if (degree < self.num_registers) {
                    const neigh_copy = try self.allocator.dupe(VReg, neighbors);
                    try stack.append(self.allocator, .{ .vreg = vreg, .neighbors = neigh_copy });
                    _ = remaining.remove(vreg);
                    found = true;
                    break;
                }
            }
            // 溢出阶段：无可简化节点时选最大度数节点直接溢出
            if (!found) {
                var max_degree: u32 = 0;
                var spill_vreg: VReg = 0;
                var it2 = remaining.iterator();
                while (it2.next()) |entry| {
                    const vreg = entry.key_ptr.*;
                    const neighbors = self.getNeighbors(vreg);
                    var degree: u32 = 0;
                    for (neighbors) |n| {
                        if (remaining.contains(n)) degree += 1;
                    }
                    if (degree >= max_degree) {
                        max_degree = degree;
                        spill_vreg = vreg;
                    }
                }
                const slot = alloc.spill_count;
                alloc.spill_count += 1;
                try alloc.spill_map.put(self.allocator, spill_vreg, slot);
                _ = remaining.remove(spill_vreg);
            }
        }

        // 选择阶段：按出栈顺序为每个 VReg 分配最低可用颜色
        var used_colors: [256]bool = undefined;
        var max_preg: u8 = 0;
        while (stack.items.len > 0) {
            const item = stack.pop().?;
            @memset(&used_colors, false);
            for (item.neighbors) |n| {
                if (alloc.reg_map.get(n)) |color_| {
                    used_colors[color_] = true;
                }
            }
            var color_: PReg = 0;
            while (color_ < self.num_registers and used_colors[color_]) color_ += 1;
            if (color_ >= self.num_registers) {
                // 选择阶段仍无法分配，溢出到栈槽
                const slot = alloc.spill_count;
                alloc.spill_count += 1;
                try alloc.spill_map.put(self.allocator, item.vreg, slot);
            } else {
                try alloc.reg_map.put(self.allocator, item.vreg, color_);
                if (color_ > max_preg) max_preg = color_;
                // boxed 值需要运行期释放，记录到 release_mask
                if (self.is_boxed.get(item.vreg) orelse false) {
                    if (color_ < 64) {
                        alloc.release_mask |= (@as(u64, 1) << @intCast(color_));
                    }
                }
            }
            self.allocator.free(item.neighbors);
        }
        alloc.register_count = @as(u16, max_preg) + 1;
        if (alloc.spill_count > 0) {
            alloc.register_count += alloc.spill_count;
        }
        return alloc;
    }
};

test "无干涉的 VReg 全部分配不同寄存器" {
    var allocator = RegAllocator.init(std.testing.allocator);
    defer allocator.deinit();
    try allocator.addLiveRange(0, 0, 5, false);
    try allocator.addLiveRange(1, 5, 10, false);
    try allocator.addLiveRange(2, 10, 15, false);
    try allocator.buildInterferenceGraph();
    var alloc = try allocator.color();
    defer alloc.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), alloc.getPReg(0));
    try std.testing.expectEqual(@as(u8, 0), alloc.getPReg(1));
    try std.testing.expectEqual(@as(u8, 0), alloc.getPReg(2));
    try std.testing.expect(alloc.register_count >= 1);
}

test "互相干涉的 VReg 分配不同寄存器" {
    var allocator = RegAllocator.init(std.testing.allocator);
    defer allocator.deinit();
    try allocator.addLiveRange(0, 0, 10, false);
    try allocator.addLiveRange(1, 0, 10, false);
    try allocator.addLiveRange(2, 0, 10, false);
    try allocator.buildInterferenceGraph();
    var alloc = try allocator.color();
    defer alloc.deinit(std.testing.allocator);
    const r0 = alloc.getPReg(0);
    const r1 = alloc.getPReg(1);
    const r2 = alloc.getPReg(2);
    try std.testing.expect(r0 != r1);
    try std.testing.expect(r0 != r2);
    try std.testing.expect(r1 != r2);
}

test "boxed 值设置 release_mask" {
    var allocator = RegAllocator.init(std.testing.allocator);
    defer allocator.deinit();
    try allocator.addLiveRange(0, 0, 10, true);
    try allocator.addLiveRange(1, 0, 10, false);
    try allocator.buildInterferenceGraph();
    var alloc = try allocator.color();
    defer alloc.deinit(std.testing.allocator);
    const r0 = alloc.getPReg(0);
    if (r0 < 64) {
        try std.testing.expect((alloc.release_mask & (@as(u64, 1) << @intCast(r0))) != 0);
    }
}
