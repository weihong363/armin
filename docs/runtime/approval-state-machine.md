# 审批状态机

> Phase 2.5 — 用显式审批生命周期提升 runtime 可靠性

## 问题

当前审批流程曾经混合了两个不同概念，并且缺少显式生命周期：

1. **原生终端审批**（CLI 交互式 prompt）：`Allow Once`、`Allow Session`、`Reject`
2. **Review 决策**（工作流决策）：`Approve`、`Request Changes`、`Ask Question`

如果二者都走同一条 `resolveApproval()` 路径，并在按钮点击后立即把状态设为 `running`，就无法确认终端动作是否真的成功。

---

## 目标状态机

### 原生终端审批

```text
                  ┌─────────────────┐
                  │  PendingApproval │  ← 从终端 prompt 检测到 NativeTerminalApproval
                  └────────┬────────┘
                           │
                    用户点击 Approve/Reject
                           │
                  ┌────────▼────────┐
                  │ ResolvingApproval│  ← 终端动作已发送，等待确认
                  └────────┬────────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
       动作成功且       Prompt        动作失败
       prompt 消失       消失       （错误/超时）
              │            │            │
     ┌────────▼───┐ ┌─────▼──────┐ ┌───▼──────────┐
     │ApprovalRslvd│ │ApprovalRslvd│ │ApprovalFailed │
     └────────────┘ └────────────┘ └──────────────┘
```

**关键规则**：只有终端动作成功且 runtime 确认后，审批才算解决。

### Review 决策

```text
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

## 数据模型

### ApprovalState（enum）

```dart
enum ApprovalState {
  none,           // 没有 pending approval
  pending,        // 已请求审批，等待用户操作
  resolving,      // 用户动作已发送，等待 runtime 确认
  resolved,       // 已确认解决
  failed,         // 审批动作失败
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

## 与 RuntimeEventBus 集成

新增事件：

```text
ApprovalRequested   — 检测到 NativeTerminalApproval
ApprovalResolving   — 用户选择了选项，动作已发送
ApprovalResolved    — 终端确认审批已解决
ApprovalRejected    — 用户明确拒绝
ApprovalFailed      — 终端动作失败
ReviewSubmitted     — 用户提交 review 决策
```

---

## 与现有流程集成

### 之前：

```text
resolveApproval() → sendFollowUp/sendKeys → _saveApprovalDecision → running
```

### 之后：

```text
resolveApproval() → publish(ApprovalResolving) → sendFollowUp/sendKeys
    ↓（等待 stream 确认）
    ↓ Approval prompt 消失或动作成功
    ↓
publish(ApprovalResolved) → running
```

---

## 状态转换规则

1. **Pending → Resolving**：只有用户动作成功发送到终端后发生
2. **Resolving → Resolved**：审批 prompt 从输出中消失，或 runtime 确认
3. **Resolving → Failed**：终端动作报错，或超时仍无确认
4. **Pending → Rejected**：用户明确拒绝；不是 `Resolving → Rejected`
5. **Resolving 是过渡态**：UI 应在该状态展示 loading/spinner
