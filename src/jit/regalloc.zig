//! 线性扫描寄存器分配器。
//!
//! 将 IR 虚拟寄存器分配到物理寄存器或栈槽。
//! 采用线性扫描算法：按虚拟寄存器定义点排序，
//! 维护活跃区间集合，贪心分配物理寄存器。

const std = @import("std");
const ir = @import("ir.zig");
const backend = @import("backend.zig");

/// 虚拟寄存器的活跃区间。
const LiveInterval = struct {
    vreg: ir.VReg,
    start: u32, // 定义点（IR 指令索引）
    end: u32, // 最后使用点
    assigned_reg: ?backend.PhysReg = null,
    spilled: bool = false,
    stack_slot: ?u32 = null,
};

/// 寄存器分配结果。
pub const Allocation = struct {
    /// 虚拟寄存器 → 物理寄存器映射。
    vreg_to_phys: std.AutoHashMap(u32, backend.PhysReg),
    /// 溢出到栈的虚拟寄存器 → 栈偏移映射。
    vreg_to_slot: std.AutoHashMap(u32, u32),
    /// 总栈槽数（用于计算栈帧大小）。
    spill_slots: u32,

    pub fn deinit(self: *Allocation) void {
        self.vreg_to_phys.deinit();
        self.vreg_to_slot.deinit();
    }
};

/// 执行线性扫描寄存器分配。
/// `avail_regs` 是可用于分配的物理寄存器列表。
pub fn allocate(
    allocator: std.mem.Allocator,
    func: *const ir.IRFunction,
    avail_regs: []const backend.PhysReg,
) !Allocation {
    // 1. 计算每个虚拟寄存器的活跃区间
    var intervals = std.AutoHashMap(u32, LiveInterval).init(allocator);
    defer intervals.deinit();

    for (func.insts.items, 0..) |inst, i| {
        // 定义点
        if (inst.dst.isValid()) {
            const entry = try intervals.getOrPut(inst.dst.id);
            if (!entry.found_existing) {
                entry.value_ptr.* = .{
                    .vreg = inst.dst,
                    .start = @intCast(i),
                    .end = @intCast(i),
                };
            } else {
                entry.value_ptr.end = @max(entry.value_ptr.end, @as(u32, @intCast(i)));
            }
        }
        // 使用点
        inline for (.{ &inst.a, &inst.b }) |operand_ptr| {
            if (operand_ptr.* == .vreg) {
                const vr = operand_ptr.vreg;
                const entry = try intervals.getOrPut(vr.id);
                if (!entry.found_existing) {
                    entry.value_ptr.* = .{
                        .vreg = vr,
                        .start = @intCast(i),
                        .end = @intCast(i),
                    };
                } else {
                    entry.value_ptr.end = @max(entry.value_ptr.end, @as(u32, @intCast(i)));
                }
            }
        }
    }

    // 1b. 循环感知：对于向后跳转（循环回边），将跳转目标处活跃的变量
    // 的 end 延伸到跳转指令位置，确保循环不变量在循环体中保持活跃。
    var label_to_idx = std.AutoHashMap(u32, u32).init(allocator);
    defer label_to_idx.deinit();
    for (func.insts.items, 0..) |inst, i| {
        if (inst.op == .label) {
            try label_to_idx.put(inst.label, @intCast(i));
        }
    }

    var changed = true;
    while (changed) {
        changed = false;
        for (func.insts.items, 0..) |inst, i| {
            // 收集跳转目标标签
            const targets: [2]?u32 = switch (inst.op) {
                .jump => .{ inst.label, null },
                .branch => .{ inst.label, @truncate(@as(u64, @bitCast(inst.imm))) },
                else => .{ null, null },
            };
            for (targets) |maybe_tl| {
                const tl = maybe_tl orelse continue;
                const target_idx = label_to_idx.get(tl) orelse continue;
                if (target_idx > i) continue; // 向前跳转，非循环
                // 向后跳转：将 target_idx 处活跃变量的 end 延伸到 i
                var it2 = intervals.iterator();
                while (it2.next()) |entry| {
                    const ival = entry.value_ptr.*;
                    // 变量在 target_idx 处活跃：start <= target_idx 且 end >= target_idx
                    if (ival.start <= target_idx and ival.end >= target_idx) {
                        if (ival.end < @as(u32, @intCast(i))) {
                            entry.value_ptr.end = @intCast(i);
                            changed = true;
                        }
                    }
                }
            }
        }
    }

    // 2. 按起始点排序活跃区间
    var sorted: std.ArrayListUnmanaged(LiveInterval) = .empty;
    defer sorted.deinit(allocator);
    var it = intervals.iterator();
    while (it.next()) |entry| {
        try sorted.append(allocator, entry.value_ptr.*);
    }
    std.mem.sort(LiveInterval, sorted.items, {}, struct {
        fn lt(_: void, a: LiveInterval, b: LiveInterval) bool {
            return a.start < b.start;
        }
    }.lt);

    // 3. 线性扫描分配
    var active: std.ArrayListUnmanaged(LiveInterval) = .empty;
    defer active.deinit(allocator);
    var next_spill_slot: u32 = 0;

    var vreg_to_phys = std.AutoHashMap(u32, backend.PhysReg).init(allocator);
    var vreg_to_slot = std.AutoHashMap(u32, u32).init(allocator);

    for (sorted.items) |interval| {
        // 过期旧区间
        var i: usize = 0;
        while (i < active.items.len) {
            if (active.items[i].end < interval.start) {
                _ = active.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        // 查找空闲物理寄存器
        var found_reg: ?backend.PhysReg = null;
        for (avail_regs) |preg| {
            var conflict = false;
            for (active.items) |act| {
                if (act.assigned_reg) |ar| {
                    if (ar.id == preg.id and ar.kind == preg.kind) {
                        conflict = true;
                        break;
                    }
                }
            }
            if (!conflict) {
                found_reg = preg;
                break;
            }
        }

        if (found_reg) |preg| {
            try vreg_to_phys.put(interval.vreg.id, preg);
            var mut_interval = interval;
            mut_interval.assigned_reg = preg;
            try active.append(allocator, mut_interval);
        } else {
            // 溢出到栈
            try vreg_to_slot.put(interval.vreg.id, next_spill_slot);
            next_spill_slot += 1;
        }
    }

    return .{
        .vreg_to_phys = vreg_to_phys,
        .vreg_to_slot = vreg_to_slot,
        .spill_slots = next_spill_slot,
    };
}
