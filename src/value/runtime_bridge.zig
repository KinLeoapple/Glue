//! 运行时桥接模块
//!
//! 将并发运行时相关的外部模块（原子操作、协程调度、通道通信）
//! 重新导出为 Value 系统可用的类型别名，使 Value 联合体能引用
//! 这些运行时对象而无需直接依赖其实现细节。

const atomic_mod = @import("atomic");
const spawn_mod = @import("spawn");
const channel_mod = @import("channel");

/// 原子值，封装对共享可变状态的原子访问
pub const AtomicValue = atomic_mod.AtomicValue;

/// 协程句柄，表示一个异步任务的运行时引用
pub const SpawnHandle = spawn_mod.SpawnHandle;

/// 通道值，用于协程间通信的同步通道
pub const ChannelValue = channel_mod.ChannelValue;

/// 发送端，通道的写入半部
pub const SenderValue = channel_mod.SenderValue;

/// 接收端，通道的读取半部
pub const ReceiverValue = channel_mod.ReceiverValue;
