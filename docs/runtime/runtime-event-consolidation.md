# Armin Runtime Event Architecture Audit

> Phase 2.5 — Consolidation toward event-driven runtime state

Long-term runtime durability and remote-daemon direction are tracked in
[Bridge Runtime Long-Term Architecture](bridge-runtime-long-term-architecture.md).

## 1. Current RuntimeEventBus Responsibilities

**Location**: `lib/features/runtime/services/runtime_event_bus.dart`

**Current Event Types** (7):
- `taskCreated`
- `taskStarted`
- `taskProgress`
- `taskWaitingUser`
- `taskCompleted`
- `taskFailed`
- `taskCancelled`

**Missing Events** (identified gap):
- `taskPaused` / `taskResumed` — No dedicated events; pause/resume handled via `_saveControlledTask` without bridge notification
- `ObserverAttached` / `ObserverDetached` — Observer lifecycle not reflected in event bus
- `ConnectionLost` / `ConnectionRestored` — SSH disconnection handled at stream level only
- `ApprovalRequested` / `ApprovalResolved` / `ApprovalRejected` — Approval events now flow through `RuntimeEventBus`
- `OutputUpdated` — Only `taskProgress` is emitted for output changes
- `DeliverableUpdated` — No deliverable-level events exist

**Integration Points**:
- `ArminAppState` owns the `RuntimeEventBus` instance and exposes `runtimeEvents` stream to UI
- `BridgeRuntime` publishes events on state transitions via `_publish()`
- `ArminAppState._bridgeSyncTerminalStatus()` maps TaskStatus to event types

**Risk**: Event bus is incomplete — many state changes happen outside its visibility.

---

## 2. Current TaskWatcher Responsibilities

**Location**: `lib/features/runtime/services/task_watcher.dart`

**Current Responsibilities**:
1. **Offset tracking** — `_lastOffsets` map per taskId
2. **Incremental output extraction** — `capturedOutput.substring(safeOffset)`
3. **Action extraction** — Last non-noise line (truncated to 120 chars)
4. **Progress extraction** — Regex `(\d{1,3})\s*%` pattern matching
5. **Status inference** — String matching on output:
   - `contains('waiting for user')` / `contains('needs approval')` → `waitingUser`
   - `contains('task completed')` / `contains('completed successfully')` → `completed`
   - `contains('task failed')` / `contains('fatal error')` → `failed`
   - Otherwise → `running`
6. **Checkpoint extraction** — Regex on `checkpoint:|阶段:|步骤:`
7. **Noise filtering** — Governance lines, prompt echo, tmux/ssh prefixes

**Risk**: Status inference via `contains()` string matching is fragile and produces false positives/negatives. This is explicitly called out as something that should become a fallback, not primary state authority.

---

## 3. Current RuntimeSessionManager Responsibilities

**Location**: `lib/features/runtime/services/runtime_session_manager.dart`

**Current Responsibilities**:
1. **Session creation/restoration** — `createOrRestore()` with dedup by `projectPath + tmuxSessionName`
2. **Task-to-session mapping** — `attachTask()` adds taskId to session's taskIds list
3. **Status lifecycle** — `active → detached → destroyed`
4. **Session ID generation** — Normalized from `projectPath::tmuxSessionName`

**Session States**:
- `active` — Session is running
- `detached` — Observer disconnected (but tmux session persists)
- `destroyed` — Session explicitly cleaned up

**Risk**: Session manager is memory-only — no persistence across app restarts.

**Long-term boundary**: session and task runtime state must be persisted in
SQLite. The Flutter-process session manager is a transition layer, not the
authoritative durability boundary.

---

## 4. Current Approval Flow

**Location**: Spread across `ArminAppState`, `TerminalPromptParser`

**Current Flow**:
```
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

**Key Observations**:
- **Approval no longer wraps TerminalPrompt**: native terminal prompts now map directly to `NativeTerminalApproval`; workflow-level approval events remain modeled separately
- **Explicit approval lifecycle**: approval state is expressed by `ApprovalState`, including `pending`, `resolving`, `approved`, `rejected`, and `failed`
- **ResolvingApproval state exists**: after button press, UI can represent that terminal action was sent and confirmation is pending
- **Desync risk is handled by reconcile**: if terminal action fails or the remote prompt remains, refresh/reconcile can restore the pending approval state

---

## 5. Current Observer Lifecycle

**Location**: `lib/features/agent/services/native_output_observer.dart`

**Observer States**:
- `running` — Active output detected
- `outputQuieting` — No new meaningful output
- `turnIdle` — Output quiet for >= idleThreshold
- `needAttention` — Approval/confirm/permission keywords
- `reconnecting` — Reconnection keywords detected
- `runtimeLost` — Reconnection exceeded reconnectThreshold

**Observer ↔ Task State Mapping**:
- `running` → TaskStatus.running
- `turnIdle` → TaskStatus.turnIdle
- `needAttention` → TaskStatus.needAttention
- `runtimeLost` → TaskStatus.runtimeLost
- `outputQuieting` → TaskStatus.running (no status change)
- `reconnecting` → TaskStatus.running (no status change)

**Risk**: Observer state → Task state mapping is implicit in `_taskWithExecutionUpdate()`, not a formal mapping. Observer detachment (SSH disconnect) directly sets `TaskStatus.observerDetached` — observer and task state are coupled.

---

## 6. Current State Transition Logic

**Location**: Primarily `ArminAppState`

**State Transitions**:
```
draft → pending → running → turnIdle / needAttention / needApproval
                  ↓              ↓
               observerDetached  userCompleted / userFailed
                  ↓
               running (reconnect)
                  
running → runtimeLost / failed / stopped
turnIdle / needAttention → running (continue/followUp)
```

**Bridge Synchronization**:
- `_bridgeEnsureTaskCreated()` — On task load/save
- `_bridgeNotifyExecutionStarted()` — On stream start, calls `bridgeRuntime.startTask()`
- `_bridgeNotifyExecutionUpdate()` — On each stream update, calls `bridgeRuntime.observeOutput()`
- `_bridgeSyncTerminalStatus()` — On status changes, calls `markWaitingUser/completeTask/failTask/cancelTask`
- `_bridgeSyncStreamStatus()` — On stream-side status changes (not via _saveControlledTask)

**Risk**: Two parallel state tracks exist — TaskSession (UI-oriented) and RuntimeTaskSnapshot (bridge-oriented). They are synchronized manually through the bridge methods above, but synchronization is not guaranteed in all paths.

---

## 7. Existing Parser Dependencies

**Parsers** (`lib/features/agent/parsers/`):
- `TerminalPromptParser` — Detects interactive CLI prompts (numbered options with cursor)
- `AgentOutputCleaner` — Cleans thinking blocks, ANSI codes, noise

**Current Dependencies**:
- SSH stream → `_buildStreamingUpdate()` → `TerminalPromptParser`, `NativeOutputObserver`
- TaskWatcher → `_extractStatus()`, `_extractProgress()`, `_extractAction()`, `_extractCheckpoint()` — all regex/contains based
- OutputSummaryProvider → `_removeTerminalPromptBlocks()`, `_semanticLines()`, various pattern matching
- ArminAppState → `_taskWithExecutionUpdate()` consumes parsed results

**Risk**: Parsers operate independently — no shared parsing pipeline or priority ordering.

---

## 8. Existing tmux Dependencies

**Location**: `lib/features/agent/services/ssh_agent_session_service.dart`

**tmux Usage**:
- Per-task tmux session: `tmux -L <name> new-session -d ...`
- Output capture: `tmux -L <name> capture-pane -t ... -p -S - -E -`
- Command sending: `tmux -L <name> send-keys -t ... "..." Enter`
- Session existence check: `tmux -L <name> has-session -t ...`
- Session kill: `tmux -L <name> kill-session -t ...`

**tmux Session Name**:
- Source: `HostConfig.tmuxSessionName` (default: `armin`)
- Per-task isolation via tmux socket name (`-L`) and session name pattern

**Risk**: tmux is both transport and indirect state evidence — the spec says it should be transport only.

**Additional risk**: stable `capture-pane` output can be mistaken for `turnIdle`
even while the Agent is still thinking, running a child process, or hiding TUI
updates. Pane stability should mean `outputQuieting` or `no visible update`,
not completion.

---

## 9. Existing Runtime Risks (Summary)

| Risk | Severity | Impact |
|------|----------|--------|
| Approval desync after button press | High | Terminal action may fail silently |
| TaskWatcher `contains()` state inference | Medium | False state transitions from output keywords |
| No explicit approval lifecycle | Medium | Can't distinguish "pending" from "resolving" |
| Observer ↔ Task state coupling | Medium | ObserverDetached implies TaskPaused in some paths |
| Bridge sync gaps (pause/resume) | Medium | Bridge unaware of paused/resumed state |
| Incomplete RuntimeEventBus | Low | UI can't fully consume events |
| SessionManager memory-only | Low | No crash recovery for session state |
| Parallel state tracks (TaskSession + RuntimeTaskSnapshot) | Low | Manual sync prone to drift |
| Pane stability treated as turn completion | High | Result card and TTS can trigger while remote Agent is still running |

---

## Consolidation Target

After Phase 2.5:

```
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

TaskWatcher remains as compatibility layer:
```
RuntimeEventBus (Primary: event-driven)
    ↓
TaskWatcher (Secondary: output observation + legacy fallback)
    → progress extraction
    → summary extraction
    → audit compatibility
```

String matching becomes last resort fallback.

Runtime state should ultimately be reduced from durable events persisted in
SQLite. `TaskWatcher._extractStatus()` and `tmux capture-pane` snapshots remain
compatibility inputs only; they must not be the authority for completion,
approval resolution, or result availability.
