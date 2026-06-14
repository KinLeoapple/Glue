//! Per-heap 分代式复制收集器
//!
//! 文档 §5.1: 每个协程拥有独立的 GC heap
//! GC 算法：分代式复制收集器（新生代 + 老生代 + 大对象区）
//!
//! 核心优势：
//! - 零全局暂停：每个 heap 独立回收
//! - 天然防数据竞争：两个协程不可能同时访问同一块内存
//! - 高效回收：函数式风格产生大量的短命对象，新生代频繁回收
//!
//! 设计：
//! - 新生代（Nursery）：半空间复制收集，小对象快速 bump 分配（预留，需根集追踪）
//! - 老生代（Old Generation）：FreeList 分配器，支持单个 free + 块级 bump 分配
//! - 大对象区（Large Object Space）：直接分配，标记-清除收集
//! - 写屏障（Write Barrier）：记录老生代→新生代引用，避免全堆扫描
//!
//! 根集追踪（Shadow Stack 方案 B）：
//! - Evaluator 维护 shadow_stack，在分配前 pushRoot 保护临时 Value
//! - GC 提供 mark/sweep 基础设施，Evaluator 负责从根集追踪可达对象
//! - mark_set 记录标记的堆地址，sweep 回收未标记的分配

const std = @import("std");

/// 大对象阈值：超过此大小的对象直接分配到大对象区
const LARGE_OBJECT_THRESHOLD: usize = 4096;

/// 新生代半空间大小（预留，当前未使用）
const NURSERY_SEMI_SPACE_SIZE: usize = 256 * 1024;

/// 老生代 FreeList 分配器的块大小
const OLD_GEN_BLOCK_SIZE: usize = 64 * 1024;

/// FreeList 节点最小对齐
const FREE_LIST_ALIGNMENT: usize = 16;

/// GC 自动触发阈值增量
const GC_COLLECT_THRESHOLD_INCREMENT: usize = 4 * 1024 * 1024;

/// 老生代 FreeList 分配器
/// 替代 ArenaAllocator，提供更精细的内存管理：
/// - 块级 bump 分配：从 backing_allocator 申请大块，块内 bump 分配
/// - FreeList 复用：释放的内存加入 free list，后续分配可复用
/// - 支持 individual free：GC 可回收单个死亡对象
/// - 块级批量释放：deinit 时释放所有块
pub const OldGenAllocator = struct {
    backing_allocator: std.mem.Allocator,

    /// 已分配的块列表（用于 deinit 时批量释放）
    blocks: std.ArrayList([]u8),

    /// 当前活跃块的 bump 指针
    current_block: []u8,
    current_offset: usize,

    /// FreeList 头节点
    free_list: ?*FreeNode,

    /// 统计
    total_allocated: usize,
    total_freed: usize,

    const FreeNode = struct {
        size: usize,
        next: ?*FreeNode,
    };

    pub const MIN_ALLOC = @sizeOf(FreeNode);
    const BLOCK_HEADER_SIZE: usize = 0;

    pub fn init(backing: std.mem.Allocator) OldGenAllocator {
        return OldGenAllocator{
            .backing_allocator = backing,
            .blocks = std.ArrayList([]u8).empty,
            .current_block = &.{},
            .current_offset = 0,
            .free_list = null,
            .total_allocated = 0,
            .total_freed = 0,
        };
    }

    pub fn deinit(self: *OldGenAllocator) void {
        for (self.blocks.items) |block| {
            self.backing_allocator.free(block);
        }
        self.blocks.deinit(self.backing_allocator);
        self.free_list = null;
        self.total_allocated = 0;
        self.total_freed = 0;
    }

    pub fn allocator(self: *OldGenAllocator) std.mem.Allocator {
        return std.mem.Allocator{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *OldGenAllocator = @ptrCast(@alignCast(ctx));

        const align_bytes = @max(alignment.toByteUnits(), FREE_LIST_ALIGNMENT);
        const needed = std.mem.alignForward(usize, @max(len, MIN_ALLOC), align_bytes);

        // 1. 先在 free list 中查找（first-fit）
        var prev: ?*FreeNode = null;
        var current = self.free_list;
        while (current) |node| {
            if (node.size >= needed) {
                // 从 free list 中移除
                if (prev) |p| {
                    p.next = node.next;
                } else {
                    self.free_list = node.next;
                }
                // 如果剩余空间足够，分裂出一个新的 FreeNode
                const remaining = node.size - needed;
                if (remaining >= MIN_ALLOC + FREE_LIST_ALIGNMENT) {
                    const split_ptr: [*]u8 = @ptrCast(node);
                    const split_node: *FreeNode = @ptrCast(@alignCast(split_ptr + needed));
                    split_node.size = remaining;
                    split_node.next = self.free_list;
                    self.free_list = split_node;
                }
                self.total_allocated += needed;
                return @ptrCast(node);
            }
            prev = current;
            current = node.next;
        }

        // 2. 在当前块中 bump 分配
        const aligned_offset = std.mem.alignForward(usize, self.current_offset, align_bytes);
        if (self.current_block.len > 0 and aligned_offset + needed <= self.current_block.len) {
            self.current_offset = aligned_offset + needed;
            self.total_allocated += needed;
            return self.current_block.ptr + aligned_offset;
        }

        // 3. 当前块空间不足，分配新块
        const block_size = @max(needed, OLD_GEN_BLOCK_SIZE);
        const block = self.backing_allocator.alignedAlloc(u8, .@"16", block_size) catch return null;
        self.blocks.append(self.backing_allocator, block) catch {
            self.backing_allocator.free(block);
            return null;
        };

        // 如果当前块还有剩余空间，将其加入 free list
        if (self.current_block.len > 0 and self.current_block.len - self.current_offset >= MIN_ALLOC) {
            const remaining = self.current_block.len - self.current_offset;
            const remaining_ptr = self.current_block.ptr + self.current_offset;
            const node: *FreeNode = @ptrCast(@alignCast(remaining_ptr));
            node.size = remaining;
            node.next = self.free_list;
            self.free_list = node;
        }

        // 切换到新块
        self.current_block = block;
        self.current_offset = needed;
        self.total_allocated += needed;
        return block.ptr;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        _ = buf;
        return false;
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        _ = buf;
        return null;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        _ = alignment;
        _ = ret_addr;
        const self: *OldGenAllocator = @ptrCast(@alignCast(ctx));

        if (buf.len < MIN_ALLOC) return;

        // 将释放的内存加入 free list
        const node: *FreeNode = @ptrCast(@alignCast(buf.ptr));
        node.size = std.mem.alignForward(usize, buf.len, FREE_LIST_ALIGNMENT);
        node.next = self.free_list;
        self.free_list = node;
        self.total_freed += node.size;
    }
};

pub const GarbageCollector = struct {
    backing_allocator: std.mem.Allocator,

    /// 新生代 From/To 空间（预留，当前未使用）
    nursery_from: []u8,
    nursery_to: []u8,
    nursery_alloc_ptr: usize,
    using_from: bool,

    /// 老生代（FreeList 分配器，支持 individual free）
    old_generation: OldGenAllocator,

    /// 大对象区列表
    large_objects: std.ArrayList(*LargeObject),

    /// 写屏障记忆集（预留）
    remembered_set: std.AutoHashMap(usize, std.ArrayList(usize)),

    /// GC 统计
    gc_count: usize,
    total_allocated: usize,
    total_freed_by_gc: usize,

    // ── 根集追踪基础设施 ──

    /// 标记集合：记录当前 GC 周期中标记为可达的堆地址
    mark_set: std.AutoHashMap(usize, void),

    /// 分配注册表：记录所有通过 GC 分配器分配的内存块
    /// 用于 sweep 阶段回收未标记的分配
    alloc_registry: std.ArrayList(AllocRecord),

    /// 上次 GC 后的分配阈值，超过此值触发下次 GC
    last_collect_threshold: usize,

    const LargeObject = struct {
        ptr: [*]u8,
        size: usize,
        alive: bool,
    };

    /// 分配记录
    const AllocRecord = struct {
        ptr: [*]u8,
        size: usize,
    };

    pub fn init(backing_allocator: std.mem.Allocator) !GarbageCollector {
        return GarbageCollector{
            .backing_allocator = backing_allocator,
            .nursery_from = &.{},
            .nursery_to = &.{},
            .nursery_alloc_ptr = 0,
            .using_from = true,
            .old_generation = OldGenAllocator.init(backing_allocator),
            .large_objects = std.ArrayList(*LargeObject).empty,
            .remembered_set = std.AutoHashMap(usize, std.ArrayList(usize)).init(backing_allocator),
            .gc_count = 0,
            .total_allocated = 0,
            .total_freed_by_gc = 0,
            .mark_set = std.AutoHashMap(usize, void).init(backing_allocator),
            .alloc_registry = std.ArrayList(AllocRecord).empty,
            .last_collect_threshold = 0,
        };
    }

    pub fn deinit(self: *GarbageCollector) void {
        self.old_generation.deinit();

        for (self.large_objects.items) |obj| {
            self.backing_allocator.free(obj.ptr[0..obj.size]);
            self.backing_allocator.destroy(obj);
        }
        self.large_objects.deinit(self.backing_allocator);

        var iter = self.remembered_set.valueIterator();
        while (iter.next()) |list| {
            list.deinit(self.backing_allocator);
        }
        self.remembered_set.deinit();

        self.mark_set.deinit();
        self.alloc_registry.deinit(self.backing_allocator);
    }

    pub fn allocator(self: *GarbageCollector) std.mem.Allocator {
        return std.mem.Allocator{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *GarbageCollector = @ptrCast(@alignCast(ctx));

        // 大对象直接分配到大对象区
        if (len >= LARGE_OBJECT_THRESHOLD) {
            return self.allocLarge(len, alignment) orelse null;
        }

        // 所有分配走老生代（FreeList 分配器）
        const result = self.old_generation.allocator().rawAlloc(len, alignment, @returnAddress());
        if (result != null) {
            self.total_allocated += len;
            // 注册分配到 alloc_registry
            self.alloc_registry.append(self.backing_allocator, .{
                .ptr = result.?,
                .size = len,
            }) catch {};
        }
        return result;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        _ = buf;
        return false;
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        _ = buf;
        return null;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        _ = ctx;
        _ = alignment;
        _ = ret_addr;
        _ = buf;
        // 分代式 GC 不支持单独 free，由 GC 统一回收
    }

    fn allocLarge(self: *GarbageCollector, len: usize, alignment: std.mem.Alignment) ?[*]u8 {
        const align_usize = alignment.toByteUnits();
        const ptr = if (align_usize <= @alignOf(u8))
            self.backing_allocator.alloc(u8, len) catch return null
        else
            self.backing_allocator.alloc(u8, len + align_usize) catch return null;
        const obj = self.backing_allocator.create(LargeObject) catch {
            self.backing_allocator.free(ptr);
            return null;
        };
        obj.* = .{
            .ptr = ptr.ptr,
            .size = len,
            .alive = true,
        };
        self.large_objects.append(self.backing_allocator, obj) catch {
            self.backing_allocator.free(ptr);
            self.backing_allocator.destroy(obj);
            return null;
        };
        self.total_allocated += len;
        return ptr.ptr;
    }

    // ── 根集追踪 API ──

    /// 标记一个堆地址为可达。返回 true 表示新标记（需要继续追踪子对象），
    /// 返回 false 表示已标记过（跳过，避免循环）
    pub fn markObject(self: *GarbageCollector, addr: usize) bool {
        if (addr == 0) return false;
        const result = self.mark_set.getOrPut(addr) catch return false;
        return !result.found_existing;
    }

    /// 检查一个堆地址是否已被标记为可达
    pub fn isMarked(self: *GarbageCollector, addr: usize) bool {
        return self.mark_set.contains(addr);
    }

    /// 清除所有标记（准备新的 GC 周期）
    pub fn clearMarks(self: *GarbageCollector) void {
        self.mark_set.clearRetainingCapacity();
    }

    /// Sweep：回收所有未标记的分配
    /// 由 Evaluator 在 mark 阶段完成后调用
    pub fn sweep(self: *GarbageCollector) void {
        // 1. 回收老生代中未标记的分配
        var i: usize = 0;
        while (i < self.alloc_registry.items.len) {
            const record = self.alloc_registry.items[i];
            const addr = @intFromPtr(record.ptr);
            if (!self.mark_set.contains(addr)) {
                // 回收分配
                const slice = record.ptr[0..record.size];
                self.old_generation.allocator().free(slice);
                self.total_freed_by_gc += record.size;
                _ = self.alloc_registry.swapRemove(i);
                // swapRemove 后不递增 i，因为最后一个元素被移到了位置 i
            } else {
                i += 1;
            }
        }

        // 2. 回收大对象区中未标记的对象
        i = 0;
        while (i < self.large_objects.items.len) {
            const obj = self.large_objects.items[i];
            const addr = @intFromPtr(obj.ptr);
            if (!self.mark_set.contains(addr)) {
                self.backing_allocator.free(obj.ptr[0..obj.size]);
                self.backing_allocator.destroy(obj);
                self.total_freed_by_gc += obj.size;
                _ = self.large_objects.swapRemove(i);
            } else {
                obj.alive = true; // 重置 alive 标记
                i += 1;
            }
        }

        self.gc_count += 1;
        self.last_collect_threshold = self.total_allocated;
    }

    /// 检查是否应该触发 GC
    pub fn shouldCollect(self: *const GarbageCollector) bool {
        return self.total_allocated >= self.last_collect_threshold + GC_COLLECT_THRESHOLD_INCREMENT;
    }

    /// Minor GC：新生代垃圾回收（预留，当前无操作）
    pub fn minorGC(self: *GarbageCollector) void {
        self.gc_count += 1;
        // 当前所有分配走老生代，nursery 无需回收
    }

    /// Major GC：全堆垃圾回收（由 Evaluator 调用 clearMarks + mark + sweep）
    pub fn majorGC(self: *GarbageCollector) void {
        self.minorGC();

        // 清除大对象区中未标记的对象
        var i: usize = 0;
        while (i < self.large_objects.items.len) {
            const obj = self.large_objects.items[i];
            if (!obj.alive) {
                self.backing_allocator.free(obj.ptr[0..obj.size]);
                self.backing_allocator.destroy(obj);
                _ = self.large_objects.swapRemove(i);
            } else {
                obj.alive = false;
                i += 1;
            }
        }
    }

    /// 写屏障（预留）
    pub fn writeBarrier(self: *GarbageCollector, old_gen_ptr: usize, new_gen_ptr: usize) void {
        const result = self.remembered_set.getOrPut(old_gen_ptr) catch return;
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(usize).init(self.backing_allocator);
        }
        result.value_ptr.append(self.backing_allocator, new_gen_ptr) catch {};
    }

    /// 检查指针是否在新生代中
    pub fn isInNursery(self: *GarbageCollector, ptr: usize) bool {
        const space = if (self.using_from) self.nursery_from else self.nursery_to;
        const start = @intFromPtr(space.ptr);
        const end = start + space.len;
        return ptr >= start and ptr < end;
    }

    /// 获取 GC 统计信息
    pub fn stats(self: *const GarbageCollector) GCStats {
        return GCStats{
            .gc_count = self.gc_count,
            .total_allocated = self.total_allocated,
            .total_freed_by_gc = self.total_freed_by_gc,
            .large_object_count = self.large_objects.items.len,
            .alloc_registry_count = self.alloc_registry.items.len,
        };
    }
};

pub const GCStats = struct {
    gc_count: usize,
    total_allocated: usize,
    total_freed_by_gc: usize,
    large_object_count: usize,
    alloc_registry_count: usize,
};
