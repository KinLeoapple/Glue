//! 内存管理模块入口
//!
//! 提供三种分配器：
//! - ChannelRegion：通道数据，bump + reset（短生命周期）
//! - ObjectPool / ThreadContext：堆对象，精确尺寸页池（中长生命周期）
//! - ShadowArena：临时作用域，bump + reset（极短生命周期）

const std = @import("std");

pub const channel_region = @import("channel_region.zig");
pub const shadow_arena = @import("shadow_arena.zig");
pub const page_pool = @import("page_pool.zig");
pub const global_pool = @import("global_pool.zig");
pub const buddy = @import("buddy.zig");
pub const thread_ctx = @import("thread_ctx.zig");

// 重导出常用类型
pub const ChannelRegion = channel_region.ChannelRegion;
pub const ShadowArena = shadow_arena.ShadowArena;
pub const ThreadContext = thread_ctx.ThreadContext;
pub const GlobalPool = global_pool.GlobalPool;
