# Runtime Feature

Phase 2.5 runtime code defines the lightweight Bridge Runtime boundary.

It is not a multi-agent scheduler, workflow engine, cloud sync layer, or push
notification service.

Current responsibilities:

- keep task lifecycle snapshots separate from terminal/session details
- publish task lifecycle events through an internal event bus
- persist runtime task snapshots, runtime events, and UI-facing `WorkState`
  through the default SQLite runtime store
- manage named runtime sessions independently from mobile screens
- track incremental watcher offsets for long-running output
- expose checkpoint fields for future recovery work

The existing `AgentSessionService` remains responsible for real SSH/tmux/Codex
execution. The runtime layer is the bridge-facing contract that future work can
use to move observation and lifecycle state out of the mobile UI.

Long-term direction:

- Runtime state is authoritative only after it is durable. The persistence
  boundary should be SQLite, covering tasks, turns, runtime events, work state,
  approval state, session bindings, watcher offsets, deliverables, and timeline
  events.
- Phase A uses a Flutter-process Bridge Runtime with
  `SQLiteRuntimePersistenceStore`; this improves app-restart recovery but does
  not yet survive remote daemon loss or provide full disconnect replay.
- The Flutter-process runtime is a transition implementation. Future work should
  either support reliable disconnect/reconnect replay from SQLite or move the
  runtime to a remote daemon beside the tmux/CLI session.
- `tmux capture-pane` and watcher snapshots are observation inputs. They must not
  directly decide task completion, result availability, or approval resolution.
- `WorkState` and `ApprovalState` should be reduced from durable runtime events,
  not inferred independently by UI screens.

See `docs/runtime/bridge-runtime-long-term-architecture.md` for the full target.
