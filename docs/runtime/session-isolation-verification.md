# Session 隔离验证报告

> Phase 2.5 — 每任务 tmux session 隔离审计

## 1. Task ↔ Session 映射

**当前实现**：`SSHAgentSessionService`

每次任务执行通过以下命令创建 tmux session：

```text
tmux -L <socket_name> new-session -d -s <session_name> -c <project_path>
```

- **Socket name**：`armin-<sanitized_host>_<username>`，按 host/user 隔离 tmux server
- **Session name**：`armin-<task_id_truncated>`，按任务隔离 session
- **Project path**：通过 `-c` 设置为 tmux session 工作目录

**验证结果**：✅ 每个任务都有唯一 tmux session，session name 包含 taskId。

---

## 2. Task ↔ Pane 映射

**当前实现**：每个 session 只有一个 pane（`new-session` 默认创建一个 pane）。

命令发送到默认 pane：`-t <session_name>:0.0`。

**验证结果**：✅ task 与 pane 一一对应，任务之间不共享 pane。

---

## 3. Observer 所有权

**当前实现**：每个 `AgentExecutionRequest` 会创建：

- 新 SSH client connection
- 新 `NativeOutputObserver` 实例
- 新 `_ExecutionOutputState` buffer
- 新 update stream 的 StreamController

Observer 由 `ArminAppState._runningExecutions` 中的 stream subscription 持有。

**验证结果**：✅ 每个任务都有自己的 observer，不共享 observer 实例。

**风险**：Observer 是临时对象。如果 `_runningExecutions` 丢失 subscription，只能通过新的 `execute()` 调用重新 attach。

---

## 4. 重连行为

**当前实现**：`reconnectTask()`：

1. 调用 `_saveControlledTask(status: TaskStatus.running, ...)`
2. 调用 `_syncRemoteSnapshot()` capture 当前 pane 内容
3. 使用 `attachOnly: true` 调用 `startTaskExecution()`

SSH 重连时，tmux session 独立保留。客户端只重新 attach：

```text
tmux -L <socket> capture-pane -t <session>:0.0 -p
```

**验证结果**：✅ 重连可读取当前状态，不会打断正在运行的 tmux session。

---

## 5. Observer 断开行为

**当前实现**：`disconnectTask()`：

- 取消 stream subscription
- 从 `_runningExecutions` 移除
- 状态设为 `TaskStatus.observerDetached`
- 不 kill tmux session
- 不暂停远端 Agent

自动断开（`_autoDetachTask`）使用同一路径，reason 为 `'auto_detach'`。

**验证结果**：✅ observer 断开会保留远端执行，任务可重新 attach。

**风险**：RuntimeEventBus 缺少显式 `ConnectionLost` 或 `ObserverDetached` 事件。

---

## 6. 暂停任务行为

**当前实现**：`pauseTask()`：

1. 通过 `pause()` 发送 `Ctrl+Z`，向 tmux pane 进程发送 SIGSTOP
2. 调用 `disconnectTask(markFailed: false, recordDetached: false)` 静默断开
3. 状态设为 `TaskStatus.paused`

`resumeTask()`：

1. 通过 `resume()` 发送 `fg`，发送 SIGCONT
2. 重连并开始监控

**验证结果**：✅ 暂停/恢复能通过 tmux 正确控制 agent 进程。

**风险**：`_bridgeSyncTerminalStatus()` 对 `TaskStatus.paused` 是 no-op（switch 中 `break`），Bridge 不感知暂停/恢复事件。

---

## 7. Session 清理

**当前实现**：`_cleanupTaskSession()`：

```text
tmux -L <socket> kill-session -t <session_name>
```

`SessionManager.destroy()` 将 session 标记为 `destroyed`。

Cleanup 发生在：

- `markTaskCompleted()`：用户标记完成
- `markTaskFailed()`：用户标记失败
- stream `onDone` 且状态为终态
- `cleanupRemoteSession()`：用户显式请求

**验证结果**：✅ session cleanup 能正确销毁 tmux session。

---

## 8. 隔离保证

| 保证 | 状态 | 说明 |
|------|------|------|
| 每任务 tmux session | ✅ | Session name 包含 taskId |
| 每任务 pane | ✅ | 每个 session 只有一个 pane |
| 每任务 observer | ✅ | 每次 execute 都创建新的 NativeOutputObserver |
| Observer 断开不等于任务停止 | ✅ | tmux session 在 observer 断开后继续存在 |
| 重连保留状态 | ✅ | capture-pane 读取当前状态 |
| 跨 host session 隔离 | ✅ | 每个 host/user 使用独立 socket |

---

## 结论

Session 隔离已经足够。

tmux session 管理不需要架构性改动。

建议：只记录上述保证，并在 RuntimeEventBus 中补充 `ObserverDetached` / `ConnectionLost` 事件以提升可见性。
