# Legacy Logic Cleanup Checklist

> Phase 2.5 — 新 RuntimeEventBus 逻辑稳定后移除旧逻辑

## 状态

- **当前阶段**: 新旧逻辑共存（Phase 2.5 完成）
- **目标阶段**: 新逻辑稳定后，移除旧逻辑
- **触发条件**: 新 RuntimeEventBus 事件流在生产环境运行 2 周无问题

---

## 1. TaskWatcher._extractStatus() — 字符串匹配状态推断

### 旧逻辑

| 文件 | 行号 | 描述 |
|------|------|------|
| `lib/features/runtime/services/task_watcher.dart` | L56-L75 | `_extractStatus()` 通过 `contains()` 推断状态 |

```dart
// 旧逻辑 — 字符串匹配状态推断（应移除）
RuntimeTaskStatus? _extractStatus(String output) {
  final lower = output.toLowerCase();
  if (lower.contains('waiting for user') ||
      lower.contains('needs approval') ||
      lower.contains('need approval') ||
      lower.contains('waiting for your')) {
    return RuntimeTaskStatus.waitingUser;
  }
  if (lower.contains('task completed') ||
      lower.contains('completed successfully')) {
    return RuntimeTaskStatus.completed;
  }
  if (lower.contains('task failed') || lower.contains('fatal error')) {
    return RuntimeTaskStatus.failed;
  }
  if (output.trim().isEmpty) {
    return null;
  }
  return RuntimeTaskStatus.running;
}
```

### 新逻辑（替代）

- `RuntimeEventBus` 发布 `approvalRequested`, `taskCompleted`, `taskFailed` 等事件
- `ArminAppState._taskWithExecutionUpdate()` 通过 `AgentExecutionUpdate.approval`, `.result`, `.turnIdle` 等结构化字段决定状态

### 移除方案

`_extractStatus()` 保留为 last-resort fallback，但仅在 RuntimeEventBus 未覆盖的边界场景使用。移除时：
1. 将方法标记为 `@Deprecated`
2. `TaskWatcherUpdate.status` 返回 `null`
3. `BridgeRuntime.observeOutput()` 不再依赖 `update.status` 做状态转换

---

## 2. TaskWatcher._extractAction() / _extractCheckpoint() — 正则匹配摘要提取

### 旧逻辑

| 文件 | 行号 | 描述 |
|------|------|------|
| `lib/features/runtime/services/task_watcher.dart` | L31-L42 | `_extractAction()` — 取最后一行非噪音行 |
| `lib/features/runtime/services/task_watcher.dart` | L77-L86 | `_extractCheckpoint()` — 正则 `checkpoint|阶段|步骤:` |

### 新逻辑（替代）

- `OutputSummaryProvider.summarize()` 通过结构化规则（表格提取、行评分）生成摘要
- `WorkState.headline` / `WorkState.detail` 提供 UI 就绪的摘要文本

### 移除方案

保留作为 output observation 的辅助功能（不是状态权威），不直接驱动 UI 状态变更。

---

## 3. BridgeRuntime.observeOutput() — 通过 TaskWatcher 间接推断状态

### 旧逻辑

| 文件 | 行号 | 描述 |
|------|------|------|
| `lib/features/runtime/services/bridge_runtime.dart` | L55-L85 | `observeOutput()` 调用 `watcher.observe()` 后直接使用 `update.status` 做状态转换 |

```dart
// 旧逻辑 — TaskWatcher 的状态推断直接影响 RuntimeTaskSnapshot
final nextStatus = update.status ?? current.status;
final updated = current.copyWith(
  status: nextStatus,  // ← 依赖 TaskWatcher 的字符串匹配
  ...
);
_publish(_eventTypeForStatus(nextStatus), updated);
```

### 新逻辑（替代）

- `ArminAppState._bridgeNotifyExecutionUpdate()` 调用 `observeOutput()` — 应改为调用 `bridgeRuntime.notifyOutputUpdated()`
- 状态转换由 `_taskWithExecutionUpdate()` 中的结构化字段（`update.approval`, `update.result`, `update.turnIdle`）驱动

### 移除方案

1. `observeOutput()` 改为仅做数据记录（不改变 status field）
2. 移除 `_publish(_eventTypeForStatus(nextStatus), ...)` 中的状态驱动事件
3. 仅发布 `notifyOutputUpdated` 轻量事件

---

## 4. _bridgeSyncTerminalStatus() — 手动桥接同步

### 旧逻辑

| 文件 | 行号 | 描述 |
|------|------|------|
| `lib/core/services/armin_app_state.dart` | L910-L953 | 手动将 TaskStatus 映射到桥接事件 |

```dart
// 旧逻辑 — 手动 switch-case 映射 TaskStatus → BridgeRuntime 方法
void _bridgeSyncTerminalStatus(
  String taskId,
  TaskStatus status,
  DateTime now,
  String summary,
) {
  switch (status) {
    case TaskStatus.turnIdle:
    case TaskStatus.needAttention:
    case TaskStatus.needApproval:
      unawaited(bridgeRuntime.markWaitingUser(taskId, ...));
    case TaskStatus.userCompleted:
    case TaskStatus.completed:
      unawaited(bridgeRuntime.completeTask(taskId, ...));
    // ... more cases
  }
}
```

### 新逻辑（替代）

- `ArminAppState` 直接调用 `bridgeRuntime.notifyXxx()` 方法，不通过中间映射
- RuntimeEventBus 事件直接从 stream 端发出

### 移除方案

1. `_bridgeSyncTerminalStatus()` 保留直到所有调用者切换到直接调用 `bridgeRuntime.notifyXxx()`
2. 最终只保留 `_bridgeSyncTerminalStatus()` 作为向后兼容 fallback

---

## 5. ApprovalRequest — 旧审批模型（字符串 status）

### 旧逻辑

| 文件 | 行号 | 描述 |
|------|------|------|
| `lib/features/agent/parsers/approval_request.dart` | L1-L70 | `ApprovalRequest` 使用 `String status` 而非 `ApprovalState` enum |

```dart
// 旧逻辑 — 字符串状态
class ApprovalRequest {
  final String status; // 'pending', 'approved', 'rejected' — 无类型安全
  ...
}
```

### 新逻辑（替代）

- `NativeTerminalApproval` 使用 `ApprovalState` enum（`none | pending | resolving | resolved | failed`）
- `ReviewDecision` 使用 `ReviewDecisionType` enum

### 移除方案

1. 将 `ApprovalRequest.status` 迁移到 `ApprovalState`
2. `_saveApprovalDecision()` 改为存储 `NativeTerminalApproval`
3. `resolveApproval()` 改为发布 `notifyApprovalResolving/Resolved/Rejected`

---

## 6. TerminalPrompt → ApprovalRequest 包装

### 旧逻辑

| 文件 | 行号 | 描述 |
|------|------|------|
| `lib/features/agent/parsers/approval_parser.dart` | L1-L26 | `ApprovalParser` 包装 `TerminalPromptParser` 输出 |
| `lib/features/agent/services/ssh_agent_session_service.dart` | L203-L212 | `_approvalFromTerminalPrompt()` |
| `lib/features/agent/services/ssh_agent_session_service.dart` | L248-L261 | `_buildStreamingUpdate()` 同时运行两个 parser |

```dart
// 旧逻辑 — 将 TerminalPrompt 包装成 ApprovalRequest
final approval = _approvalParser.parse(observedOutput);
final terminalPrompt = _terminalPromptParser.parse(observedOutput);
final effectiveApproval = approval ??
    (isSafeMode ? null : _approvalFromTerminalPrompt(terminalPrompt));
```

### 新逻辑（替代）

- `NativeTerminalApproval` 替代 TerminalPrompt-to-ApprovalRequest 包装
- `ReviewDecision` 独立处理 workflow 决策

### 移除方案

1. `ApprovalParser` 迁移到生成 `NativeTerminalApproval`
2. `_approvalFromTerminalPrompt()` 移除，改为直接创建 `NativeTerminalApproval`
3. `AgentExecutionUpdate` 的 `approval` 字段改为 `NativeTerminalApproval?`

---

## 7. UI 直接消费 TaskStatus

### 旧逻辑

| 文件 | 描述 |
|------|------|
| `lib/features/tasks/widgets/*.dart` | Current Situation 卡片直接读取 `task.status` |
| `lib/features/history/screens/task_detail_screen.dart` | 多处 `switch (task.status)` / `_isAttentionRequired(task.status)` |
| `lib/features/tasks/screens/task_draft_screen.dart` | 状态标签直接映射 `TaskStatusLabel.label` |

### 新逻辑（替代）

- `ArminAppState.workState(taskId)` 返回 `WorkState`
- UI 应通过 `WorkState.phase` 判断需要展示什么
- `WorkState.needsAttention` 替代 `_isAttentionRequired(task.status)`
- `WorkState.statusText` 替代直接读取 `task.shortSummary`

### 移除方案

渐进式迁移：
1. 新增 `WorkState` 访问器（已完成）
2. Current Situation 卡片改为消费 `WorkState`
3. 状态标签迁移到 `WorkPhase` 映射
4. 移除对 `TaskStatus` 的直接 switch 判断

---

## 8. ArminAppState._bridgeSyncTerminalStatus() — 暂停/运行/observer 的无操作

### 旧逻辑

| 文件 | 行号 | 描述 |
|------|------|------|
| `lib/core/services/armin_app_state.dart` | L946-L951 | `running/paused/observerDetached/draft/pending` → `break` |

```dart
// 旧逻辑 — 多个状态直接忽略
case TaskStatus.running:
case TaskStatus.paused:
case TaskStatus.observerDetached:
case TaskStatus.draft:
case TaskStatus.pending:
    break;
```

### 新逻辑（替代）

- Phase 2.5 已修复：`paused` → `bridgeRuntime.pauseTask()`, `observerDetached` → `bridgeRuntime.notifyObserverDetached()`

### 移除方案

已部分完成。`running` 仍然忽略 — 因为 stream 侧进度由 `_bridgeNotifyExecutionUpdate()` 处理。验证后可移除 `running` case 的注释。

---

## 9. _bridgeNotifyExecutionUpdate() — 重型 observeOutput 调用

### 旧逻辑

| 文件 | 行号 | 描述 |
|------|------|------|
| `lib/core/services/armin_app_state.dart` | L895-L908 | 每次 stream update 都调用 `bridgeRuntime.observeOutput()` |

```dart
// 旧逻辑 — 每次输出都触发 TaskWatcher 解析 + 持久化
void _bridgeNotifyExecutionUpdate(TaskSession task, String rawOutput) {
  unawaited(bridgeRuntime.observeOutput(
    taskId: task.id,
    capturedOutput: rawOutput,
    now: DateTime.now(),
  ));
}
```

### 新逻辑（替代）

- 高频 progress（无状态变更）: `bridgeRuntime.notifyOutputUpdated()` — 轻量事件
- 状态变更事件: 直接通过 `notifyXxx()` 方法

### 移除方案

1. `_bridgeNotifyExecutionUpdate()` 保留但内部改为仅在高频 progress 时调用 `notifyOutputUpdated()`
2. 状态变更路径已由其他 notify 方法覆盖，可移除 `observeOutput` 中的状态变更逻辑

---

## 10. OutputSummaryProvider 中的 TerminalPrompt 块过滤

### 旧逻辑

| 文件 | 行号 | 描述 |
|------|------|------|
| `lib/features/tasks/services/output_summary_provider.dart` | L501-L593 | `_removeTerminalPromptBlocks()` — 手动过滤终端提示块 |
| `lib/features/tasks/services/output_summary_provider.dart` | L569-L577 | 硬编码的 TerminalPrompt 启动检测 |

```dart
// 旧逻辑 — 硬编码字符串匹配
bool _isTerminalPromptStart(String line) {
  return lower == 'asking user' ||
      lower.startsWith('allow this command to run') ||
      lower.startsWith('allow execution of') ||
      ...
}
```

### 新逻辑（替代）

- `TerminalPromptParser` 已能结构化检测终端提示
- `NativeTerminalApproval` 携带已解析的审批信息
- OutputSummaryProvider 应接收已处理的输出（不含 prompt 块）

### 移除方案

在 SSH 层（`_buildStreamingUpdate`）预处理后传递 cleaned output，移除 OutputSummaryProvider 中的重复检测。

---

## 11. AgentExecutionUpdate 字段 — 旧字段与新模型并存

### 旧逻辑

| 文件 | 行号 | 描述 |
|------|------|------|
| `lib/features/agent/services/agent_session_service.dart` | L50-L74 | `AgentExecutionUpdate` 同时携带 `approval` 和 `terminalPrompt` |

```dart
class AgentExecutionUpdate {
  final ApprovalRequest? approval;       // 旧
  final TerminalPrompt? terminalPrompt;  // 旧
  final bool turnIdle;
  final bool needsAttention;
  ...
}
```

### 新逻辑（替代）

```dart
class AgentExecutionUpdate {
  final NativeTerminalApproval? nativeApproval; // 新
  final ReviewDecision? reviewDecision;          // 新
  final bool turnIdle;
  ...
}
```

### 移除方案

1. 新增 `nativeApproval` 和 `reviewDecision` 字段
2. 旧字段标记 `@Deprecated`
3. SSH 层迁移到新字段
4. 移除旧字段

---

## 移除优先级

| 优先级 | 项目 | 影响范围 | 风险 |
|--------|------|---------|------|
| 🔴 P0 | `_extractStatus()` 状态推断 | BridgeRuntime, TaskWatcher | 高 — 核心状态路径 |
| 🔴 P0 | `observeOutput()` 状态驱动 | BridgeRuntime | 高 — 核心状态路径 |
| 🟡 P1 | `ApprovalRequest` 字符串 status | Approval 流程 | 中 — 审批可靠性 |
| 🟡 P1 | TerminalPrompt → Approval 包装 | SSH 层 | 中 — 审批可靠性 |
| 🟢 P2 | `_bridgeSyncTerminalStatus()` 手动映射 | AppState | 低 — 内部实现 |
| 🟢 P2 | UI 直接消费 TaskStatus | UI 层 | 低 — UI 表现 |
| 🟢 P3 | OutputSummaryProvider 重复检测 | 摘要层 | 低 — 功能正确 |

---

## 移除验证标准

每个旧逻辑的移除必须满足：

1. ✅ 新 RuntimeEventBus 事件流已覆盖该场景
2. ✅ 相关测试在移除后仍然通过
3. ✅ Flutter analyze 0 error
4. ✅ 旧逻辑已无调用者（或调用者已迁移）

---

## 当前共存状态

Phase 2.5 实现了新旧逻辑的**安全共存**：

```
新逻辑                          旧逻辑
══════════                      ══════════
RuntimeEventBus (25 events)     TaskWatcher._extractStatus()
bridgeRuntime.notifyXxx()       _bridgeSyncTerminalStatus()
ApprovalState enum              ApprovalRequest.status (String)
WorkState                       TaskStatus (直接消费)
NativeTerminalApproval          TerminalPrompt → ApprovalRequest
```

两个系统同时运行，新逻辑已通过 323 个测试验证。旧逻辑可在新逻辑稳定后按优先级逐步移除。
