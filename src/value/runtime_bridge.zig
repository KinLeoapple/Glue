//! runtime 模块桥接——re-export runtime/ 的并发原语类型
//!
//! 定义留 runtime/（atomic.zig/spawn.zig/channel.zig），value/runtime_bridge.zig re-export。
//! Value union 持 *T 指针，release 逻辑由 mod.zig 调 runtime 类型的 unref/release 方法。
//!
//! 这里的 @import("atomic")/("spawn")/("channel") 由 build.zig 的 addImport 注入，
//! 与旧 value.zig L13-15 的循环依赖结构一致。
//!
//! 命名规范：方法名全部使用完整单词，不使用缩写。

const atomic_mod = @import("atomic");
const spawn_mod = @import("spawn");
const channel_mod = @import("channel");

pub const AtomicValue = atomic_mod.AtomicValue;
pub const SpawnHandle = spawn_mod.SpawnHandle;
pub const ChannelValue = channel_mod.ChannelValue;
pub const SenderValue = channel_mod.SenderValue;
pub const ReceiverValue = channel_mod.ReceiverValue;

