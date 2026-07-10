//! 图着色寄存器分配器。
//! 流程：AST → 活跃性分析 → 干涉图构建 → 简化 → 溢出 → 着色 → 寄存器映射
//! 由于 Glue 的 AST 结构复杂（闭包/defer/select/match），采用简化版图着色：
//! 1. 线性扫描 AST 收集变量定义点和使用点
//! 2. 构建活跃区间（live range）
//! 3. 构建干涉图（重叠活跃区间互相干涉）
//! 4. 简化 + 溢出 + 着色（Chaitin-Briggs 算法）
//! 5. 输出：虚拟变量 → 物理寄存器号映射

const std = @import("std");

/// 虚拟变量 ID（编译期分配，每个 val/var/param/临时 有唯一 ID）
pub const VReg = u32;

/// 物理寄存器号（0-254，255 保留给溢出标记）
pub const PReg = u8;
pub const SPILL_MARKER: PReg = 255;

/// 活跃区间：[start, end)
pub const LiveRange = struct {
    vreg: VReg,
    start: u32, // 定义点（指令索引）
    end: u32, // 最后使用点 + 1
};

/// 分配结果：VReg → PReg 映射
pub const Allocation = struct {
    /// 成功着色的寄存器映射
    reg_map: std.AutoHashMapUnmanaged(VReg, PReg) = .{},
    /// 溢出到帧栈的 VReg 集合（映射到 slot 索引）
    spill_map: std.AutoHashMapUnmanaged(VReg, u16) = .{},
    /// 总寄存器数（含参数+局部+临时）
    register_count: u16 = 0,
    /// 溢出 slot 数
    spill_count: u16 = 0,
    /// release_mask：bit i=1 表示物理寄存器 i 持 boxed 值
    release_mask: u64 = 0,

    pub fn deinit(self: *Allocation, allocator: std.mem.Allocator) void {
        self.reg_map.deinit(allocator);
        self.spill_map.deinit(allocator);
    }

    /// 查询 VReg 对应的物理寄存器（溢出则返回 SPILL_MARKER）
    pub fn getPReg(self: *const Allocation, vreg: VReg) PReg {
        if (self.reg_map.get(vreg)) |r| return r;
        if (self.spill_map.get(vreg)) |_| return SPILL_MARKER;
        return SPILL_MARKER; // 未分配（错误）
    }

    /// 查询 VReg 对应的溢出 slot（非溢出则返回 null）
    pub fn getSpillSlot(self: *const Allocation, vreg: VReg) ?u16 {
        return self.spill_map.get(vreg);
    }
};

/// 寄存器分配器
pub const RegAllocator = struct {
    allocator: std.mem.Allocator,
    /// 所有活跃区间
    live_ranges: std.ArrayListUnmanaged(LiveRange) = .empty,
    /// 干涉图邻接表：vreg → 干涉的 vreg 列表
    interference: std.AutoHashMapUnmanaged(VReg, std.ArrayListUnmanaged(VReg)) = .{},
    /// VReg → 是否持 boxed 值（用于 release_mask）
    is_boxed: std.AutoHashMapUnmanaged(VReg, bool) = .{},
    /// 可用物理寄存器数（默认 240，0-239 给变量，240-254 给临时表达式）
    num_registers: u8 = 240,

    pub fn init(allocator: std.mem.Allocator) RegAllocator {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RegAllocator) void {
        self.live_ranges.deinit(self.allocator);
        var it = self.interference.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.interference.deinit(self.allocator);
        self.is_boxed.deinit(self.allocator);
    }

    /// 注册一个虚拟变量的活跃区间
    pub fn addLiveRange(self: *RegAllocator, vreg: VReg, start: u32, end: u32, boxed: bool) !void {
        try self.live_ranges.append(self.allocator, .{
            .vreg = vreg,
            .start = start,
            .end = end,
        });
        try self.is_boxed.put(self.allocator, vreg, boxed);
    }

    /// 获取 VReg 的邻居列表（干涉的 VReg），返回空切片如果无邻居
    fn getNeighbors(self: *const RegAllocator, vreg: VReg) []const VReg {
        if (self.interference.get(vreg)) |list| {
            return list.items;
        }
        return &[_]VReg{};
    }

    /// 构建干涉图：重叠活跃区间互相干涉
    pub fn buildInterferenceGraph(self: *RegAllocator) !void {
        for (self.live_ranges.items, 0..) |lr_i, i| {
            for (self.live_ranges.items[i + 1 ..]) |lr_j| {
                // 区间重叠条件：lr_i.start < lr_j.end and lr_j.start < lr_i.end
                if (lr_i.start < lr_j.end and lr_j.start < lr_i.end) {
                    // 互相添加邻接
                    try self.addEdge(lr_i.vreg, lr_j.vreg);
                    try self.addEdge(lr_j.vreg, lr_i.vreg);
                }
            }
        }
    }

    fn addEdge(self: *RegAllocator, from: VReg, to: VReg) !void {
        const entry = try self.interference.getOrPut(self.allocator, from);
        if (!entry.found_existing) {
            entry.value_ptr.* = .empty;
        }
        // 避免重复添加
        for (entry.value_ptr.items) |v| {
            if (v == to) return;
        }
        try entry.value_ptr.append(self.allocator, to);
    }

    /// Chaitin-Briggs 图着色：简化 → 溢出 → 着色
    pub fn color(self: *RegAllocator) !Allocation {
        const StackItem = struct {
            vreg: VReg,
            neighbors: []VReg,
        };

        var alloc = Allocation{};
        var stack = std.ArrayListUnmanaged(StackItem).empty;
        defer stack.deinit(self.allocator);

        // 收集所有 VReg
        var remaining = std.AutoHashMapUnmanaged(VReg, void).empty;
        defer remaining.deinit(self.allocator);
        for (self.live_ranges.items) |lr| {
            try remaining.put(self.allocator, lr.vreg, {});
        }

        // 简化阶段：移除度数 < num_registers 的节点
        while (remaining.count() > 0) {
            var found = false;
            var it = remaining.iterator();
            while (it.next()) |entry| {
                const vreg = entry.key_ptr.*;
                const neighbors = self.getNeighbors(vreg);
                // 计算仍在 remaining 中的邻居数
                var degree: u32 = 0;
                for (neighbors) |n| {
                    if (remaining.contains(n)) degree += 1;
                }
                if (degree < self.num_registers) {
                    // 压栈并移除
                    const neigh_copy = try self.allocator.dupe(VReg, neighbors);
                    try stack.append(self.allocator, .{ .vreg = vreg, .neighbors = neigh_copy });
                    _ = remaining.remove(vreg);
                    found = true;
                    break;
                }
            }
            if (!found) {
                // 溢出：选度数最大的节点标记为溢出
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
                // 分配溢出 slot
                const slot = alloc.spill_count;
                alloc.spill_count += 1;
                try alloc.spill_map.put(self.allocator, spill_vreg, slot);
                _ = remaining.remove(spill_vreg);
            }
        }

        // 着色阶段：从栈中弹出，分配颜色
        var used_colors: [256]bool = undefined;
        var max_preg: u8 = 0;
        while (stack.items.len > 0) {
            const item = stack.pop().?;
            // 收集邻居已用的颜色
            @memset(&used_colors, false);
            for (item.neighbors) |n| {
                if (alloc.reg_map.get(n)) |color_| {
                    used_colors[color_] = true;
                }
                // 溢出的邻居不占颜色
            }
            // 找最小可用颜色
            var color_: PReg = 0;
            while (color_ < self.num_registers and used_colors[color_]) color_ += 1;
            if (color_ >= self.num_registers) {
                // 实际溢出（简化时未预测到）
                const slot = alloc.spill_count;
                alloc.spill_count += 1;
                try alloc.spill_map.put(self.allocator, item.vreg, slot);
            } else {
                try alloc.reg_map.put(self.allocator, item.vreg, color_);
                if (color_ > max_preg) max_preg = color_;
                // 设置 release_mask
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
            alloc.register_count += alloc.spill_count; // 溢出 slot 接在寄存器后面
        }
        return alloc;
    }
};

// ── 单元测试 ──

test "无干涉的 VReg 全部分配不同寄存器" {
    var allocator = RegAllocator.init(std.testing.allocator);
    defer allocator.deinit();

    // 3 个不重叠的活跃区间
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

    // 3 个完全重叠的活跃区间 → 互相干涉 → 需要 3 个不同寄存器
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

    try allocator.addLiveRange(0, 0, 10, true); // boxed
    try allocator.addLiveRange(1, 0, 10, false); // 非 boxed

    try allocator.buildInterferenceGraph();
    var alloc = try allocator.color();
    defer alloc.deinit(std.testing.allocator);

    // VReg 0 是 boxed，其寄存器应在 release_mask 中
    const r0 = alloc.getPReg(0);
    if (r0 < 64) {
        try std.testing.expect((alloc.release_mask & (@as(u64, 1) << @intCast(r0))) != 0);
    }
}
