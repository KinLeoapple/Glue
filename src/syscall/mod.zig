//! Glue syscall 分派模块入口
//!
//! Glue 用户代码 → stdlib 业务层 → __ 前缀 syscall 原语 → 本模块分派。
//! syscall_call 节点的 meta_index 索引 GlueIR.syscall_metas 表得到 syscall_id（u16），
//! Engine.execSyscall 调用本模块的 dispatch 函数按 SyscallId 路由到 io/time/net 实现。
//!
//! 分层职责：
//! - builtin 类型层（src/builtin/）：IOError/TimeError 等 error_newtype 定义
//! - syscall 原语层（本模块）：宿主 syscall 包装，构造错误用 makeError+makeThrow
//! - stdlib 业务层（src/std/）：File/Path/Duration 等高层 API
//!
//! 依赖方向：本模块不依赖 ir（类型信息通过 SyscallRetKind 自描述），ir 模块依赖本模块的
//! SyscallId/lookupByName/returnKind/okTypeName 进行编译期查询。
//! 这反转了原先 syscall → ir 的依赖方向，实现 IR 层与宿主能力解耦。
//!
//! 设计参考：docs/superpowers/specs/2026-07-19-stdlib-design.md

const std = @import("std");
const value = @import("value");

pub const io = @import("io.zig");
pub const time = @import("time.zig");
pub const net = @import("net.zig");
pub const util = @import("util.zig");

/// 注册表模块（声明式 syscall 表，唯一真相源）
pub const registry = @import("registry.zig");

// 从 registry 重导出公共 API
pub const SyscallId = registry.SyscallId;
pub const SyscallRetKind = registry.SyscallRetKind;
pub const SyscallError = registry.SyscallError;
pub const SyscallEntry = registry.SyscallEntry;
pub const SyscallFn = registry.SyscallFn;
pub const REGISTRY = registry.REGISTRY;
pub const lookupByName = registry.lookupByName;
pub const returnKind = registry.returnKind;
pub const okTypeName = registry.okTypeName;
pub const dispatch = registry.dispatch;
