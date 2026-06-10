# Runtime Feature

Phase 2.5 runtime code defines the lightweight Bridge Runtime boundary.

It is not a multi-agent scheduler, workflow engine, cloud sync layer, or push
notification service.

Current responsibilities:

- keep task lifecycle snapshots separate from terminal/session details
- publish task lifecycle events through an internal event bus
- manage named runtime sessions independently from mobile screens
- track incremental watcher offsets for long-running output
- expose checkpoint fields for future recovery work

The existing `AgentSessionService` remains responsible for real SSH/tmux/Codex
execution. The runtime layer is the bridge-facing contract that future work can
use to move observation and lifecycle state out of the mobile UI.
