//! JIT 可执行内存管理。
//!
//! 负责分配可执行内存页：先以 RW 权限写入机器码，
//! 写入完成后切换为 RX 权限执行。
//! 跨平台支持 macOS/Linux/Windows。

const std = @import("std");
const builtin = @import("builtin");

/// POSIX 内存保护标志（跨平台统一使用原始数值，避免 macOS vm_prot_t 与 Linux PROT 的类型差异）。
const PROT_READ: u32 = 0x1;
const PROT_WRITE: u32 = 0x2;
const PROT_EXEC: u32 = 0x4;

/// mmap 私有映射标志（所有 POSIX 平台相同）。
const MAP_PRIVATE: u32 = 0x0002;

/// mmap 匿名映射标志（macOS 为 0x1000，Linux/BSD 为 0x20）。
const MAP_ANONYMOUS: u32 = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .maccatalyst, .driverkit => 0x1000,
    else => 0x0020,
};

/// 可执行内存块，管理一段 mmap 分配的内存区域。
pub const ExecMemory = struct {
    ptr: [*]u8,
    len: usize,
    // 已写入的字节数（用作分配游标）
    used: usize = 0,

    /// 释放底层内存。
    pub fn deinit(self: *ExecMemory) void {
        switch (builtin.os.tag) {
            .windows => std.os.windows.VirtualFree(self.ptr, 0, std.os.windows.MEM_RELEASE),
            else => {
                // 使用整数地址绕过对齐类型检查（mmap 返回的指针总是页对齐的）
                const addr = @intFromPtr(self.ptr);
                const page_aligned: *align(std.heap.page_size_min) const anyopaque = @ptrFromInt(addr);
                const rc = std.c.munmap(page_aligned, self.len);
                std.debug.assert(rc == 0);
            },
        }
    }

    /// 在内存块中分配 size 字节（4字节对齐），返回写入位置。
    /// 返回 null 表示空间不足。
    pub fn alloc(self: *ExecMemory, size: usize) ?[*]u8 {
        const aligned = std.mem.alignForward(usize, size, 4);
        if (self.used + aligned > self.len) return null;
        const result = self.ptr + self.used;
        self.used += aligned;
        return result;
    }

    /// 将已写入的区域从 RW 切换为 RX，使其可执行。
    /// 在 ARM64 上还需要刷新指令缓存，否则 CPU 可能执行缓存中的旧数据。
    pub fn finalize(self: *ExecMemory) void {
        switch (builtin.os.tag) {
            .windows => {
                var old_protect: std.os.windows.DWORD = 0;
                std.os.windows.VirtualProtect(self.ptr, self.used, std.os.windows.PAGE_EXECUTE_READ, &old_protect);
            },
            else => {
                // POSIX: mprotect 要求页对齐地址
                const page_size = std.heap.page_size_min;
                const page_start = std.mem.alignBackward(usize, @intFromPtr(self.ptr), page_size);
                const page_end = std.mem.alignForward(usize, @intFromPtr(self.ptr) + self.used, page_size);
                const prot: std.c.PROT = @bitCast(@as(u32, PROT_READ | PROT_EXEC));
                const page_ptr: *align(std.heap.page_size_min) anyopaque = @ptrFromInt(page_start);
                const rc = std.c.mprotect(page_ptr, page_end - page_start, prot);
                std.debug.assert(rc == 0);
            },
        }
        // ARM64 需要刷新指令缓存（x86-64 硬件保证缓存一致性，无需此操作）
        flushIcache(self.ptr, self.used);
    }
};

/// 分配一块可写的可执行内存（初始权限为 RW），写入完成后调用 finalize() 切换为 RX。
/// 默认 64KB，可指定更大的大小。
pub fn allocExec(size: usize) !ExecMemory {
    const page_size = std.heap.page_size_min;
    const alloc_size = if (size == 0) 64 * 1024 else std.mem.alignForward(usize, size, page_size);

    switch (builtin.os.tag) {
        .windows => {
            const addr = std.os.windows.VirtualAlloc(
                null,
                alloc_size,
                std.os.windows.MEM_COMMIT | std.os.windows.MEM_RESERVE,
                std.os.windows.PAGE_READWRITE,
            ) orelse return error.OutOfMemory;
            return .{ .ptr = @ptrCast(addr), .len = alloc_size };
        },
        else => {
            // mmap 分配 RW 内存，后续 finalize 时切换为 RX
            const prot: std.c.PROT = @bitCast(@as(u32, PROT_READ | PROT_WRITE));
            const flags: std.c.MAP = @bitCast(@as(u32, MAP_PRIVATE | MAP_ANONYMOUS));
            const addr = std.c.mmap(
                null,
                alloc_size,
                prot,
                flags,
                -1,
                0,
            );
            if (@intFromPtr(addr) == @intFromPtr(std.c.MAP_FAILED)) return error.OutOfMemory;
            return .{ .ptr = @ptrCast(addr), .len = alloc_size };
        },
    }
}

/// 刷新指令缓存，确保 JIT 生成的机器码对 CPU 可见。
/// ARM64 不保证指令缓存与数据缓存的一致性，必须显式刷新。
/// x86-64 硬件保证缓存一致性，此函数为空操作。
fn flushIcache(start: [*]u8, len: usize) void {
    switch (builtin.cpu.arch) {
        .aarch64 => {
            flushIcacheArm64(start, len);
        },
        .x86_64 => {
            // x86-64 硬件保证指令缓存一致性，无需刷新
        },
        else => {},
    }
}

/// ARM64 指令缓存刷新。
/// macOS 使用 sys_icache_invalidate 系统调用；
/// Linux 使用内联汇编（DC CVAU + DSB ISH + IC IVAU + DSB ISH + ISB）。
fn flushIcacheArm64(start: [*]u8, len: usize) void {
    if (len == 0) return;

    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => {
            // macOS 提供 sys_icache_invalidate 系统调用
            const sys_icache_invalidate = struct {
                extern "c" fn sys_icache_invalidate(start: *anyopaque, length: usize) void;
            }.sys_icache_invalidate;
            sys_icache_invalidate(@ptrCast(start), len);
        },
        else => {
            // Linux/其他 POSIX: 手动刷新指令缓存
            // 按缓存行大小（通常 64 字节）逐行刷新
            const cache_line: usize = 64;
            const end = @intFromPtr(start) + len;
            var addr = std.mem.alignBackward(usize, @intFromPtr(start), cache_line);

            while (addr < end) : (addr += cache_line) {
                // DC CVAU: 按地址清理数据缓存到 Point of Unification
                asm volatile ("dc cvau, %[addr]"
                    :
                    : [addr] "r" (addr),
                );
            }

            // DSB ISH: 确保数据缓存清理完成
            asm volatile ("dsb ish" ::: "memory");

            addr = std.mem.alignBackward(usize, @intFromPtr(start), cache_line);
            while (addr < end) : (addr += cache_line) {
                // IC IVAU: 按地址使指令缓存失效
                asm volatile ("ic ivau, %[addr]"
                    :
                    : [addr] "r" (addr),
                );
            }

            // DSB ISH: 确保指令缓存失效完成
            asm volatile ("dsb ish" ::: "memory");
            // ISB: 指令同步屏障，刷新流水线
            asm volatile ("isb" ::: "memory");
        },
    }
}

test "ExecMemory 分配与写入" {
    var mem = try allocExec(4096);
    defer mem.deinit();

    const buf = mem.alloc(16) orelse return error.OutOfMemory;
    buf[0] = 0xC3; // x86 ret 指令（仅用于测试内存可写性）
    try std.testing.expectEqual(@as(usize, 16), mem.used);

    // 再次分配验证游标推进
    _ = mem.alloc(8) orelse return error.OutOfMemory;
    try std.testing.expectEqual(@as(usize, 24), mem.used);
}
