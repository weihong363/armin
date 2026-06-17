# Legacy Logic Cleanup Checklist

> Phase 2.5 → Phase A 过渡期 — 旧逻辑向新 Runtime 架构迁移

## 状态

- **当前阶段**: 新旧逻辑共存（Phase 2.5 → Phase A 过渡中，测试需以当前分支 `flutter test` 为准）
- **目标阶段**: 旧逻辑逐步移除，新 RuntimeEventBus + WorkState + ApprovalState 成为唯一权威
- **迁移原则**: 从防御层向核心收敛，每步只切换一个调用者，全链路验证后进入下一步
- **核心约束**: 所有状态触发型检测必须基于当前观察基线之后的新增证据
- **持久化边界**: Phase A 以 SQLite Runtime Store 为边界；Flutter 进程内 Runtime 可重建，但状态 reducer 的结果必须可从 SQLite 恢复

---

## 圈号 → 原始项对照表

> ①–⑫ 为旧版文档第 1–12 项的原始编号，⑬–⑭ 为迁移期间新增的补强项。执行顺序中引用圈号即指下表中对应的原始项。

| 圈号 | 原始项 | 当前归属 Step |
|:---:|------|:---:|
| ① | `TaskWatcher._extractStatus()` — 字符串匹配状态推断 | Step 8（已移除 ✅） |
| ② | `TaskWatcher._extractAction() / _extractCheckpoint()` — 正则匹配摘要提取 | 辅助功能，保留不驱动状态 |
| ③ | `BridgeRuntime.observeOutput()` — TaskWatcher 间接推断状态 | Step 8（已去状态化 ✅） |
| ④ | `_bridgeSyncTerminalStatus()` — 手动桥接同步 | Step 5（已移除 ✅） |
| ⑤ | `ApprovalRequest` — 旧审批模型（字符串 status） | Phase 5 后已物理移除 ✅ |
| ⑥ | `TerminalPrompt → ApprovalRequest` 包装 | 已替换为 `TerminalPrompt → NativeTerminalApproval` ✅ |
| ⑦ | UI 直接消费 `TaskStatus` | Step 9（一等 UI 已迁移，二级 fallback 保留 ✅） |
| ⑧ | `_bridgeSyncTerminalStatus()` 暂停/运行/observer 无操作 | Step 5（已合并移除 ✅） |
| ⑨ | `_bridgeNotifyExecutionUpdate()` — 重型 observeOutput 调用 | Step 4（已轻量化 ✅） |
| ⑩ | `OutputSummaryProvider` 中的 TerminalPrompt 块过滤 | Step 3（已完成 ✅） |
| ⑪ | `AgentExecutionUpdate` 旧字段与新模型并存 | Step 7（生产主路径已迁移，旧字段仅兼容输入 ✅） |
| ⑫ | Attach/Reconnect 解析历史残留 | Step 0（已完成 ✅） |
| ⑬ | 结果/TTS 同源门禁 | Step 1（新增补强，已完成 ✅） |
| ⑭ | 运行时限制分类门禁 | Step 2（新增补强，已完成 ✅） |

---

## 当前不足与补强方向

这份清单原先偏重“删旧代码”，但近期问题表明，迁移前还需要明确几条行为门禁，否则迁到新 Runtime 后旧问题会被重新实现：

1. **状态分类不能把运行时限制当成用户输入**
   - `Credits exhausted` / `usage limit` 属于运行时限制，不是普通 `needAttention`。
   - 若限制信息前已有本轮交付性 `▪ ...` 输出，应保留 deliverable 并进入 `turnIdle` / 可继续状态。
   - 若没有任何交付性输出，才进入需要处理的运行时问题状态，文案也不应是 `Needs Input`。

2. **结果卡片和 TTS 必须同源**
   - 结果卡片、手动朗读、自动 TTS 都应使用同一个“latest turn deliverable source”。
   - 优先级：当前 turn scoped raw output → scoped cleaned output → event-linked result payload。
   - 禁止从旧 `task.summary`、初始 prompt、旧 turn summary 或 reconnect snapshot 生成新的结果/TTS。

3. **UI 不应被 Runtime 事件抢占手势**
   - 结果出现、App resume、progress event 都不能强制切到产出 tab 或重置用户滚动。
   - 只有用户显式点击“查看结果/产出”时才切 tab。

4. **probe / refresh / reconcile 只能做状态校准**
   - probe 可以发现远端新证据，但不能把旧 pane 残留重新归约为当前事件。
   - full capture 只能用于审计、恢复和人工刷新；若要改变状态，必须经过 marker count、offset、event id 或 fingerprint 去重。

5. **Adapter 可以解析文本，但 parser 位置必须集中**
   - Codex / Qoder 仍是 TUI，文本 → 事件不可避免。
   - 问题不在“有解析”，而在解析分散在 SSH 脚本、Dart parser、summary fallback、UI/TTS 多处。
   - 迁移目标是：Adapter/Watcher 负责文本解析，Runtime reducer 负责状态归约，UI/TTS 只消费归约后的事件/状态/结果。

---

## 迁移收益

| 维度 | 迁移前 | 迁移后 |
|------|--------|--------|
| 状态权威 | 分散于 SSH 脚本 grep + Dart parser + `_extractStatus` 三处 | `RuntimeEventBus` → reducer 单一路径 |
| 文本残留污染 | 旧 exit marker / approval prompt 可被误判为当前状态 | 增量证据原则：只在新增文本中触发状态 |
| 审批模型 | `String status`（`'pending'` / `'approved'`），无类型安全 | `ApprovalState` enum，编译期保证 |
| 断线恢复 | 重新 capture-pane 全量重解析 | `last_offset` / `last_event_id` 增量恢复 |
| TTS 播报源 | 可回退到 `task.summary` / 初始提示词 | 仅播 event-linked payload |
| App 职责 | 直接判断任务完成 | 只发 command，Runtime 负责状态归约 |

---

## 执行顺序

> 注意：顺序 ≠ 旧 P0–P3 优先级。正确的迁移路径是从防御层向核心收敛。

```
Step 0: ⑫ 增量证据约束（新增保护网，不移除任何旧逻辑）
Step 1: ⑬ 结果/TTS 同源门禁（latest turn deliverable source）
Step 2: ⑭ 运行时限制分类门禁（quota / usage limit）
Step 3: ⑩ P3  OutputSummaryProvider 重复检测
Step 4: ⑨ P2  _bridgeNotifyExecutionUpdate 轻量化
Step 5: ④+⑧ P2  _bridgeSyncTerminalStatus 适配层清理
Step 6: ⑥+⑤ P1  TerminalPrompt → NativeTerminalApproval 包装 → ApprovalRequest 移除
Step 7: ⑪ P1  AgentExecutionUpdate 字段迁移
Step 8: ③+① P0  observeOutput 去状态化 → _extractStatus 移除
Step 9: ⑦ P2  UI 消费 TaskStatus → WorkState
```

---

## Step 0: ⑫ 增量证据约束 — 必须先做

### 目标

给所有旧 parser / grep 加一道保护门：attach/reconnect 后，只有当前观察基线之后的新增文本才能触发状态变更。不移除任何旧逻辑，只加约束。

### 改动范围

- `SSHAgentSessionService._ExecutionOutputState`：增加 `baselineHash` / `hasNewDelta` 状态位
- `SSHAgentSessionService._buildStreamingUpdate()`：streaming 中 parser 结果只在有 delta 时传播
- `SSHAgentSessionService.execute()` 的 `whenComplete`：无新增 snapshot 时，`approval` / `terminalPrompt` 仅记日志不驱动 `needsAttention`

### 风险与应对

| 风险 | 可能性 | 应对 |
|------|:---:|------|
| `hasNewDelta` 状态位未正确维护，pipe 流延迟导致误屏蔽合法新 prompt | 低 | 先在测试中验证 pipe 流的 delta 检测逻辑；`hasNewDelta` 使用 hash 比较而非时间戳 |
| `whenComplete` 中跳过 parser 导致合法 follow-up 的审批提示被静默 | 低 | 只有 `attachOnly && !hasNewDelta` 时才跳过，非 attach 模式不受影响 |

### 验证标准

- [x] `ssh_agent_session_service_test`：attach-only 初始 pane 有旧 exit marker / approval marker，无新增时不应触发 break
- [x] `armin_app_state_task_control_test`：follow-up 后服务端只返回旧 prompt 残留，task 不应变为 `needAttention`
- [x] `probeRemoteState`：首次看到旧 exit marker 只建立计数基线，不触发 refresh
- [x] 非 attach 模式行为不变（`flutter test` 全量回归）

---

## Step 1: ⑬ — 结果/TTS 同源门禁

### 目标

在继续迁移前，先固定“结果从哪里来”的行为契约。后续 Runtime reducer、UI、TTS 都必须复用同一条 latest turn deliverable source，避免 UI 显示一个结果、TTS 播另一个结果。

### 改动范围

- `TurnOutputSlicer`：保留 turn-scoped raw / cleaned 输出能力
- `TaskDetailScreen`：结果卡片优先使用 scoped raw output，再回退 scoped cleaned output
- `TaskSpeechPolicy`：自动播报使用同一 source，不再优先 fallback 到旧 `task.summary`
- `TaskNeedsPanel` 手动读结果：与结果卡片同源

### 风险与应对

| 风险 | 可能性 | 应对 |
|------|:---:|------|
| raw output 中含 TUI chrome，结果卡片出现噪声 | 中 | raw 只作为 source，仍交给 `OutputSummaryProvider` / `AgentOutputCleaner` 清洗 |
| cleaned output 曾经比 raw 更干净，改 raw 优先导致摘要质量波动 | 中 | 仅在 scoped raw 非空时使用；保留 cleaned fallback；用真实 `▪` 输出回归 |
| TTS 播报长文本过长 | 低 | 当前策略是播显示卡片全文；后续引入独立 speech summarizer 前不得牺牲结果完整性 |

### 验证标准

- [x] 后续 turn 的 `cleanedOutput` 是旧片段，但 `rawOutput` 有最终 `▪ ...` 时，结果卡片显示最终结果
- [x] 自动 TTS 使用 latest raw turn output，不播旧 summary / prompt / thinking
- [x] App resume 不强制切到产出 tab，不抢用户滚动和 tab 切换

---

## Step 2: ⑭ — 运行时限制分类门禁

### 目标

`Credits exhausted` / `usage limit` / `quota exhausted` 不能一律进入 `needAttention`。运行时限制前若已有本轮 deliverable，应保留结果并进入可继续状态；没有 deliverable 时才提示用户处理运行时问题。

### 改动范围

- `NativeOutputObserver`：将 quota 判断拆成“有 deliverable”和“无 deliverable”两类
- `ArminAppState._taskWithExecutionUpdate()`：`turnIdle + done + deliverable` 写入 task summary / turn output，不再写入 `TaskResult`
- `OutputSummaryProvider`：继续过滤 quota 文案中的升级/用量提示，不把它当作结果主体

### 风险与应对

| 风险 | 可能性 | 应对 |
|------|:---:|------|
| 工具调用 `▪ Bash(...)` 被误认为 deliverable | 中 | deliverable 检测排除 `Read(...)` / `Write(...)` / `Edit(...)` / `Bash(...)` 等工具调用 |
| 真正需要用户充值/升级的任务被静默归为完成 | 中 | 只有 quota 前已有自然语言 deliverable 才归入 `turnIdle`；无 deliverable 仍需处理 |
| Qoder / Codex quota 文案不同 | 中 | quota pattern 统一放入 adapter/observer，后续迁到 Agent Adapter 专属配置 |

### 验证标准

- [x] `Credits exhausted` 跟在 `▪ 12 个测试全部通过...` 后面时，task 为 `turnIdle`，result 被写入
- [x] `Credits exhausted` 前无 deliverable 时，仍进入 needs-attention/runtime issue
- [x] 结果卡片和 TTS 播最终 deliverable，不播 `Credits exhausted` 作为主体

---

## Step 3: ⑩ P3 — OutputSummaryProvider 重复检测

### 目标

移除 `_removeTerminalPromptBlocks()` 中的硬编码字符串匹配，改为复用 `TerminalPromptParser` 的统一结构化识别。

### 改动范围

- `TerminalPromptParser`：新增 `stripPromptBlocks()`，统一负责审批/终端交互块剥离
- `OutputSummaryProvider._removeTerminalPromptBlocks()`：移除内部硬编码 prompt start / option / footer 规则，改为调用 `TerminalPromptParser.stripPromptBlocks()`

### 风险与应对

| 风险 | 可能性 | 应对 |
|------|:---:|------|
| 统一 parser 漏掉边缘 prompt 格式，摘要中出现审批文本 | 中 | 新 prompt 格式只补 `TerminalPromptParser`，摘要层不再复制规则 |
| 两个 parser（SSH 层 + OutputSummaryProvider）的 prompt 检测逻辑不一致 | 低 | 终端 prompt 检测统一使用 `TerminalPromptParser`，`_isTerminalPromptStart` 的硬编码字符串逐步迁移到 parser 规则 |

### 验证标准

- [x] 摘要输出中不再出现 `Permission Required`、`Apply this change?` 等终端交互文本
- [x] 正常输出（非 prompt 块）不被误过滤
- [x] `OutputSummaryProvider` 相关测试通过

---

## Step 4: ⑨ P2 — _bridgeNotifyExecutionUpdate 轻量化

### 目标

将 `_bridgeNotifyExecutionUpdate()` 从调用重型 `observeOutput()`（含 TaskWatcher 解析 + 状态推断 + 持久化）改为调用轻量 `notifyOutputUpdated()`。

### 改动范围

- `ArminAppState._bridgeNotifyExecutionUpdate()`：内部调用从 `bridgeRuntime.observeOutput()` 切换为 `bridgeRuntime.notifyOutputUpdated()`
- `BridgeRuntime.observeOutput()`：保留为 legacy observation API，但不再从 streaming / reconcile 生产路径调用

### 风险与应对

| 风险 | 可能性 | 应对 |
|------|:---:|------|
| legacy `observeOutput()` 仍存在，后续新调用者可能误用它做状态推断 | 中 | 生产路径已切到 `notifyOutputUpdated()` / `RuntimeReconcileDecision`；后续 Step 8 再让 `observeOutput()` 去状态化 |
| `notifyOutputUpdated()` 不持久化，BridgeRuntime 内存中的输出进度在 App 重启后丢失 | 低 | Phase A 目标之一就是让 SQLite 成为持久化边界。当前 `TaskSession` 已通过 JSON 文件持久化，BridgeRuntime 的进度数据为辅助信息，丢失可接受 |

### 验证标准

- [x] streaming 路径每次 update 只发布 `outputUpdated` 事件，不触发状态变更事件
- [x] 状态变更仍由 `_taskWithExecutionUpdate()` 中的结构化字段驱动
- [x] `running` case 在 `_bridgeSyncTerminalStatus` 中的 `break` 随旧适配器移除

---

## Step 5: ④+⑧ P2 — _bridgeSyncTerminalStatus 适配层清理

### 目标

将 AppState 中的 `_bridgeSyncTerminalStatus()` 调用者逐个切换为直接调用 `bridgeRuntime.notifyXxx()`，并移除旧适配器方法。

### 改动范围

- `ArminAppState`：6 处 `_bridgeSyncTerminalStatus()` 调用点已逐一替换
- `_bridgeSyncTerminalStatus()`：全部调用者迁移后已移除

### 风险与应对

| 风险 | 可能性 | 应对 |
|------|:---:|------|
| 逐一切换过程中新旧状态同步路径不一致 | 中 | 每次只切换一个调用点，切换后验证该状态路径的 BridgeRuntime 事件是否正确发布 |
| `needAttention` / `turnIdle` 直接映射到 `WorkPhase` 时语义可能被压扁 | 中 | 切换前确认是否应映射为 `turnIdle`、`needsInstruction`、`needsReview` 或 `needsDecision`，禁止统一塞进单一 waiting 状态 |

### 验证标准

- [x] stream-side 状态变化调用点已切换为显式 Runtime API
- [x] 其余调用者切换后，对应状态路径的 RuntimeEvent 正确发布
- [x] `taskWaitingUser` / `taskCompleted` / `taskFailed` 事件与迁移前一致
- [x] 全部迁移后 `_bridgeSyncTerminalStatus()` 无调用者

---

## Step 6: ⑥+⑤ P1 — 审批模型迁移

### 目标

将 TerminalPrompt → ApprovalRequest 的包装链路替换为 `TerminalPrompt → NativeTerminalApproval`。历史任务已迁移后，`ApprovalRequest` / `ApprovalParser` 不再保留为兼容投影，审批状态只通过 `NativeTerminalApproval.state` / `ApprovalState` 表达。

### 改动范围

- `AgentExecutionUpdate`：新增 `nativeApproval`
- `SSHAgentSessionService`：streaming / settled update 同时产出 `nativeApproval`
- `BridgeRuntime.notifyApprovalRequested()`：接收 `NativeTerminalApproval` 并写入 `WorkState.approval`
- `TaskSession`：持久化 `nativeApproval` / `nativeApprovalRequests`
- `ArminAppState._taskWithExecutionUpdate()`：消费 `nativeApproval`
- `_ApprovalPromptCard`：原生消费 `NativeTerminalApproval`
- `TaskSpeechPolicy`：审批播报优先读取 `nativeApproval`
- `ApprovalRequest` / `ApprovalParser`：历史兼容外壳已移除

### 风险与应对

| 风险 | 可能性 | 应对 |
|------|:---:|------|
| 旧审批 JSON 已不再兼容 | 低 | 历史任务已完成 schema migration；后续不再写入旧字段 |
| UI `_ApprovalPromptCard` 与 runtime 状态显示不一致 | 低 | 详情页统一读取 `nativeApprovalRequests` / `nativeApproval` |

### 验证标准

- [x] 审批 prompt 在 safe / balanced / aggressive 三种模式下正确识别（现有 parser / app state 回归）
- [x] `ApprovalState` 状态机：pending → resolving → resolved/failed 完整流转（BridgeRuntime diagnostics + WorkState）
- [x] 审批历史 `nativeApprovalRequests` 正确记录
- [x] JSON 持久化往返无数据丢失（native 字段，`flutter test` 全量回归）
- [x] `TaskSession.nativeApproval` JSON 字段与 `_ApprovalPromptCard` 原生消费完成

---

## Step 7: ⑪ P1 — AgentExecutionUpdate 字段迁移

### 目标

`AgentExecutionUpdate` 中新增 `nativeApproval` 字段。生产路径产出 `nativeApproval`；旧 `approval` / `terminalPrompt` 字段已随历史 schema 清理移除。

### 改动范围

- `AgentExecutionUpdate`：新增 `nativeApproval`
- SSH 层 streaming / settled 构造点：产出 `nativeApproval`
- AppState：优先识别 `nativeApproval`，再回退旧 `approval` / `terminalPrompt`
- refresh / captured snapshot：从旧 parser 结果投影生成 `nativeApproval` 后再进入 AppState 归约

### 风险与应对

| 风险 | 可能性 | 应对 |
|------|:---:|------|
| 测试文件构造 `AgentExecutionUpdate` 时仍用旧字段 | 低 | 旧字段已删除，编译期阻止回归 |

### 验证标准

- [x] `flutter analyze` 0 error, 0 warning
- [x] SSH 生产路径 `AgentExecutionUpdate` 构造携带 `nativeApproval`
- [x] AppState 消费 native-only approval 并投影到当前任务模型
- [x] 核心测试中 native-only `AgentExecutionUpdate` 路径已覆盖
- [x] 旧 `approval` / `terminalPrompt` 字段不再是生产主路径；物理移除延后到历史 JSON schema 清理

---

## Step 8: ③+① P0 — observeOutput 去状态化 → _extractStatus 移除

### 目标

`observeOutput()` 改为纯数据记录，不再通过 `_extractStatus()` 驱动状态变更。`_extractStatus()` 最终标记 `@Deprecated` 并移除。

### 前置条件

- [x] Step 0 增量证据约束已落地
- [x] Step 1 结果/TTS 同源门禁已落地
- [x] Step 2 运行时限制分类门禁已落地
- [x] Step 4 `_bridgeNotifyExecutionUpdate` 已切换到轻量路径
- [x] Step 5 reconcile 路径不再依赖 `observeOutput` 的状态变更
- [x] Step 6 审批路径已具备新模型主路径（旧字段/兼容投影已移除）

### 改动范围

- `BridgeRuntime.observeOutput()`：已移除 `_publish(_eventTypeForStatus(nextStatus), ...)` 状态驱动发布，仅保留数据记录和 `outputUpdated`
- `TaskWatcher._extractStatus()`：已移除，`TaskWatcherUpdate` 不再携带 `status`
- `TaskWatcher._extractAction()` / `_extractCheckpoint()`：保留为数据记录辅助功能

### 覆盖盲区验证

| 旧 grep 模式 | 新事件覆盖 | 状态 |
|-------------|-----------|:---:|
| `waiting for user` / `needs approval` / `need approval` / `waiting for your` | `taskWaitingUser` / `approvalRequested` | ✅ |
| `task completed` / `completed successfully` | `taskCompleted` | ✅ |
| `task failed` | `taskFailed` | ✅ |
| `fatal error` | 评估是否归入 `taskFailed` 或新增事件 | ⚠️ |

### 风险与应对

| 风险 | 可能性 | 应对 |
|------|:---:|------|
| 旧 `_extractStatus` 的 grep 覆盖了少数新 RuntimeEventBus 未建模的场景（如 `"fatal error"`） | 中 | 移除前逐个 grep 验证覆盖 |
| legacy `observeOutput` 不再负责状态，旧 grep 覆盖场景可能失去 fallback | 低 | 生产路径必须通过 `RuntimeEventBus` / `RuntimeReconcileDecision` 覆盖状态变化 |

### 验证标准

- [x] 所有旧 grep 模式在新 RuntimeEventBus 中有对应事件覆盖（`fatal error` 留在 observer/failure 分类回归中）
- [x] `observeOutput()` 调用不再产生 `taskProgress` / `taskWaitingUser` / `taskCompleted` / `taskFailed` 事件
- [x] `_extractStatus()` 无调用者后移除
- [x] 相关测试通过

---

## Step 9: ⑦ P2 — UI 消费 TaskStatus → WorkState

### 目标

UI 层不再直接 `switch (task.status)`，改为通过 `WorkState.phase` 判断展示内容。

### 前置条件

- [x] Step 5 `_bridgeSyncTerminalStatus` 已完成迁移，BridgeRuntime 的 `_workStates` 在状态变更时同步更新
- [x] Step 8 完成，TaskStatus 的状态变更路径唯一且正确

### 改动范围

- `task_detail_screen.dart`：`switch (task.status)` / `_isAttentionRequired(task.status)` → `workState(taskId).phase`
- `task_home_screen.dart`：Waiting For You / Running Summary / Activity Feed / task list labels → `WorkState.phase`
- `task_card.dart` / `task_history_screen.dart`：历史任务卡片状态 badge / progress label → `WorkState.phase`
- Current Situation 卡片：改为消费 `WorkState`
- 状态标签：`TaskStatusLabel.label` → `WorkPhase` 映射

### 当前 WorkPhase 映射缺口

```
TaskStatus                  WorkPhase
─────────                  ─────────
turnIdle        →          turnIdle
needAttention   →          needsInstruction / needsDecision / needsReview（按原因细分）
needApproval    →          needsApproval
running         →          working
completed       →          completed
failed          →          failed
stopped         →          stopped
```

### 风险与应对

| 风险 | 可能性 | 应对 |
|------|:---:|------|
| `needAttention` 原因不明，UI 无法决定是继续、审批、查看还是恢复 | 中 | 迁移前先让 reducer 填充 `WorkState.detail` / `approval` / `phase`，UI 不再自行猜原因 |
| `WorkState` 只在 `BridgeRuntime._transition()` 和 `_updateWorkState()` 中更新，非终端状态路径可能未覆盖 | 低 | 在 Step 5 验证 `_bridgeSyncTerminalStatus` 的所有调用者都已在 BridgeRuntime 侧产生状态变更 |

### 验证标准

- [x] 首页 Waiting For You / Running Summary / Activity Feed 优先消费 `WorkState`
- [x] 历史任务卡片优先消费 `WorkState`
- [x] Task Detail 首屏状态标签 / Current Situation / What This Task Needs / 主按钮优先消费 `WorkState`
- [x] Current Situation 卡片显示内容与迁移前一致
- [x] 状态标签正确映射
- [x] 二级控制、调试、兼容 fallback 中残留的 `TaskStatus` 判断仅作为低层兼容分支，不再承载一等 UI 心智

---

## 风险总览

| Step | 核心风险 | 严重度 | 缓解措施 |
|------|---------|:---:|------|
| 0 | `hasNewDelta` 状态位维护错误 | 中 | hash 比较 + 测试覆盖 |
| 1 | 结果卡片和 TTS 再次分叉 | 高 | latest turn deliverable source 单一 helper + 回归测试 |
| 2 | quota / usage limit 再次被归为普通输入需求 | 高 | observer / adapter 先判 deliverable，再判 runtime issue |
| 3 | SSH 层预处理遗漏 prompt 格式 | 中 | 双 parser 并行运行，diff 验证 |
| 4 | legacy `observeOutput` 被新调用者误用 | 低 | 生产路径只用 `notifyOutputUpdated` 和 `RuntimeReconcileDecision` |
| 5 | 逐一切换时新旧同步不一致 | 中 | 每次仅切一个调用者，立即验证 |
| 6 | JSON 持久化旧审批数据丢失 | 中 | 新旧字段并行一个版本周期 |
| 7 | 测试文件旧字段残留 | 中 | 核心 fake agent 已迁 native-only；旧字段 fixture 只保留兼容覆盖 |
| 8 | 新事件未覆盖旧 grep 模式 | 中 | 逐个 grep 词验证覆盖 |
| 9 | `WorkPhase` 粒度不足 | 中 | 迁移前确认 `needsInstruction` / `needsDecision` / `needsReview` 映射 |

---

## 功能迁移计划

迁移按“功能垂直切片”推进，而不是按文件批量替换。每个切片完成后都必须能独立通过测试，并且旧路径只作为 fallback 存在。

| 阶段 | 功能切片 | 当前旧路径 | 目标新路径 | 完成标准 |
|------|----------|------------|------------|----------|
| A0 | 状态触发保护网 | SSH grep / full capture 直接触发状态 | 增量证据、marker count、fingerprint 去重 | 旧 prompt / 旧 exit marker 不能触发 `needAttention` / `turnIdle` |
| A1 | 输出与播报同源 | 结果卡片、TTS、summary fallback 各自取源 | latest turn deliverable source | 后续 turn 结果、TTS、手动朗读一致 |
| A2 | Runtime issue 分类 | `Credits exhausted` → `needAttention` | deliverable 优先，runtime issue 次之 | 有结果时显示结果，无结果时提示运行时问题 |
| A3 | 审批/终端交互 | `TerminalPrompt` → `ApprovalRequest` String 状态 | `TerminalPrompt` → `NativeTerminalApproval` + `ApprovalState` | Runtime/WorkState、审批卡、历史、JSON 已纵切，旧模型已移除 |
| A4 | Streaming 事件 | `_bridgeNotifyExecutionUpdate` → `observeOutput` | `notifyOutputUpdated` 轻量事件 | progress 不触发状态归约，不引发全局重建 |
| A5 | 状态 reducer | `_bridgeSyncTerminalStatus` + `TaskStatus` 写入 | RuntimeEventBus → reducer → WorkState | AppState 只发 command，不猜状态 |
| A6 | Reconcile/Refresh | full capture 重新推断状态 | `RuntimeReconcileDecision` + 增量补齐 | refresh 只校准新证据，不复活旧 pane 残留 |
| A7 | UI 状态消费 | UI 直接 `switch (TaskStatus)` | UI 读取 `WorkState.phase/detail` | 首页、详情、TTS 不再直接消费 raw terminal state |

### 推荐执行节奏

1. **先冻结行为契约**：保留 Step 0–2 的测试，不允许迁移中改回旧行为。
2. **先迁移输出类功能，再迁移状态类功能**：结果/TTS 的错源问题最容易影响用户感知，且能作为后续 reducer 的验收样本。
3. **审批模型已经纵切到 native 主路径**：不要重新引入 `ApprovalRequest` / `ApprovalParser`；审批状态只通过 `NativeTerminalApproval.state` / `ApprovalState` 表达。
4. **observeOutput 去状态化前先切 streaming**：确保高频路径不再依赖 `TaskWatcher._extractStatus()`，再处理 reconcile 路径。
5. **UI 最后迁移**：等 WorkState 覆盖所有语义后再替换 UI，否则会把状态缺口转移到页面 helper。

### 每个切片的最小验收集

- `flutter analyze` 对改动文件无 error / warning。
- 该切片的单元测试 + 至少一个 AppState 级测试。
- 若影响 UI，增加 widget 测试覆盖首页或详情页。
- 若影响 TTS，断言实际 `TaskSpeechDecision.text`，不能只断言 `shouldSpeak`。
- 若影响 result，必须覆盖“后续 turn + 旧 summary + 最新 `▪` deliverable”的真实形态。

---

## 半迁移态一致性保障

每次 Step 完成后必须验证两条路径输出一致：

```
旧路径（仍运行）              新路径（正在切换）
══════════════                ══════════════
SSH script grep              RuntimeEventBus event
↓                            ↓
AgentExecutionUpdate          bridgeRuntime.notifyXxx()
↓                            ↓
_taskWithExecutionUpdate      _workStates[taskId]
↓                            ↓
TaskSession.status           WorkState.phase
```

验证方式：在 Step 完成后，选取一个典型任务（safe → balanced → aggressive 各一个），对比旧路径的 `TaskStatus` 与新路径的 `WorkPhase` 在相同输入下是否一致。对不应一致的场景（例如 quota 后已有 deliverable），以新行为门禁为准，旧路径只能作为兼容 fallback。

---

## 移除验证标准

每个旧逻辑的移除必须满足：

1. ✅ 新 RuntimeEventBus 事件流已覆盖该场景
2. ✅ 相关测试在移除后仍然通过
3. ✅ Flutter analyze 0 error
4. ✅ 旧逻辑已无调用者（或调用者已迁移）

---

## 当前共存状态

Phase 2.5 目前处于新旧逻辑的**过渡共存**：

```
新逻辑                          旧逻辑
══════════                      ══════════
RuntimeEventBus (25 events)     TaskWatcher._extractStatus()
bridgeRuntime.notifyXxx()       _bridgeSyncTerminalStatus()（已移除）
ApprovalState enum              ApprovalRequest.status（已移除）
WorkState                       TaskStatus（二级控制/调试 fallback）
NativeTerminalApproval          TerminalPrompt → NativeTerminalApproval
```

主路径已经迁移到 RuntimeEventBus / WorkState / NativeTerminalApproval。审批兼容外壳已随历史 JSON schema 清理物理移除；后续不能重新引入 prompt 污染、提前 `turnIdle`、旧结果播报等问题。测试数量不固定，以当前分支 `flutter test` 结果为准。
