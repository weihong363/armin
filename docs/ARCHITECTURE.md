# 架构

Armin 是一个 Flutter 应用，采用本地优先的状态管理，并围绕语音、提示构建、历史记录和终端代理执行提供服务抽象层。

长期 Runtime 方向见 [Bridge Runtime Long-Term Architecture](runtime/bridge-runtime-long-term-architecture.md)。当前 Flutter 内 Bridge Runtime 是过渡实现；最终任务生命周期、审批状态、事件流和 watcher offset 的持久化边界应在 SQLite，并逐步迁移到远端 Runtime daemon 或支持可靠断线续传。

Session Manager Daemon 是向远端 Runtime daemon 架构演进的第一步，设计决策见 [Session Manager Daemon 设计](runtime/session-manager-daemon.md)。

安全远端执行器也是长期架构考虑，而不是 Phase 2.5 / Phase 3 的近期目标。近期仍应优先验证语音任务创建、Loop-based 工作流、长生命周期编码任务和多设备远程访问需求是否真实存在；在这些假设成立前，不应显著增加 relay、身份、权限和多执行器路由等基础设施复杂度。

长期目标不是消除文本解析。Codex / Qoder 是 TUI 程序，文本仍然是原始观察输入；目标是把“文本 → 事件”的转换集中在 Runtime Watcher / Agent Adapter 层，解析新增文本后写入结构化事件，再由 Runtime reducer 归约任务状态。AppState、结果卡片、TTS 和 UI 不应各自反复解析 raw terminal text，也不应让 pane 中残留的 exit marker、thinking、approval prompt 或旧结果直接决定当前 turn 状态。

## 层级结构

- `core/models`: 共享状态和跨功能值类型
- `core/storage`: 历史存储抽象、内存测试实现和 SQLite 持久化实现
- `features/voice`: STT/TTS 抽象、模拟语音服务和设备语音服务
- `features/tasks`: 草稿模型、提示构建器、秘密信息脱敏、约束提取、状态流转和任务 UI
- `features/agent`: 代理会话抽象、测试 mock、SSH/tmux 服务、原生输出清洗/观察与 legacy 解析器
- `features/hosts`: 主机配置模型和 UI
- `features/history`: 任务详情审计视图
- `features/runtime`: Bridge Runtime、RuntimeEventBus、SessionManager、TaskWatcher、WorkState/ApprovalState 模型与 reconcile 探测

## 本地存储

测试可注入 `InMemoryTaskHistoryStore` 和 mock 服务。应用运行时通过 `ArminAppState.run()` 使用 `SQLiteTaskHistoryStore`、`DeviceVoiceService` 与 `SSHAgentSessionService`。Host、project path、task history、Runtime 聚合和事件统一写入 `armin_runtime.db`；生产路径不存在 JSON Store。

正常任务历史绝不能存储明文敏感值。Phase 2 只支持 SSH password 认证；`HostConfig.toJson()` 排除 password，`SecurePasswordStore` 通过 `flutter_secure_storage` 将密码存入平台安全存储，加载后仅在运行内存中传递给 SSH 请求。`privateKeyPath` 是兼容字段，不是默认执行路径。

## 代理会话服务

`AgentSessionService` 为执行、跟进、连接测试、日志 capture 与 session 控制提供抽象。执行更新包含：

```dart
AgentExecutionUpdate(
  rawOutput,
  cleanedOutput,
  observerState,
  turnIdle,
  runtimeLost,
  needsAttention,
  done,
)
```

`MockAgentSessionService` 仅用于测试。`SSHAgentSessionService` 的真实 Phase 2 流程为：

1. 使用安全加载的 password 连接到 Host。
2. 为新任务使用短且独立的 tmux session，例如 `armin-2800`。
3. 在任务选择的 project path 中启动配置的 Agent：Codex 使用 `-C`，Qoder 使用 `-w`。
4. 发送经 `PromptGovernor` 处理的用户提示。
5. 按 `RuntimePolicy` 轮询有限范围的 `tmux capture-pane`；稳定窗口发布 settled-candidate，attach-only 也检查当前静止快照。
6. 用 `AgentOutputCleaner` 生成展示/观察用输出，并由 `NativeOutputObserver` 复核 settled-candidate，产生 `turnIdle`、`needAttention` 或 `runtimeLost` observation。
7. `turnIdle` 保留 session 等待用户继续；暂停会停止手机端 observer 而保留 session，恢复会重新监听同一 session；用户标记完成、失败、停止或达到最长运行时限时，先 capture 最终日志，再 cleanup session。

Armin 不负责代理的推理、规划、代码合并或调度。它仅管理 shell 级别的通信和可审计性。

`tmux capture-pane` 是观察输入，不是任务状态的唯一权威。输出稳定或无新增可见文本只能表示 `outputQuieting` / `no visible update`，不能单独触发 `turnIdle`、结果卡片或 TTS 播报。但在 Runtime Event 覆盖完整前，tmux snapshot / parser 仍是自动 reconcile 的必要输入：当 stream marker、RuntimeEvent 或 WorkState 卡住时，可以用新增证据、marker count、fingerprint 或 offset 去重后的 capture 结果校准 `TaskSession.status` 和 `WorkState`。长期应由 Runtime Event + SQLite Store 派生 `WorkState`、`ApprovalState` 和结果可见性。

目标链路：

```text
tmux / Codex / Qoder
↓
Raw TUI text stream
↓
CodexAdapter / QoderAdapter / GenericTuiAdapter
↓
RuntimeEventBus
↓
Runtime reducer
↓
SQLite Task / Turn / Event Store
↓
Armin App UI
```

Adapter 可以解析文本中的审批、等待输入、进度、交付结果和进程退出，但它只产出事件候选；是否进入 `turnIdle`、`needApproval`、`completed` 或显示结果卡片，必须由 reducer 基于新增事件和持久化状态决定。

## 输出与提示层

纯 Dart 服务保持行为可测试：

- `AgentOutputCleaner`
- `NativeOutputObserver`
- `SecretRedactor`
- `PromptTemplateBuilder`
- `PromptGovernor`
- `AgentInstructionDiscovery`
- `SpeechDraftCleaner`
- `ConstraintExtractor`
- `OutputSummaryProvider`

旧的 `TaskResultParser` / `TASK_RESULT_*` 协议解析外壳已移除。Runtime 对 current-turn evidence 调用一次 `OutputSummaryProvider`，将 display/speech summary 与 fingerprint 持久化为 `TurnDeliverable`；结果卡、手动朗读和自动 TTS 只读取该对象。审批终端提示直接映射为当前 `WorkState.approval`，TaskSession 审批列表只保留审计历史。

## 指标/事件层

`MetricEvent` 记录 shell 级别的事件，如任务创建、任务开始、接收到原始输出、请求批准和任务完成。第一阶段在任务详情时间线中显示这些事件。后续阶段可以聚合诸如持续时间、编辑次数、批准次数、中断次数、验证状态、变更文件数和原始日志大小等字段。

后续指标层还应覆盖单次任务交互效率，而不是只记录 runtime 事件数量。重点观察用户 token 消耗、Agent 输出长度、有效结果占比、追加/重试次数、审批次数、等待时间、用户是否接受结果，以及任务从创建到可验收的耗时。这些指标服务于“每次交互是否更高效、结果是否更符合预期”，不用于把 Armin 扩展成模型基准测试平台。

Armin 适合采用轻量 Loop Engineering 视角：Plan → Execute → Observe → Evaluate → Adjust → Verify。该 loop 描述用户围绕任务持续补充上下文、观察结果和确认下一步的产品循环；它不是 workflow engine，也不代表自动多 Agent 编排。Runtime 负责可靠观察和状态归约，评估层负责记录本轮循环是否消耗过高、是否需要返工、是否达到用户预期。

### RuntimeEventBus（Phase 2.5）

`RuntimeEventBus` 是 Bridge Runtime 提交后的结构化通知流，承载 25 种事件类型。SQLite 中的 Runtime 聚合才是可恢复的状态真相源；EventBus 不承担持久化或冷启动恢复：

- **任务生命周期**：`TASK_CREATED`、`TASK_STARTED`、`TASK_PROGRESS`、`TASK_WAITING_USER`、`TASK_COMPLETED`、`TASK_FAILED`、`TASK_CANCELLED`
- **运行时控制**：`TASK_PAUSED`、`TASK_RESUMED`、`TASK_STOPPED`
- **输出与交付物**：`OUTPUT_UPDATED`、`DELIVERABLE_UPDATED`
- **审批生命周期**：`APPROVAL_REQUESTED`、`APPROVAL_RESOLVING`、`APPROVAL_RESOLVED`、`APPROVAL_REJECTED`、`APPROVAL_FAILED`
- **观察者与连接**：`OBSERVER_ATTACHED`、`OBSERVER_DETACHED`、`CONNECTION_LOST`、`CONNECTION_RESTORED`
- **审查与等待**：`REVIEW_SUBMITTED`、`WAITING_FOR_INSTRUCTION`、`WAITING_FOR_REVIEW`、`WAITING_FOR_APPROVAL`

事件流通过 `BridgeRuntime` 的 `_publish()` / `_publishDirect()` 在状态提交后发出。首页和详情状态读取 snapshot；详情只用 Runtime 事件更新独立 progress 区域。`TaskWatcher` 只产出 observation，不作为状态权威。

## UI 结构

主页是一个任务队列，而非终端：

- 需要处理的任务（审批/关注）
- 活跃任务与上限显示（默认 5）
- 历史任务入口（显示全部任务数）
- 新建任务按钮

新建任务：

- 设备语音输入，测试可注入 mock
- 任务描述编辑器
- 上下文编辑器
- 约束芯片
- 密钥输入
- 提示预览
- 发送到真实 SSH/tmux agent session

任务详情：

- 时间线/审计部分
- 语音/STT
- 草稿和已确认的任务
- 已发送的提示
- 运行时控制与断开/重连监听
- 结果摘要
- 折叠的原始日志
- 指标时间线

## Bridge Runtime（Phase 2.5）

`BridgeRuntime` 是 Flutter 进程内的 Runtime 状态归约与事件发布边界。AppState 将状态变化写入按 task 串行的 Runtime 队列；`TaskWatcher` 只解析当前增量证据，`RuntimeEventBus` 分发提交后的结构化通知，`WorkState` 和 `ApprovalState` 是当前 UI 语义来源。`WorkState` 嵌入 `runtime_tasks` 聚合记录，不再独立持久化；任务历史、Runtime 聚合和事件共享 `armin_runtime.db`。

### 核心组件

| 组件 | 职责 |
|------|------|
| `BridgeRuntime` | 任务快照管理、状态转换、事件发布、reconcile 探测 |
| `RuntimeEventBus` | 广播式事件流，25 种事件类型 |
| `RuntimeSessionManager` | Session 创建/恢复、task-to-session 映射、状态生命周期（active → detached → destroyed） |
| `TaskWatcher` | 增量输出解析、偏移量追踪、进度/动作/检查点提取 |
| `RuntimeTaskStore` | SQLite Runtime 聚合与 event 持久化；WorkState 嵌入聚合 |

### WorkState 与 ApprovalState

UI 不直接消费 raw terminal state。`BridgeRuntime` 通过 `_updateWorkState()` 派生人类可读的 `WorkState`（`WorkPhase`：idle / working / turnIdle / needsApproval / completed / failed / stopped），UI 通过 `workState(taskId)` 读取当前阶段、标题和详情。

审批状态通过 `ApprovalState` 枚举表达完整生命周期：

```text
none → pending → resolving → resolved
                     ↘ failed
```

- `pending`：检测到审批请求，等待用户操作
- `resolving`：用户操作已发送到终端，等待远端确认
- `resolved`：审批 prompt 消失或 runtime 确认审批成功
- `failed`：终端操作失败或超时

审批区分两类：`NativeTerminalApproval`（CLI 交互式 prompt，如 Allow Once / Reject）和 `ReviewDecision`（工作流审查，如 Approve / Request Changes / Ask Question）。

### Reconcile 探测

`BridgeRuntime` 通过 `startReconcileLoop()` 周期扫描 running 任务（默认 30s），每次最多探测 3 个任务（超时 3s）。探测结果触发以下决策：

- `sessionMissing`：远端 tmux session 不存在 → 标记 `runtimeLost`
- `needsAttention`：远端输出包含审批/关注关键词 → 标记 `needAttention`
- `exited`：远端 Agent 进程已退出 → 标记完成
- `stableOutput`：连续两次探测输出 hash 不变 → 标记 `turnIdle`

连续 6 次 `sessionMissing` 后自动排除该任务，避免无效 SSH 探测。`runtimeLost` 为终端状态，不计入活跃任务上限且可被删除。

## 运行时控制

运行时控制仅限于 shell 和用户任务语义层：

- 跟进指令直接发送到当前 tmux/Agent 会话，不添加私有结构化 marker。
- 运行中的语音追加与语音控制会追加脱敏后的 `VoiceInput`，使历史可区分用户实际说过的推进或终止语义。
- 暂停/恢复与停止控制当前远端会话；对应的 `TASK_PAUSED` / `TASK_RESUMED` / `TASK_STOPPED` 事件通过 RuntimeEventBus 发布。
- 断开监听只移除手机侧 observer（发布 `OBSERVER_DETACHED`），远端 session 可继续运行；重新连接会 attach 到同一 session（发布 `OBSERVER_ATTACHED`）。
- 任务监督在终态前持续存在，但高频 SSH/tmux stream 可以降级：用户正在查看任务详情时保持实时 observer；后台达到资源阈值前先 capture 并归约最新证据，再转为低频 reconcile。detached snapshot 首次出现或发生变化时必须自动刷新，不得要求手动重连。
- detached 状态下发送 follow-up 时，必须先同步并封存上一 Turn 的新增远端输出，再创建下一 Turn，避免 reconnect snapshot 将旧结果归入新 Turn。
- SSH 传输中断或手机网络掉线发布 `CONNECTION_LOST`，进入可恢复的监听断开状态，不会自动判定远端任务失败或清理可能仍在运行的 session；恢复后发布 `CONNECTION_RESTORED`。
- `turnIdle` 表示本轮在强信号下进入等待用户继续，用户可以继续追加或确认结束，不等于完成；它不应由短时间无输出或 pane 稳定直接产生。
- 用户标记完成/失败或停止时，Armin 保存 final capture 后清理 tmux session。
- 如果 cleanup 未能确认成功，任务会保留提示和日志，终态详情页可再次请求清理远端 session。
- `runtimeLost`（远端会话已不可用）属于终端状态；该任务不再被 reconcile 探测、不被 bridge 跟踪、不计入活跃任务上限，且可被删除。仅 `running` 和 `observerDetached` 会被周期性 reconcile 探测远端状态。
- `RuntimePolicy` 会按执行模式调整安静输出阈值：安全模式较短，平衡模式更长，激进 / YOLO 模式最长，以降低长时间 thinking、跑测试或自动执行时被误判为 `turnIdle` 的风险；单次运行仍有最长观察时限，监控窗口较短，final capture 窗口较完整。
- 已结束、失败、停止或运行丢失的任务可重新执行，并预选原任务的 Host 和 project path；仍在交互中的任务不能通过重跑另起 session。

Armin 不解释或重写 Agent 的执行逻辑。`SelectableOutputSummaryProvider` 支持用户打开实验性的端侧摘要增强，并在 runner 不存在、设备不支持、超时或失败时回落至脱敏后的规则摘要。生产包仍待接入实际 Android 模型 runner；它只用于 TTS/展示摘要，不参与 Agent 执行。

## 交互效率与 Loop Engineering

长期上，Armin 不只判断“任务有没有结束”，还要帮助用户判断“这轮 Agent 交互是否值得继续用同样方式推进”。效率评估应绑定到 Task / Turn，而不是绑定到某个聊天会话：

- 输入侧：任务描述长度、上下文追加次数、语音/文本比例、审批次数和用户等待时间
- 输出侧：deliverable 是否存在、摘要是否可读、TTS 是否同源、无效输出和 thinking/CLI 噪声是否被过滤
- 结果侧：用户接受、继续、拒绝、重做或标记完成的行为
- 成本侧：token 消耗、重复执行次数、用户返工次数和从任务创建到验收的时长

Loop Engineering 在 Armin 中的边界是单任务闭环优化：更清楚地计划任务、更可靠地观察执行、更早发现偏离、更低成本地追加上下文和验收结果。它不应变成复杂工作流系统、自动 fork/join runtime 或多 Agent 调度器。

## Phase 2.6 结果迁移架构

结果、TTS 和诊断使用同一套 deliverable 数据契约，UI 同步路径不承担重解析工作。迁移执行和验收标准统一维护在 [legacy-cleanup-checklist.md](runtime/legacy-cleanup-checklist.md)。架构只保留三层边界：

| 层 | 同步性 | 职责 | 禁止事项 |
|----|--------|------|----------|
| Candidate / Evidence Layer | 同步选择、按需取证 | 选择可能包含结果的 turn；需要解析时读取 scoped raw / cleaned output 作为 evidence | 不生成摘要，不直接展示 evidence，不直接朗读 raw output |
| Resolved Summary Layer | 异步、可缓存 | 对 evidence 做过滤和摘要生成，产出 `displaySummary` / `speechSummary` / provenance | 不阻塞 build / Tab 切换 / 任务完成状态更新 |
| Speech Source Layer | 异步优先，复用 resolved summary | 手动朗读和自动 TTS 复用 resolved `speechSummary`，缺失时读清洗后的 `displaySummary` | 不从 prompt、running snapshot、reconnect snapshot 或 legacy summary 推导 latest result |

`rawOutput` / `cleanedOutput` 是 resolver evidence，不是产品层 deliverable；`task.summary` / `shortSummary` 不作为 deliverable 兜底。解析结果先作为 `TurnDeliverable` 持久化，再发布关联 turn id 和 evidence fingerprint 的 `DELIVERABLE_UPDATED`；结果卡片、手动朗读和自动 TTS 读取同一个 display/speech payload。

所有阶段的架构迁移、替换和重大重构都由 [Armin 核心行为与性能基线](runtime/core-behavior-performance-baseline.md) 约束。新的主路径只有在状态、任务控制、结果/TTS、交互响应和持久化成本均满足基线后，才能替代并移除旧路径。

## 未来安全远端执行器

Codex 近期方向中的 authenticated remote executor、端到端加密 relay channel 和基于 Noise 的安全通信，为 Armin 的远期架构提供了参考。未来可考虑的 Secure Remote Executor Infrastructure 包括：

- Executor Identity
- Device Authentication
- 基于 Noise 的端到端加密
- Authenticated Relay Channels
- Permission Profiles
- Audit Logs
- Multi-Device Synchronization
- Multi-Executor Routing
- Secure Session Management

参考链路：

```text
Mobile App
↓
Encrypted Relay
↓
Executor
↓
Codex / Claude Code / Other Agents
```

Relay 必须被视为不可信组件。长期上，敏感通信应由 Mobile App 与 Executor 之间的端到端加密保护，relay 只承担转发能力，不应成为明文状态、密钥或用户任务内容的信任边界。
