# Bridge Runtime Long-Term Architecture

> Long-term direction for making Armin a task-centric Agent runtime rather than
> a mobile remote-control surface.

## Problem

The current Phase 2 implementation still treats `tmux capture-pane` output as a
major source of runtime truth. This is useful for observation, but it is not a
reliable completion signal.

`capture-pane` can tell Armin what is visible in the terminal. It cannot prove:

- whether the Agent process is still thinking
- whether a child command is still running
- whether the TUI has hidden or rewritten a thinking block
- whether no visible output means the turn is complete
- whether a permission prompt has actually disappeared after the user responds

The most important rule is:

```text
No visible output is not completion.
```

Pane stability may mean `outputQuieting` or `no visible update`, but it must not
alone produce `turnIdle`, a result card, TTS playback, or task completion.

## Target Architecture

Long term, the Flutter app should not own the authoritative runtime state. The
app is the client surface: it creates tasks, reviews progress, adds context, and
sends control decisions.

The authoritative runtime should move toward a durable bridge layer:

```text
Armin App
    ↓
Remote Bridge Runtime
    ↓
SQLite Task/Event Store
    ↓
Task Watcher
    ↓
tmux / Codex / Qoder / other CLI Agent
```

The existing Flutter-process Bridge Runtime is a transition step. It is useful
for proving contracts, reducers, and UI consumption, but it is not the final
durability boundary because it dies with the app process.

## Persistence Boundary

SQLite is the long-term persistence boundary for runtime state.

Runtime state must not depend only on in-memory Flutter objects, transient SSH
streams, or terminal screen snapshots. The durable store should own at least:

- `tasks`
- `turns`
- `runtime_events`
- `work_state`
- `approval_state`
- `session_bindings`
- `last_seen_offsets`
- `deliverables`
- `timeline_events`
- `watcher_checkpoints`

The app can cache these records in memory, but it must be able to rebuild its
view from SQLite after restart, reconnect, or watcher recovery.

## Runtime Events as State Authority

Task state should be reduced from durable runtime events, not inferred directly
by the UI from terminal text.

Primary event examples:

- `TASK_STARTED`
- `TASK_PROGRESS`
- `OUTPUT_UPDATED`
- `TASK_WAITING_USER`
- `APPROVAL_REQUESTED`
- `APPROVAL_RESOLVING`
- `APPROVAL_RESOLVED`
- `APPROVAL_FAILED`
- `DELIVERABLE_UPDATED`
- `TASK_COMPLETED`
- `TASK_FAILED`
- `SESSION_LOST`
- `OBSERVER_DETACHED`
- `OBSERVER_ATTACHED`

`TaskStatus`, `WorkState`, `ApprovalState`, timeline rows, result cards, and TTS
should be derived from this event stream and persisted state.

## Watcher Contract

The watcher may keep using `tmux capture-pane` in the near term, but only as an
input source.

Allowed watcher outputs:

- latest visible output
- incremental output slices
- last seen offset/hash
- detected approval prompt
- detected terminal option prompt
- detected progress/action text
- detected strong completion/failure markers

Disallowed watcher behavior:

- treating stable output as completion
- turning quiet output directly into `turnIdle`
- producing deliverables from prompt echoes or thinking-only output
- resolving approvals without confirmation that the prompt disappeared or work
  moved forward

## CLI Adapters

CLI-specific behavior belongs in adapters, not in the generic watcher.

Adapters should identify:

- approval prompt formats
- waiting-for-user prompts
- explicit completion markers
- failure markers
- running/thinking markers
- output sections that are display-only

Codex, Qoder, Claude, and future CLIs may share generic structural parsers, but
their personalized markers should stay in adapter-specific configuration.

## Adapter Invariants

Adapters do not eliminate text parsing. Codex and Qoder are TUI programs, so raw
text is the unavoidable observation input. The long-term rule is narrower and
more important:

```text
Parse text once, parse only new text, then persist events.
```

Required adapter invariants:

- Adapter input must be delta-based: `last_offset` / `last_event_id` /
  `baseline_hash` defines the current observation window.
- Full `capture-pane` snapshots are allowed for audit, recovery, and manual
  debugging, but they must not directly emit state-changing events.
- State-changing events require new evidence after the current baseline.
- Old exit markers, approval prompts, terminal option prompts, thinking text,
  prompt echoes, and previous deliverables are historical evidence only.
- Reducers must deduplicate events by offset, event id, marker count, or content
  fingerprint before changing `WorkState`, `ApprovalState`, turn state, result
  visibility, or TTS eligibility.
- UI and TTS consume event-linked payloads such as `ApprovalRequested.question` or
  `TurnCompleted.deliverable`, not arbitrary task-level historical summaries.

This prevents attach/reconnect from replaying stale terminal residue as a new
approval request, new process exit, new turn result, or new speech event.

## Approval Lifecycle

Native terminal approval must have a durable lifecycle:

```text
pending -> resolving -> resolved
                    \-> failed
```

After the user taps Allow/Reject, Armin should not immediately assume the remote
Agent accepted the choice. The runtime should enter `resolving` and wait for one
of these confirmations:

- the approval prompt disappears from the latest watcher output
- new Agent output appears after the selected option is sent
- the adapter reports a confirmed state transition
- the send action fails or times out, producing `failed`

This prevents the app from showing `running` while the remote Agent is still
blocked on `Apply this change?`.

## Turn Idle Contract

`turnIdle` is not a synonym for quiet output.

It should be emitted only from stronger signals, such as:

- explicit waiting-for-next-instruction prompt
- explicit Agent-ready prompt
- confirmed approval/waiting-user state
- adapter-recognized completed turn output
- process exit where appropriate for the selected Agent mode

Long-running thinking, hidden TUI updates, child commands, and output quieting
must remain `running` or `outputQuieting`.

## Deployment Evolution

### Phase A: Flutter Runtime + SQLite

- Add SQLite-backed task/event/runtime stores. Baseline implemented by
  `SQLiteRuntimePersistenceStore`.
- Keep Bridge Runtime in Flutter while making event reduction durable.
- Rehydrate runtime snapshots and `WorkState` from SQLite after app restart.
- Stop using pane stability as a completion signal.

### Phase B: Disconnect / Reconnect Replay

- Persist watcher offsets, snapshot hashes, and last event ids.
- On reconnect, replay missed remote output into the event reducer.
- Treat capture-pane resync as reconciliation, not source-of-truth guessing.

### Phase C: Remote Runtime Daemon

- Move watcher, reducer, approval lifecycle, and SQLite store to the remote
  machine.
- Run beside or inside the tmux/session environment.
- Mobile app talks to the daemon through SSH/RPC/API and only renders durable
  runtime state.

## Non-Goals

This architecture is not:

- a multi-agent scheduler
- a workflow engine
- a fork/join runtime
- an automatic merge/commit system
- a Slack/Feishu replacement
- a generic terminal emulator

The goal is narrower: make task execution state durable, event-driven, and
reliable after the user leaves the app or the terminal output goes quiet.
