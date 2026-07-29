//! 并发堆对象类型：原子值、异步句柄、通道、发送端、接收端
//!
//! 对应 Zig 实现中的并发值类型。Glue 运行时为单线程协作式调度，
//! 故使用 `Rc`（非 `Arc`）进行引用计数；`Mutex` 用于内部可变性，
//! 在单线程上下文中不会产生真正的锁竞争。

use std::rc::Rc;
use std::sync::Mutex;

use crate::value::Value;

// =========================================================================
// AtomicValue — 原子值（互斥保护的 可变值）
// =========================================================================

/// 原子值：互斥锁保护的可变值
#[derive(Debug)]
pub struct AtomicValue {
    data: Mutex<Value>,
}

impl AtomicValue {
    /// 创建包含指定值的原子值
    pub fn new(val: Value) -> Self {
        Self {
            data: Mutex::new(val),
        }
    }

    /// 加载值的克隆
    pub fn load(&self) -> Value {
        self.data.lock().unwrap().clone()
    }

    /// 存储新值
    pub fn store(&self, val: Value) {
        *self.data.lock().unwrap() = val;
    }

    /// 交换值，返回旧值
    pub fn swap(&self, val: Value) -> Value {
        std::mem::replace(&mut *self.data.lock().unwrap(), val)
    }
}

impl Clone for AtomicValue {
    fn clone(&self) -> Self {
        Self::new(self.load())
    }
}

// =========================================================================
// AsyncStatus / AsyncHandle — 异步状态与句柄
// =========================================================================

/// 异步任务状态
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AsyncStatus {
    /// 待执行
    Pending,
    /// 执行中
    Running,
    /// 已完成
    Completed,
    /// 已取消
    Cancelled,
    /// 已失败
    Failed,
}

/// 异步句柄：异步任务的运行时表示，持有状态与结果
#[derive(Debug)]
pub struct AsyncHandle {
    status: Mutex<AsyncStatus>,
    result: Mutex<Option<Value>>,
}

impl AsyncHandle {
    /// 创建新的异步句柄（初始状态为 `Pending`）
    pub fn new() -> Self {
        Self {
            status: Mutex::new(AsyncStatus::Pending),
            result: Mutex::new(None),
        }
    }

    /// 获取当前状态
    pub fn status(&self) -> AsyncStatus {
        *self.status.lock().unwrap()
    }

    /// 设置状态
    pub fn set_status(&self, status: AsyncStatus) {
        *self.status.lock().unwrap() = status;
    }

    /// 获取结果（克隆）
    pub fn result(&self) -> Option<Value> {
        self.result.lock().unwrap().clone()
    }

    /// 设置结果
    pub fn set_result(&self, val: Value) {
        *self.result.lock().unwrap() = Some(val);
    }
}

impl Default for AsyncHandle {
    fn default() -> Self {
        Self::new()
    }
}

impl Clone for AsyncHandle {
    fn clone(&self) -> Self {
        let status = self.status();
        let result = self.result();
        Self {
            status: Mutex::new(status),
            result: Mutex::new(result),
        }
    }
}

// =========================================================================
// ChannelValue — 通道值
// =========================================================================

/// 通道值：缓冲或同步通道，支持发送与接收
#[derive(Debug)]
pub struct ChannelValue {
    buffer: Mutex<Vec<Value>>,
    capacity: usize,
    closed: Mutex<bool>,
}

impl ChannelValue {
    /// 创建指定容量的通道（`capacity` 为 0 表示无缓冲）
    pub fn new(capacity: usize) -> Self {
        Self {
            buffer: Mutex::new(Vec::new()),
            capacity,
            closed: Mutex::new(false),
        }
    }

    /// 发送值：通道已关闭时返回错误
    pub fn send(&self, val: Value) -> Result<(), String> {
        if *self.closed.lock().unwrap() {
            return Err("channel closed".to_string());
        }
        let mut buf = self.buffer.lock().unwrap();
        if self.capacity > 0 && buf.len() >= self.capacity {
            return Err("channel full".to_string());
        }
        buf.push(val);
        Ok(())
    }

    /// 接收值：缓冲为空时返回 `None`
    pub fn recv(&self) -> Option<Value> {
        let mut buf = self.buffer.lock().unwrap();
        if !buf.is_empty() {
            Some(buf.remove(0))
        } else {
            None
        }
    }

    /// 非阻塞发送：通道已关闭或已满时返回错误
    pub fn try_send(&self, val: Value) -> Result<(), String> {
        self.send(val)
    }

    /// 非阻塞接收：缓冲为空时返回 `None`
    pub fn try_recv(&self) -> Option<Value> {
        self.recv()
    }

    /// 关闭通道
    pub fn close(&self) {
        *self.closed.lock().unwrap() = true;
    }

    /// 通道是否已关闭
    pub fn is_closed(&self) -> bool {
        *self.closed.lock().unwrap()
    }
}

impl Clone for ChannelValue {
    fn clone(&self) -> Self {
        let buf = self.buffer.lock().unwrap().clone();
        Self {
            buffer: Mutex::new(buf),
            capacity: self.capacity,
            closed: Mutex::new(*self.closed.lock().unwrap()),
        }
    }
}

// =========================================================================
// SenderValue / ReceiverValue — 通道发送端与接收端
// =========================================================================

/// 发送端值：通道的写入端
#[derive(Debug, Clone)]
pub struct SenderValue {
    pub channel: Rc<ChannelValue>,
}

/// 接收端值：通道的读取端
#[derive(Debug, Clone)]
pub struct ReceiverValue {
    pub channel: Rc<ChannelValue>,
}
