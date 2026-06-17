# Armin Runtime Event 架构审计

> Phase 2.5 — 向事件驱动 runtime state 收敛

长期 runtime 持久化和远端 daemon 方向见 [Bridge Runtime 长期架构](bridge-runtime-long-term-architecture.md)。

## 1. 当前 RuntimeEventBus 职责

**位置**：`lib/features/runtime/services/runtime_event_bus.dart`

**当前事件类型**（7 个）：

- `taskCreated`
- `taskStarted`
- `taskProgress`
- `taskWaitingUser`
- `taskCompleted`
- `taskFailed`
- `taskCancelled`

**缺失事件**（已识别 gap）：

- `taskPaused` / `taskResumed`：没有专用事件；暂停/恢复通过 `_saveControlledTask` 处理，未通知 bridge
- `ObserverAttached` / `ObserverDetached`：observer 生命周期未反映到 event bus
- `ConnectionLost` / `ConnectionRestored`：SSH 断连只在 stream 层处理
- `ApprovalRequested` / `ApprovalResolved` / `ApprovalRejected`：审批事件现在通过 `RuntimeEventBus` 流转
- `OutputUpdated`：输出变化只发 `taskProgress`
- `DeliverableUpdated`：缺少 deliverable 级事件

**集成点**：

- `ArminAppState` 持有 `RuntimeEventBus` 实例，并向 UI 暴露 `runtimeEvents` stream
- `BridgeRuntime` 通过 `_publish()` 在状态转换时发布事件
- `ArminAppState._bridgeSyncTerminalStatus()` 将 TaskStatus 映射为事件类型

**风险**：Event bus 不完整，许多状态变更发生在它的可见性之外。

---

## 2. 当前 TaskWatcher 职责

**位置**：`lib/features/runtime/services/task_watcher.dart`

**当前职责**：

1. **Offset tracking**：按 taskId 维护 `_lastOffsets`
2. **增量输出提取**：`capturedOutput.substring(safeOffset)`
3. **动作提取**：最后一条非噪声行，截断到 120 字符
4. **进度提取**：正则 `(\d{1,3})\s*%`
5. **状态推断**：基于输出字符串匹配：
   - `contains('waiting for user')` / `contains('needs approval')` → `waitingUser`
   - `contains('task completed')` / `contains('completed successfully')` → `completed`
   - `contains('task failed')` / `contains('fatal error')` → `failed`
   - 其他 → `running`
6. **Checkpoint 提取**：匹配 `checkpoint:|阶段:|步骤:`
7. **噪声过滤**：governance lines、prompt echo、tmux/ssh 前缀

**风险**：通过 `contains()` 做状态推断很脆弱，容易产生 false positive / false negative。它应降级为 fallback，而不是主状态权威。

---

## 3. 当前 RuntimeSessionManager 职责

**位置**：`lib/features/runtime/services/runtime_session_manager.dart`

**当前职责**：

1. **Session 创建/恢复**：`createOrRestore()`，按 `projectPath + tmuxSessionName` 去重
2. **Task-to-session 映射**：`attachTask()` 将 taskId 加入 session 的 taskIds 列表
3. **状态生命周期**：`active → detached → destroyed`
4. **Session ID 生成**：由 `projectPath::tmuxSessionName` 规范化得到

**Session 状态**：

- `active`：Session 正在运行
- `detached`：Observer 已断开，但 tmux session 保留
- `destroyed`：Session 已显式清理

**风险**：Session manager 仅存在于内存中，App 重启后无法恢复。

**长期边界**：session 和 task runtime state 必须持久化到 SQLite。Flutter 进程内 session manager 是过渡层，不是权威持久化边界。

---

## 4. 当前审批流程

**位置**：分散在 `ArminAppState`、`TerminalPromptParser`

**当前流程**：

```text
SSH Output Stream
    ↓
_buildStreamingUpdate()
    ↓
TerminalPromptParser.parse() → TerminalPrompt?
    ↓
AgentExecutionUpdate.nativeApproval
    ↓
_taskWithExecutionUpdate() → NativeTerminalApproval / WorkState approval
    ↓
resolveApproval() → sendFollowUp("APPROVAL_DECISION:...") or selectTerminalOption()
    ↓
_saveApprovalDecision() → clearApproval / clearTerminalPrompt
```

**关键观察**：

- **审批不再包装 TerminalPrompt**：原生终端 prompt 现在直接映射为 `NativeTerminalApproval`；workflow-level approval event 单独建模
- **显式审批生命周期**：审批状态由 `ApprovalState` 表达，包括 `pending`、`resolving`、`approved`、`rejected`、`failed`
- **ResolvingApproval 状态存在**：按钮点击后，UI 可以表达终端动作已发送且正在等待确认
- **反同步风险由 reconcile 处理**：如果终端动作失败或远端 prompt 仍存在，refresh/reconcile 可以恢复 pending approval 状态

---

## 5. 当前 Observer 生命周期

**位置**：`lib/features/agent/services/native_output_observer.dart`

**Observer 状态**：

- `running`：检测到活跃输出
- `outputQuieting`：没有新的有意义输出
- `turnIdle`：输出安静时间达到 idleThreshold
- `needAttention`：检测到 approval/confirm/permission 关键词
- `reconnecting`：检测到重连关键词
- `runtimeLost`：重连超过 reconnectThreshold

**Observer ↔ Task State 映射**：

- `running` → TaskStatus.running
- `turnIdle` → TaskStatus.turnIdle
- `needAttention` → TaskStatus.needAttention
- `runtimeLost` → TaskStatus.runtimeLost
- `outputQuieting` → TaskStatus.running（不改变状态）
- `reconnecting` → TaskStatus.running（不改变状态）

**风险**：Observer state → Task state 的映射隐藏在 `_taskWithExecutionUpdate()` 中，不是正式映射。Observer 断开（SSH disconnect）会直接设置 `TaskStatus.observerDetached`，observer 和 task state 存在耦合。

---

## 6. 当前状态转换逻辑

**位置**：主要在 `ArminAppState`

**状态转换**：

```text
draft → pending → running → turnIdle / needAttention / needApproval
                  ↓              ↓
               observerDetached  userCompleted / userFailed
                  ↓
               running (reconnect)

running → runtimeLost / failed / stopped
turnIdle / needAttention → running (continue/followUp)
```

**Bridge 同步**：

- `_bridgeEnsureTaskCreated()`：任务 load/save 时调用
- `_bridgeNotifyExecutionStarted()`：stream start 时调用 `bridgeRuntime.startTask()`
- `_bridgeNotifyExecutionUpdate()`：每次 stream update 时调用 `bridgeRuntime.observeOutput()`
- `_bridgeSyncTerminalStatus()`：状态变化时调用 `markWaitingUser/completeTask/failTask/cancelTask`
- `_bridgeSyncStreamStatus()`：stream-side 状态变化时调用（不是通过 `_saveControlledTask`）

**风险**：存在两条并行状态轨：TaskSession（UI-oriented）和 RuntimeTaskSnapshot（bridge-oriented）。二者通过上述 bridge 方法手动同步，但并非所有路径都能保证同步。

---

## 7. 现有 Parser 依赖

**Parsers**（`lib/features/agent/parsers/`）：

- `TerminalPromptParser`：检测交互式 CLI prompt（带光标的编号选项）
- `AgentOutputCleaner`：清理 thinking blocks、ANSI codes、噪声

**当前依赖**：

- SSH stream → `_buildStreamingUpdate()` → `TerminalPromptParser`、`NativeOutputObserver`
- TaskWatcher → `_extractStatus()`、`_extractProgress()`、`_extractAction()`、`_extractCheckpoint()`，全部基于 regex/contains
- OutputSummaryProvider → `_removeTerminalPromptBlocks()`、`_semanticLines()` 和多种 pattern matching
- ArminAppState → `_taskWithExecutionUpdate()` 消费解析结果

**风险**：Parser 独立运行，缺少共享解析管线和优先级顺序。

---

## 8. 现有 tmux 依赖

**位置**：`lib/features/agent/services/ssh_agent_session_service.dart`

**tmux 用法**：

- 每任务 tmux session：`tmux -L <name> new-session -d ...`
- 输出 capture：`tmux -L <name> capture-pane -t ... -p -S - -E -`
- 发送命令：`tmux -L <name> send-keys -t ... "..." Enter`
- 检查 session 是否存在：`tmux -L <name> has-session -t ...`
- kill session：`tmux -L <name> kill-session -t ...`

**tmux Session Name**：

- 来源：`HostConfig.tmuxSessionName`，默认 `armin`
- 通过 tmux socket name（`-L`）和 session name pattern 实现每任务隔离

**风险**：tmux 同时承担 transport 和间接状态证据；spec 要求它只作为 transport。

**额外风险**：即使 Agent 仍在 thinking、子进程仍在运行或 TUI 隐藏更新，稳定的 `capture-pane` 输出也可能被误判为 `turnIdle`。Pane 稳定只应表示 `outputQuieting` 或 `no visible update`，不是完成。

---

## 9. 现有 Runtime 风险汇总

| 风险 | 严重度 | 影响 |
|------|--------|------|
| 按钮点击后审批不同步 | High | 终端动作可能静默失败 |
| TaskWatcher `contains()` 状态推断 | Medium | 输出关键词导致错误状态转换 |
| 缺少显式审批生命周期 | Medium | 无法区分 `pending` 和 `resolving` |
| Observer ↔ Task state 耦合 | Medium | 某些路径中 ObserverDetached 会被理解成 TaskPaused |
| Bridge sync gaps（pause/resume） | Medium | Bridge 不知道暂停/恢复状态 |
| RuntimeEventBus 不完整 | Low | UI 无法完全消费事件 |
| SessionManager 仅内存态 | Low | session state 无崩溃恢复 |
| 并行状态轨（TaskSession + RuntimeTaskSnapshot） | Low | 手动同步容易漂移 |
| Pane 稳定被当成 turn 完成 | High | 远端 Agent 仍在运行时可能触发结果卡片和 TTS |

---

## 收敛目标

Phase 2.5 后：

```text
SSH/tmux (Transport)
    ↓
RuntimeEventBus (Primary State Carrier)
    ├── TaskStarted, TaskPaused, TaskResumed, ...
    ├── ApprovalRequested, ApprovalResolved, ApprovalRejected
    ├── ObserverAttached, ObserverDetached, ConnectionLost, ConnectionRestored
    └── OutputUpdated, DeliverableUpdated
    ↓
WorkState (Derived UI State)
    ├── Progress
    ├── Approval status
    ├── Deliverables
    └── Summary
    ↓
UI
```

TaskWatcher 保留为兼容层：

```text
RuntimeEventBus (Primary: event-driven)
    ↓
TaskWatcher (Secondary: output observation + legacy fallback)
    → progress extraction
    → summary extraction
    → audit compatibility
```

字符串匹配成为最后 fallback。

Runtime state 最终应由持久化到 SQLite 的 durable events 归约得到。`TaskWatcher._extractStatus()` 和 `tmux capture-pane` 快照只保留为兼容输入，不能成为完成、审批解决或结果可见性的权威。
