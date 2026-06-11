# Session Isolation Verification Report

> Phase 2.5 — Per-task tmux session isolation audit

## 1. Task ↔ Session Mapping

**Current Implementation**: `SSHAgentSessionService`

Each task execution creates a tmux session via:
```
tmux -L <socket_name> new-session -d -s <session_name> -c <project_path>
```

- **Socket name**: `armin-<sanitized_host>_<username>` — isolates tmux servers per host/user
- **Session name**: `armin-<task_id_truncated>` — isolates sessions per task
- **Project path**: Set as tmux session working directory via `-c`

**Verification**: ✅ Each task gets a unique tmux session. Session name includes taskId.

---

## 2. Task ↔ Pane Mapping

**Current Implementation**: Single pane per session (`new-session` creates one pane by default).

Commands are sent to the default pane (`-t <session_name>:0.0`).

**Verification**: ✅ One-to-one task-to-pane mapping. No shared panes between tasks.

---

## 3. Observer Ownership

**Current Implementation**: Each `AgentExecutionRequest` creates:
- New SSH client connection
- New `NativeOutputObserver` instance
- New `_ExecutionOutputState` buffer
- New StreamController for the update stream

Observer is owned by the stream subscription in `ArminAppState._runningExecutions`.

**Verification**: ✅ Each task has its own observer. No shared observer instances.

**Risk**: Observer is ephemeral — if `_runningExecutions` loses the subscription, there's no way to re-attach without creating a new `execute()` call.

---

## 4. Reconnect Behavior

**Current Implementation**: `reconnectTask()`:
1. Calls `_saveControlledTask(status: TaskStatus.running, ...)`
2. Calls `_syncRemoteSnapshot()` to capture current pane content
3. Calls `startTaskExecution()` with `attachOnly: true`

On SSH reconnection, the tmux session persists independently. The client simply re-attaches:
```
tmux -L <socket> capture-pane -t <session>:0.0 -p
```

**Verification**: ✅ Reconnection captures current state without disrupting the running tmux session.

---

## 5. Detached Observer Behavior

**Current Implementation**: `disconnectTask()`:
- Cancels the stream subscription
- Removes from `_runningExecutions`
- Sets status to `TaskStatus.observerDetached`
- Does NOT kill the tmux session
- Does NOT pause the remote agent

Auto-detach (`_autoDetachTask`) uses the same path with reason `'auto_detach'`.

**Verification**: ✅ Detached observer preserves remote execution. Task can be re-attached.

**Risk**: No explicit `ConnectionLost` or `ObserverDetached` event on RuntimeEventBus.

---

## 6. Paused Task Behavior

**Current Implementation**: `pauseTask()`:
1. Sends `Ctrl+Z` via `pause()` → sends SIGSTOP to tmux pane process
2. Calls `disconnectTask(markFailed: false, recordDetached: false)` — silently disconnects
3. Sets status to `TaskStatus.paused`

`resumeTask()`:
1. Sends `fg` via `resume()` → sends SIGCONT
2. Reconnects and starts monitoring

**Verification**: ✅ Pause/resume properly controls agent process via tmux.

**Risk**: `_bridgeSyncTerminalStatus()` treats `TaskStatus.paused` as no-op (`break` in switch). Bridge is unaware of pause/resume events.

---

## 7. Session Cleanup

**Current Implementation**: `_cleanupTaskSession()`:
```
tmux -L <socket> kill-session -t <session_name>
```

SessionManager.destroy() marks session as `destroyed`.

Cleanup happens on:
- `markTaskCompleted()` — user marks complete
- `markTaskFailed()` — user marks failed
- Stream `onDone` when status is terminal
- `cleanupRemoteSession()` — explicit user request

**Verification**: ✅ Session cleanup properly handles tmux session destruction.

---

## 8. Isolation Guarantees

| Guarantee | Status | Notes |
|-----------|--------|-------|
| Per-task tmux session | ✅ | Session name includes taskId |
| Per-task pane | ✅ | Single pane per session |
| Per-task observer | ✅ | Fresh NativeOutputObserver per execute() |
| Observer detachment ≠ task stop | ✅ | tmux session survives observer detach |
| Reconnection preserves state | ✅ | capture-pane reads current state |
| Session isolation across hosts | ✅ | Separate socket per host/user |

---

## Conclusion

Session isolation is **already sufficient**. 

No architectural changes needed for tmux session management.

Recommendation: Only document the guarantees above and add ObserverDetached/ConnectionLost events to RuntimeEventBus for visibility.
