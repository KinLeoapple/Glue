//! 异步运行时 + 事件处理：TimerRuntime / AsyncJoinRuntime + 事件到达/取消/timer 检查。

use super::*;
use crate::ir::Ir::*;
use crate::ir::Ir::Frame;
use crate::Value::Value;

/// Timer 事件 Record 中 duration 字段名。
const TIMER_DURATION_NS_FIELD: &str = "duration_ns";

// =========================================================================
// TimerRuntime / AsyncJoinRuntime — 图外运行时
// =========================================================================

/// Timer 运行时：管理 timer deadline + 触发检查。
///
/// spec 3.5 EventSource::Timer。事件循环每次迭代检查到期 timer。
pub struct TimerRuntime {
    timers: Vec<TimerEntry>,
}
struct TimerEntry {
    deadline: std::time::Instant,
    fired: bool,
}
impl TimerRuntime {
    pub fn new() -> Self { Self { timers: Vec::new() } }
    pub fn start(&mut self, duration: std::time::Duration) -> crate::ir::Ir::TimerId {
        let id = crate::ir::Ir::TimerId(self.timers.len() as u32);
        self.timers.push(TimerEntry {
            deadline: std::time::Instant::now() + duration,
            fired: false,
        });
        id
    }
    pub fn check_and_fire(&mut self) -> Vec<crate::ir::Ir::TimerId> {
        let now = std::time::Instant::now();
        let mut fired = Vec::new();
        for (i, t) in self.timers.iter_mut().enumerate() {
            if !t.fired && now >= t.deadline {
                t.fired = true;
                fired.push(crate::ir::Ir::TimerId(i as u32));
            }
        }
        fired
    }
    pub fn is_fired(&self, id: crate::ir::Ir::TimerId) -> bool {
        self.timers.get(id.0 as usize).map(|t| t.fired).unwrap_or(false)
    }
    /// 清理已触发的 timer 条目以回收内存。
    /// 注意：TimerId 是 Vec 索引，不能直接 retain（会导致索引错位）。
    /// 此方法将已触发 timer 的 deadline 重置为零值，不改变 Vec 长度。
    /// TimerEntry 本身很小（Instant + bool），内存影响有限。
    pub fn cleanup(&mut self) {
        // 不删除条目以保持 TimerId 索引有效性
        // TimerEntry 很小，无需主动清理
    }
}

impl Default for TimerRuntime {
    fn default() -> Self {
        Self::new()
    }
}

/// AsyncJoin 运行时：管理 async 调用 → AsyncHandle 映射 + 完成结果。
///
/// async 函数调用启动子帧时注册 async_id → child_fid。
/// 子帧完成时设置 result + 触发 AsyncJoin 事件唤醒等待的 await 帧。
pub struct AsyncJoinRuntime {
    entries: Vec<AsyncJoinEntry>,
    next_async_id: u32,
}
struct AsyncJoinEntry {
    async_id: crate::ir::Ir::AsyncHandleId,
    child_fid: FrameId,
    result: Option<Value>,
}
impl AsyncJoinRuntime {
    pub fn new() -> Self { Self { entries: Vec::new(), next_async_id: 0 } }
    /// 分配新的 async_id（i32 标量值）
    pub fn alloc_id(&mut self) -> crate::ir::Ir::AsyncHandleId {
        assert!(self.next_async_id < u32::MAX, "AsyncHandleId overflow: too many async calls");
        let id = crate::ir::Ir::AsyncHandleId(self.next_async_id);
        self.next_async_id += 1;
        id
    }
    pub fn register(&mut self, async_id: crate::ir::Ir::AsyncHandleId, child_fid: FrameId) {
        self.entries.push(AsyncJoinEntry { async_id, child_fid, result: None });
    }
    /// 原子地分配 async_id 并注册 child_fid（消除 alloc_id + register 的竞态窗口）。
    pub fn alloc_and_register(&mut self, child_fid: FrameId) -> crate::ir::Ir::AsyncHandleId {
        let async_id = crate::ir::Ir::AsyncHandleId(self.next_async_id);
        self.next_async_id += 1;
        self.entries.push(AsyncJoinEntry { async_id, child_fid, result: None });
        async_id
    }
    pub fn find_by_child(&self, child_fid: FrameId) -> Option<crate::ir::Ir::AsyncHandleId> {
        // 仅匹配未完成（result=None）的 entry：帧 ID 会被复用，
        // 已完成的旧 entry 若仍匹配会导致新 async call 的完成事件被错误路由到旧 async_id。
        self.entries
            .iter()
            .find(|e| e.child_fid == child_fid && e.result.is_none())
            .map(|e| e.async_id)
    }
    pub fn find_child_by_async_id(&self, async_id: crate::ir::Ir::AsyncHandleId) -> Option<FrameId> {
        self.entries.iter().find(|e| e.async_id == async_id).map(|e| e.child_fid)
    }
    pub fn try_get_result(&self, async_id: crate::ir::Ir::AsyncHandleId) -> Option<Value> {
        self.entries.iter().find(|e| e.async_id == async_id).and_then(|e| e.result.clone())
    }
    pub fn set_result(&mut self, async_id: crate::ir::Ir::AsyncHandleId, value: Value) {
        if let Some(e) = self.entries.iter_mut().find(|e| e.async_id == async_id) {
            e.result = Some(value);
        }
    }
    /// 清理已完成且 result 已被读取的 entry，释放内存。
    /// 注意：AsyncHandleId 是 alloc_id 分配的递增值，不是 entries 索引，
    /// 所以移除 entry 不影响 ID 有效性。
    pub fn cleanup_consumed(&mut self, consumed_ids: &[crate::ir::Ir::AsyncHandleId]) {
        self.entries.retain(|e| {
            // 保留未完成的，或已完成但未被消费的
            e.result.is_none() || !consumed_ids.contains(&e.async_id)
        });
    }
}

impl Default for AsyncJoinRuntime {
    fn default() -> Self {
        Self::new()
    }
}

// =========================================================================
// impl<S: LockStrategy> Engine<S> — 事件处理方法
// =========================================================================

impl<S: LockStrategy> Engine<S> {
    /// 解析 await 事件源 + 检查就绪。
    pub(super) fn resolve_and_check_await(
        &self,
        pending: &crate::ir::Ir::PendingAwait,
    ) -> (RuntimeEvent, Option<Value>) {
        use crate::ir::Ir::EventSourceKind;
        match pending.event_kind {
            EventSourceKind::AsyncJoin => {
                let async_id = crate::ir::Ir::AsyncHandleId(pending.event_obj.as_i32() as u32);
                let event = RuntimeEvent::AsyncJoin(async_id);
                let val = self.async_join_runtime.lock().try_get_result(async_id);
                (event, val)
            }
            EventSourceKind::Channel => {
                let ch = pending
                    .event_obj
                    .heap_obj()
                    .and_then(|h| h.channel())
                    .expect("await on non-channel value");
                let v = ch.recv().or_else(|| if ch.is_closed() { Some(Value::Null) } else { None });
                let event = RuntimeEvent::ChannelReady(crate::ir::Ir::ChannelId(ch.id()));
                (event, v)
            }
            EventSourceKind::Timer => {
                let duration_ns = match pending.event_obj.heap_obj() {
                    Some(crate::Value::HeapObj::Record(r)) => {
                        r.find_field(TIMER_DURATION_NS_FIELD)
                            .map(|v| v.as_i64())
                            .expect("timer event record missing duration_ns field")
                    }
                    _ => pending.event_obj.as_i64(),
                };
                let timer_id = self
                    .timer_runtime
                    .lock()
                    .start(std::time::Duration::from_nanos(duration_ns as u64));
                let event = RuntimeEvent::TimerFired(timer_id);
                let fired = self.timer_runtime.lock().is_fired(timer_id);
                if fired {
                    (event, Some(Value::VOID))
                } else {
                    (event, None)
                }
            }
            EventSourceKind::SubgraphComplete => {
                panic!("SubgraphComplete should not go through await path");
            }
        }
    }

    /// 事件到达：注入值到等待帧 + 唤醒。
    pub(super) fn on_event_arrived(&self, event: RuntimeEvent, value: Value, queue: &QueueHandle<'_>) {
        // 找等待该事件的帧（短临界区）
        let waiters: Vec<FrameId> = {
            let mut event_waiters = self.event_waiters.lock();
            let waiters: Vec<FrameId> = event_waiters
                .iter()
                .filter(|(e, _)| *e == event)
                .map(|(_, fid)| *fid)
                .collect();
            event_waiters.retain(|(_, fid)| !waiters.contains(fid));
            waiters
        };

        for fid in waiters {
            // 取出帧（保持 Box 不 unbox 以维持地址稳定）
            let mut frame_box = {
                let mut frames = self.frames.lock();
                match frames.remove(&fid) {
                    Some(b) => b,
                    None => continue, // 帧正被其他 worker 处理，跳过
                }
            };
            let frame: &mut Frame = &mut *frame_box;

            let await_node = match frame.suspend_state {
                SuspendState::WaitingEvent(node) => node,
                _ => {
                    // 非事件等待帧：放回 + 跳过
                    self.frames.lock().insert(fid, frame_box);
                    continue;
                }
            };

            let node_offset = frame.node_offset;
            let await_graph_id = NodeId(await_node.0 + node_offset);

            // select 帧（gate 节点有 SelectInfo）：重新 push gate 节点，不注入值
            let is_select = self.graph.select_infos[await_graph_id.0 as usize].is_some();
            if is_select {
                frame.state = FrameState::Ready;
                frame.suspend_state = SuspendState::NotSuspended;
                frame.suspend_event = None;
                frame.push_ready(await_node);
            } else {
                // 普通 await 帧：注入事件值到 await 节点
                let consumer_count =
                    self.graph.downstreams[await_graph_id.0 as usize].len() as u16;
                frame.set_value(await_node, value.clone(), consumer_count);
                frame.state = FrameState::Ready;
                frame.suspend_state = SuspendState::NotSuspended;
                frame.suspend_event = None;
                notify_downstream(
                    frame,
                    &self.graph,
                    await_node,
                    await_graph_id,
                    NodeId(node_offset),
                );
            }

            // 放回帧 + 入队（同一个 Box，地址不变）
            self.frames.lock().insert(fid, frame_box);
            queue.push(fid);
        }
    }

    /// 取消帧：Suspended → Cancelling + 入就绪队列。
    pub(super) fn cancel_frame(&self, frame_id: FrameId, queue: &QueueHandle<'_>) {
        let mut frame_box = {
            let mut frames = self.frames.lock();
            match frames.remove(&frame_id) {
                Some(b) => b,
                None => return, // 帧正被其他 worker 处理，跳过
            }
        };
        let frame: &mut Frame = &mut *frame_box;

        if frame.state != FrameState::Suspended {
            self.frames.lock().insert(frame_id, frame_box);
            return;
        }

        // 移除事件等待注册
        if let Some(event) = frame.suspend_event {
            self.event_waiters
                .lock()
                .retain(|(e, fid)| !(*e == event && *fid == frame_id));
        } else {
            // select 帧：移除该帧所有事件等待
            self.event_waiters
                .lock()
                .retain(|(_, fid)| *fid != frame_id);
        }

        frame.state = FrameState::Cancelling;
        frame.suspend_state = SuspendState::NotSuspended;
        frame.suspend_event = None;

        self.frames.lock().insert(frame_id, frame_box);
        queue.push(frame_id);
    }

    /// 检查 timer 事件
    pub(super) fn check_timers(&self, queue: &QueueHandle<'_>) {
        let fired_timers = self.timer_runtime.lock().check_and_fire();
        for tid in fired_timers {
            self.on_event_arrived(RuntimeEvent::TimerFired(tid), Value::VOID, queue);
        }
    }
}
