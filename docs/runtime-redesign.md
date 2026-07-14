# Mem + Sync 重建设计文档

> **状态**：设计阶段
> **目标**：重建内存管理与并发原语系统，实现无锁热路径、高内存利用率、零碎片
> **约束**：自实现、无外部依赖、跨 5 架构兼容、mem 不引用 value 类型
>
> **目录拆分**：原 `src/runtime/` 已拆分为 `src/mem/`（内存管理）和 `src/sync/`（并发原语）

---

## 1. 当前系统的问题

### 1.1 slab_allocator 反向依赖 value

`src/mem/slab_allocator.zig`（原 `src/runtime/slab_allocator.zig`）第 15、31-38 行硬编码引用 value 模块的类型：

```zig
const value = @import("value");
const BOX_TYPES = [_]type{
    value.AdtValue, value.NewtypeValue, value.ArrayValue,
    value.RecordValue, value.Cell, value.Range,
};
```

违反依赖方向：mem 不应知道 value 的具体类型。

### 1.2 Slab 不是最优数据结构

| Slab 设计假设 | LFE 实际情况 | 结论 |
|---|---|---|
| 对象大小运行时才知道 | 编译期已知精确大小 | 大小类是多余开销 |
| 对象生命周期多样 | 通道=基本块级，对象=引用计数 | 不需要通用 free-list |
| 通用分配器 | 专用分配器 | 通用 = 次优 |
| 缓存局部性靠 LIFO free-list | bump 顺序分配更好 | LIFO 破坏局部性 |
| 内核场景需要复杂元数据 | 用户态可以极简 | 头部是浪费 |

### 1.3 热路径有锁

slab 的 alloc/free 都要获取 Mutex。但 LFE 热路径分配几乎都是同一线程内，跨线程只发生在 spawn/channel_send 等少数场景。

### 1.4 通道分配不匹配

LFE 通道需要连续、16B 对齐、批量分配、同生命周期释放。slab 是通用小对象分配器，不适合大块连续数据。

### 1.5 内存驻留无上限

slab 的 ThreadCache 无上限，arena 的 chunk 链表不归还。长期运行内存只增不减。

---

## 2. 设计目标

| 目标 | 指标 |
|---|---|
| 热路径同步 | 零锁（线程本地） |
| 对象 alloc | 2-5 周期 |
| 对象 free | 2 周期 |
| 通道 alloc | 2 周期（bump） |
| 基本块结束 | O(1) reset |
| 页利用率 | > 99% |
| 元数据开销 | < 0.5% |
| 空闲驻留 | 零（空页归还） |
| 线程缓存上限 | 有界（2 页/类型） |
| value 依赖 | 零（mem 不引用 value） |

---

## 3. 架构总览

```
┌──────────────────────────────────────────────────┐
│ GlobalPool（每进程一个，冷路径，简单锁）            │
│  ├── 每类型空闲页缓存（最多 8 页/类型）             │
│  ├── buddy 空闲块树（大对象）                      │
│  └── backing allocator（mmap/malloc）              │
├──────────────────────────────────────────────────┤
│ ThreadContext（每线程一个，热路径，零同步）          │
│  ├── ChannelRegion（通道数据）                     │
│  │   └── bump + reset，按需容量                    │
│  ├── ObjectPools（ObjHeader 对象）                 │
│  │   └── 22 个精确尺寸页池，每类型最多 2 页驻留     │
│  └── ShadowArena（临时作用域）                     │
│      └── bump + reset                             │
└──────────────────────────────────────────────────┘
```

### 依赖方向

```
src/sync/                        # 并发原语（无依赖）
├── sync.zig                     ← 无依赖（纯 std）

src/mem/                         # 内存管理（依赖 sync）
├── page_pool.zig                ← 依赖 std
├── buddy.zig                    ← 依赖 sync + std
├── channel_region.zig           ← 依赖 std
├── global_pool.zig              ← 依赖 sync + std
├── thread_ctx.zig               ← 依赖上述所有
└── debug_allocator.zig          ← 依赖 sync + std

src/value/                       # 值系统（依赖 mem + sync）
└── mod.zig                      → 通过 ThreadContext 分配 ObjHeader

src/lfe/                         # LFE 引擎（依赖 mem）
└── engine.zig                   → 通过 ThreadContext 分配通道
```

**mem 不知道 value 的任何类型。sync 不知道 mem/value 的任何类型。**

---

## 4. 小对象分配：精确尺寸页池

### 4.1 设计原理

- 每种 ObjHeader 对象类型一个独立池
- 每池只管一种固定大小，无大小类
- 每页自包含：对象数组 + 位图 + 页头，零外部元数据
- 按页分配，全空页归还系统

### 4.2 页布局

```
┌─────────────── 4KB 页 ───────────────┐
│ 对象 0   (48B)                        │
│ 对象 1   (48B)                        │
│ 对象 2   (48B)                        │
│ ...                                   │
│ 对象 84  (48B)                        │
│ ◄── 位图 (11B，85 个位) ──►           │
│ ◄── 页头 (16B：对象计数+free计数+next) ──►  │
└───────────────────────────────────────┘

每页容量计算（4KB 页，48B 对象）：
  N × 48 + ceil(N/8) + 16 ≤ 4096
  N = 85
  元数据开销 = (11 + 16) / 4096 = 0.66%
  对象利用率 = 85×48 / 4096 = 99.6%
  尾部碎片 = 4096 - 85×48 - 11 - 16 = 9B（0.22%）
```

### 4.3 页结构

```zig
const PAGE_SIZE: usize = 4096;

/// 页头，固定在页末尾
const PageHeader = struct {
    object_count: u16,   // 本页对象总数
    free_count: u16,     // 空闲对象数
    object_size: u16,    // 对象大小（用于反查）
    _pad: u16,
    next: ?*Page,        // 页链表（同类型）
};

/// 编译期计算每页对象数
fn objectsPerPage(comptime size: usize) usize {
    var n: usize = 1;
    while (n * size + (n + 7) / 8 + @sizeOf(PageHeader) <= PAGE_SIZE) n += 1;
    return n - 1;
}
```

### 4.4 分配/释放

```zig
pub fn PagePool(comptime object_size: usize) type {
    const N = objectsPerPage(object_size);

    return struct {
        const Self = @This();
        pub const capacity = N;

        /// 从页分配一个对象：位图扫描找空闲位
        fn pageAlloc(page: *Page) ?[]u8 {
            const bitmap = page.bitmap();
            for (bitmap, 0..) |word, wi| {
                if (word == 0xFFFF_FFFF_FFFF_FFFF) continue;
                const bit = @ctz(~word);
                const idx = wi * 64 + bit;
                if (idx >= N) continue;
                bitmap[wi] |= (@as(u64, 1) << @intCast(bit));
                page.header.free_count -= 1;
                return page.objectSlot(idx);
            }
            return null;
        }

        /// 释放对象回页：清位图位，全空则标记归还
        fn pageFree(page: *Page, ptr: []u8) bool {
            const idx = pageIndex(page, ptr);
            const wi = idx / 64;
            const bit = idx % 64;
            page.bitmap()[wi] &= ~(@as(u64, 1) << @intCast(bit));
            page.header.free_count += 1;
            return page.header.free_count == page.header.object_count;
        }
    };
}
```

### 4.5 线程本地缓存

每类型每线程最多 2 页（1 active + 1 cached）：

```zig
pub fn ThreadLocalPool(comptime object_size: usize) type {
    return struct {
        active: ?*Page = null,   // 当前分配页
        cached: ?*Page = null,   // 全空闲页缓存（最多 1 页）
        global: *GlobalPool,
        backing: std.mem.Allocator,

        pub fn alloc(self: *Self) ![]u8 {
            // 热路径：active 页分配
            if (self.active) |page| {
                if (PagePool(object_size).pageAlloc(page)) |slot| return slot;
            }
            // active 满：用 cached 或申请新页
            if (self.cached) |page| {
                self.active = page;
                self.cached = null;
                return self.alloc();
            }
            self.active = try self.global.acquirePage(object_size);
            return self.alloc();
        }

        pub fn free(self: *Self, ptr: []u8) void {
            const page = pageOf(ptr);  // 按 4KB 对齐反查页
            const all_free = PagePool(object_size).pageFree(page, ptr);
            if (all_free) {
                if (page == self.active) {
                    if (self.cached == null) {
                        self.active = null;
                        self.cached = page;
                    } else {
                        self.active = null;
                        self.global.returnPage(page);
                    }
                } else {
                    self.global.returnPage(page);
                }
            }
        }
    };
}
```

**内存驻留上限**：每类型每线程最多 2 页 = 8KB。

### 4.6 内存效率

| 场景 | 精确尺寸页池 | Slab |
|---|---|---|
| 用 10 个 48B 对象 | 1 页 4KB，有效 480B | 16KB slab，有效 480B |
| 用 85 个 48B 对象 | 1 页 4KB，有效 4080B | 16KB slab，有效 4080B |
| 全部释放 | **0KB（页归还）** | 16KB 驻留 |
| 元数据 | 27B/页（0.66%） | 64B/slab（0.4%）+ 大小类浪费 |
| slot 浪费 | **0**（精确尺寸） | 向上取整可达 30%+ |

---

## 5. 大对象分配：Buddy 系统

### 5.1 适用范围

大于 256B 的对象（大数组、大字符串、大 record）不走页池，走 buddy 系统。

### 5.2 设计

```zig
//! Buddy 分配器：按 2 的幂分配大块内存。
//!
//! 最小块 512B，最大块 1MB。
//! 分配时向上取整到最近的 2 的幂，分裂大块。
//! 释放时合并相邻空闲块。

const MIN_ORDER: usize = 9;   // 512B
const MAX_ORDER: usize = 20;  // 1MB
const NUM_ORDERS: usize = MAX_ORDER - MIN_ORDER + 1;

pub const BuddyAllocator = struct {
    free_lists: [NUM_ORDERS]?*BuddyBlock = [_]?*BuddyBlock{null} ** NUM_ORDERS,
    backing: std.mem.Allocator,
    lock: sync.Mutex = .{},

    /// 分配：向上取整到 2 的幂，分裂大块
    pub fn alloc(self: *BuddyAllocator, size: usize) ![]u8 {
        const order = sizeToOrder(size);
        self.lock.lock();
        defer self.lock.unlock();
        return self.allocOrder(order);
    }

    /// 释放：合并相邻空闲块
    pub fn free(self: *BuddyAllocator, ptr: []u8) void {
        const order = sizeToOrder(ptr.len);
        self.lock.lock();
        defer self.lock.unlock();
        self.freeOrder(ptr, order);
    }
};

fn sizeToOrder(size: usize) usize {
    var order = MIN_ORDER;
    while ((@as(usize, 1) << @intCast(order)) < size) order += 1;
    return order - MIN_ORDER;
}
```

### 5.3 碎片控制

Buddy 系统的碎片是"向上取整到 2 的幂"的内部碎片：

| 请求大小 | 分配块 | 内部碎片 |
|---|---|---|
| 300B | 512B | 41% |
| 500B | 512B | 2% |
| 600B | 1024B | 42% |
| 1000B | 1024B | 2% |

最坏情况 50%（请求 = 2^n + 1），但大对象场景可接受（大数组通常本身就是 2 的幂附近）。

---

## 6. 通道分配：线性区

### 6.1 设计

通道数据生命周期与基本块一致，bump 分配 + 整块 reset 是最优。无需 free-list，无需位图。

```zig
//! 线性区：bump 指针分配，reset 释放。
//! 零元数据开销，零碎片，SIMD 强制对齐。

pub const ChannelRegion = struct {
    data: ?[*]u8 align(64),  // 64B 对齐，满足 AVX-512
    len: usize,
    used: usize,
    backing: std.mem.Allocator,

    /// 分配通道：1 次对齐计算 + 1 次指针递增，零锁
    pub fn alloc(self: *ChannelRegion, size: usize) ![]u8 {
        const data = self.data orelse {
            self.data = try self.backing.alignedAlloc(u8, .@"64", size);
            self.len = size;
            self.used = size;
            return self.data.?[0..size];
        };
        const aligned = std.mem.alignForward(usize, self.used, 16);
        if (aligned + size <= self.len) {
            const ptr = data + aligned;
            self.used = aligned + size;
            return ptr[0..size];
        }
        // 容量不够：重新分配
        const new_len = @max(self.len * 2, aligned + size);
        const new_data = try self.backing.alignedAlloc(u8, .@"64", new_len);
        @memcpy(new_data[0..self.used], data[0..self.used]);
        self.backing.free(data[0..self.len]);
        self.data = new_data;
        self.len = new_len;
        return self.alloc(size);
    }

    /// 基本块结束：reset，O(1)
    pub fn reset(self: *ChannelRegion) void {
        self.used = 0;
    }

    pub fn deinit(self: *ChannelRegion) void {
        if (self.data) |d| self.backing.free(d[0..self.len]);
        self.data = null;
    }
};
```

### 6.2 特性

- **零元数据**：无 free-list，无位图，无头部
- **零碎片**：顺序分配，整块 reset
- **SIMD 友好**：64B 对齐
- **极简**：alloc = 1 次加法 + 1 次比较 = 2 周期
- **按需扩容**：容量不够时倍增扩容

### 6.3 内存效率

| 场景 | 固定双缓冲 64KB×2 | 按需线性区 |
|---|---|---|
| 基本块需求 1KB | 驻留 128KB | **驻留 1KB** |
| 基本块需求 10KB | 驻留 128KB | **驻留 10KB** |
| 基本块需求 100KB | 不够，溢出 | **驻留 100KB** |
| 基本块结束 | 驻留不变 | **保留，下次复用** |

---

## 7. 临时作用域：ShadowArena

### 7.1 设计

函数级临时数据（如格式化缓冲区、中间计算结果）用 bump+reset arena：

```zig
pub const ShadowArena = struct {
    data: ?[*]u8 align(16),
    len: usize,
    used: usize,
    backing: std.mem.Allocator,

    pub fn alloc(self: *ShadowArena, size: usize) ![]u8 {
        // 同 ChannelRegion 的 bump 逻辑，但 16B 对齐
    }

    /// 函数返回时 reset
    pub fn reset(self: *ShadowArena) void {
        self.used = 0;
    }
};
```

---

## 8. GlobalPool：冷路径

### 8.1 设计

线程本地内存不足时从 GlobalPool 补充，线程退出时归还。冷路径，简单自旋锁。

```zig
pub const GlobalPool = struct {
    lock: sync.Mutex = .{},
    /// 每类型最多缓存 8 页
    page_cache: [MAX_TYPE_COUNT]?*Page = ...,
    /// buddy 空闲块树
    buddy: BuddyAllocator,
    backing: std.mem.Allocator,

    fn acquirePage(self: *GlobalPool, comptime object_size: usize) !*Page {
        self.lock.lock();
        defer self.lock.unlock();
        const idx = sizeToTypeIdx(object_size);
        if (self.page_cache[idx]) |page| {
            self.page_cache[idx] = null;
            return page;
        }
        return PagePool(object_size).allocPage(self.backing);
    }

    fn returnPage(self: *GlobalPool, page: *Page) void {
        self.lock.lock();
        defer self.lock.unlock();
        const idx = sizeToTypeIdx(page.header.object_size);
        if (self.page_cache[idx] == null) {
            self.page_cache[idx] = page;
        } else {
            self.backing.free(pageToSlice(page));
        }
    }
};
```

### 8.2 缓存上限

| 层级 | 上限 | 内存 |
|---|---|---|
| 线程本地每类型 | 2 页（1 active + 1 cached） | 8KB |
| 全局每类型 | 8 页 | 32KB |
| 全局总上限 | 22 类型 × 8 页 × 4KB | 704KB |

---

## 9. ThreadContext：统一入口

```zig
pub const ThreadContext = struct {
    channels: ChannelRegion,
    objects: ObjectPools,  // comptime 生成的 22 个 ThreadLocalPool
    arena: ShadowArena,
    global: *GlobalPool,
    backing: std.mem.Allocator,

    /// 分配 ObjHeader 对象（编译期已知类型）
    pub fn allocObject(self: *ThreadContext, comptime T: type) !*T {
        const buf = try self.objects.get(T).alloc();
        return @ptrCast(@alignCast(buf.ptr));
    }

    /// 释放 ObjHeader 对象
    pub fn freeObject(self: *ThreadContext, comptime T: type, obj: *T) void {
        const buf = @as([*]u8, @ptrCast(obj))[0..@sizeOf(T)];
        self.objects.get(T).free(buf);
    }

    /// 分配大对象（运行时已知大小）
    pub fn allocLarge(self: *ThreadContext, size: usize) ![]u8 {
        return self.global.buddy.alloc(size);
    }

    pub fn freeLarge(self: *ThreadContext, ptr: []u8) void {
        self.global.buddy.free(ptr);
    }

    /// 分配通道数据
    pub fn allocChannel(self: *ThreadContext, size: usize) ![]u8 {
        return self.channels.alloc(size);
    }

    /// 基本块结束
    pub fn endBlock(self: *ThreadContext) void {
        self.channels.reset();
    }

    /// 函数返回
    pub fn endFunction(self: *ThreadContext) void {
        self.arena.reset();
    }
};
```

### 9.1 ObjectPools：comptime 生成

```zig
/// 编译期生成所有 ObjHeader 类型的线程本地池
pub fn ObjectPools(comptime types: []const type) type {
    return struct {
        pools: [types.len]ThreadLocalPoolOf(types[0]),

        // 实际实现用 inline for 生成 tuple 或 struct
        // 每个 type 对应一个 ThreadLocalPool(@sizeOf(T))
    };
}

// value 层初始化时注册所有类型
const object_types = [_]type{
    ArrayValue, RecordValue, AdtValue, NewtypeValue, Cell, Range, Str,
    VmClosure, PartialApplication, Builtin, TraitValue, LazyValue,
    ErrorValue, ThrowValue,
    ArrayIterator, StringIterator, RangeIterator,
    AtomicValue, SpawnHandle, ChannelValue, SenderValue, ReceiverValue,
};
```

---

## 10. 跨线程对象共享

### 10.1 分配仍在原线程

ObjHeader 对象通过 spawn/channel_send 跨线程传递时：
- **分配**：仍在原线程的 ThreadContext.objects 中分配（热路径零锁）
- **传递**：通过 ObjHeader.rc 原子递增（1 次 atomic fetch_add）
- **释放**：对象最终在**最后一个 release 它的线程**中被 free 到该线程的 free-list

### 10.2 关键

对象在哪个线程 free，就进入哪个线程的 free-list。不需要归还到原线程。

- 跨线程 RC 操作仍然是原子的（unavoidable）
- 但 free 操作仍然零锁（进入当前线程的本地 free-list）

---

## 11. 与 Value 层的交互

```zig
// value 层分配 ObjHeader 对象
pub fn newArray(ctx: *mem.ThreadContext, len: usize) !*ArrayValue {
    const buf = try ctx.allocObject(ArrayValue);
    const arr: *ArrayValue = @ptrCast(@alignCast(buf));
    arr.header = .{ .type_tag = .array, .rc = 1 };
    arr.len = len;
    // ...
    return arr;
}

// value 层释放 ObjHeader 对象
pub fn release(obj: *ObjHeader, ctx: *mem.ThreadContext) void {
    if (obj.rc > 1) {
        _ = @atomicRmw(u32, &obj.rc, .Sub, 1, .release);
        return;
    }
    deinit_table[@intFromEnum(obj.type_tag)](obj);
    const size = objectSize(obj.type_tag);
    ctx.freeObjectBySize(size, @as([*]u8, @ptrCast(obj))[0..size]);
}
```

---

## 12. LFE 引擎使用

```zig
// LFE 层流图执行
fn executeBlock(ctx: *mem.ThreadContext, block: *LaminarBlock) void {
    // 1. 为所有通道分配数据
    for (block.channels) |chan_desc| {
        chan_desc.data = ctx.allocChannel(chan_desc.width * chan_desc.count);
    }

    // 2. 逐层执行（通道数据在线性区中，SIMD 友好）
    for (block.laminae) |lamina| {
        executeLamina(ctx, lamina);
    }

    // 3. 基本块结束，reset 通道（O(1)）
    ctx.endBlock();
}
```

---

## 13. 性能对比

### 13.1 热路径

| 操作 | 当前 slab/arena | 新方案 | 提升 |
|---|---|---|---|
| 通道 alloc | lock + slab 查找 | **bump 2 周期** | 10-20x |
| 通道 free | lock + free-list push | **reset O(1)** | 无逐个 free |
| 对象 alloc | lock + free-list pop | **位图扫描 2-5 周期** | 5-10x |
| 对象 free | lock + free-list push | **位图清除 2 周期** | 5-10x |
| 基本块结束 | 逐个 free | **reset O(1)** | O(n) → O(1) |
| 跨线程共享 | lock + RC | **atomic RC only** | 移除分配锁 |

### 13.2 内存效率

| 指标 | 当前 | 新方案 |
|---|---|---|
| 页利用率 | slab 大小类浪费可达 30%+ | **99.6%**（精确尺寸） |
| 元数据开销 | 64B/slab（0.4%） | **27B/页（0.66%）** |
| 空闲驻留 | slab/arena 不归还 | **零**（空页归还） |
| 线程缓存上限 | 无上限 | **2 页/类型** |
| 全局缓存上限 | 无上限 | **8 页/类型** |
| 通道浪费 | 固定 128KB 双缓冲 | **按需，通常 1-10KB** |
| 长期运行膨胀 | 内存只增不减 | **零膨胀**（空页归还） |

### 13.3 总内存驻留

| 组件 | 当前 | 新方案 |
|---|---|---|
| 通道 | 128KB（双缓冲 64KB） | **按需，通常 1-10KB** |
| 对象缓存 | slab 16KB×N，无上限 | **每类型 2 页=8KB** |
| 临时区 | arena 4KB+ | 按需 |
| 总线程驻留 | ~256KB+ | **~20-50KB** |
| 总全局驻留 | 不定 | **~704KB 上限** |

---

## 14. 模块结构

```
src/sync/                       # 并发原语（独立目录）
└── sync.zig                    # Mutex, Condition, NullMutex（无依赖，无需修改）

src/mem/                        # 内存管理（独立目录）
├── page_pool.zig               # 新增：PagePool（精确尺寸页池）
├── buddy.zig                   # 新增：BuddyAllocator（大对象）
├── channel_region.zig          # 新增：ChannelRegion（通道线性区）
├── global_pool.zig             # 新增：GlobalPool（冷路径，页缓存+buddy）
├── thread_ctx.zig              # 新增：ThreadContext（统一入口）
├── debug_allocator.zig         # 保留：调试用
└── arena_allocator.zig         # 保留（兼容旧代码，逐步迁移到 ShadowArena）
```

### 已删除

- `src/runtime/`（整个目录已删除，拆分为 `src/mem/` 和 `src/sync/`）
- `slab_allocator.zig`（被 page_pool + buddy 替代，尚未删除）

### 保留的文件

- `src/sync/sync.zig`（无依赖，无需修改）
- `src/mem/debug_allocator.zig`（调试工具，无需修改）
- `src/mem/arena_allocator.zig`（兼容旧代码，逐步迁移到 ShadowArena）

---

## 15. 实施计划

| 阶段 | 内容 | 风险 |
|---|---|---|
| 1 | 新增 `src/mem/page_pool.zig`（精确尺寸页池） | 低（新文件，独立测试） |
| 2 | 新增 `src/mem/buddy.zig`（大对象分配） | 中（buddy 合并逻辑需测试） |
| 3 | 新增 `src/mem/channel_region.zig`（通道线性区） | 低（bump 逻辑简单） |
| 4 | 新增 `src/mem/global_pool.zig`（冷路径页缓存） | 低（简单锁 + 链表） |
| 5 | 新增 `src/mem/thread_ctx.zig`（统一入口） | 低（聚合层） |
| 6 | 迁移 value 层到 ThreadContext | 中（所有分配调用点更新） |
| 7 | 迁移 VM/LFE 到 ThreadContext | 中（通道分配更新） |
| 8 | 删除 `src/mem/slab_allocator.zig` | 低（确认无引用后删除） |

---

## 16. 平台兼容性

| 组件 | 实现方式 | 平台支持 |
|---|---|---|
| 页分配 | `mmap`（Linux/macOS）/ `VirtualAlloc`（Windows）/ `malloc`（fallback） | 全平台 |
| 线程本地存储 | `std.Thread.threadlocal`（Zig 内建） | 全平台 |
| 原子操作 | `std.atomic.Value`（Zig 内建） | 全平台（含 riscv32） |
| 锁 | `src/sync/sync.zig` 的 Mutex（自旋，无 futex） | 全平台 |
| SIMD 对齐 | 64B 对齐 | 全平台 |

**无 OS 原语依赖**：不使用 futex/condition variable，sync.zig 已是自旋策略。
