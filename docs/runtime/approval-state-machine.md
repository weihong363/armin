# Approval State Machine

> Phase 2.5 — Explicit approval lifecycle for runtime reliability

## Problem

Current approval flow conflates two distinct concepts and lacks an explicit lifecycle:

1. **Native Terminal Approval** (CLI interactive prompts) — "Allow Once", "Allow Session", "Reject"
2. **Review Decisions** (workflow decisions) — "Approve", "Request Changes", "Ask Question"

Both flow through the same `resolveApproval()` path, with status immediately set to `running` after button press — no verification that the terminal action succeeded.

---

## Proposed State Machine

### Native Terminal Approval

```
                  ┌─────────────────┐
                  │  PendingApproval │  ← NativeTerminalApproval detected from terminal prompt
                  └────────┬────────┘
                           │
                    User presses Approve/Reject
                           │
                  ┌────────▼────────┐
                  │ ResolvingApproval│  ← Terminal action sent, awaiting confirmation
                  └────────┬────────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
     Action succeeds   Prompt    Action fails
     & prompt gone    disappears  (error/timeout)
              │            │            │
     ┌────────▼───┐ ┌─────▼──────┐ ┌───▼──────────┐
     │ApprovalRslvd│ │ApprovalRslvd│ │ApprovalFailed │
     └────────────┘ └────────────┘ └──────────────┘
```

**Key rule**: Approval only resolves when terminal action succeeds AND runtime confirms.

### Review Decision

```
                  ┌─────────────────┐
                  │  PendingReview   │
                  └────────┬────────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
           Approve    RequestChanges  AskQuestion
              │            │            │
     ┌────────▼───┐ ┌─────▼──────┐ ┌───▼──────────┐
     │ReviewApprvd │ │ChangesRqstd│ │QuestionAsked  │
     └────────────┘ └────────────┘ └──────────────┘
```

---

## Data Model

### ApprovalState (enum)

```dart
enum ApprovalState {
  none,           // No pending approval
  pending,        // Approval requested, awaiting user action
  resolving,      // User action sent, awaiting runtime confirmation
  resolved,       // Approval confirmed resolved
  failed,         // Approval action failed
}
```

### NativeTerminalApproval

```dart
class NativeTerminalApproval {
  final String id;
  final String taskId;
  final String question;
  final List<TerminalPromptOption> options;
  final ApprovalState state;
  final DateTime createdAt;
  final DateTime? stateChangedAt;
  final String? selectedOptionKey;
  final String? failureReason;
}
```

### ReviewDecision

```dart
enum ReviewDecisionType { approve, requestChanges, askQuestion }

class ReviewDecision {
  final String id;
  final String taskId;
  final ReviewDecisionType type;
  final String message;
  final DateTime createdAt;
}
```

---

## Integration with RuntimeEventBus

New events:
```
ApprovalRequested   — NativeTerminalApproval detected
ApprovalResolving   — User chose an option, action sent
ApprovalResolved    — Terminal confirmed resolution
ApprovalRejected    — User explicitly rejected
ApprovalFailed      — Terminal action failed
ReviewSubmitted     — User submitted review decision
```

---

## Integration with Existing Flow

### Before (current):
```
resolveApproval() → sendFollowUp/sendKeys → _saveApprovalDecision → running
```

### After (proposed):
```
resolveApproval() → publish(ApprovalResolving) → sendFollowUp/sendKeys
    ↓ (wait for stream confirmation)
    ↓ Approval prompt disappears OR action succeeds
    ↓
publish(ApprovalResolved) → running
```

---

## Transition Rules

1. **Pending → Resolving**: Only when user action is successfully sent to terminal
2. **Resolving → Resolved**: When approval prompt disappears from output OR runtime confirms
3. **Resolving → Failed**: If terminal action errors or times out without confirmation
4. **Pending → Rejected**: If user explicitly rejects (not "Resolving → Rejected")
5. **Resolving state is transitory**: UI should show loading/spinner during this state
