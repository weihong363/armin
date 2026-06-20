# Armin 规范

Armin 是一个语言优先的 shell，用于将工作委派给计算机上的终端 Agent。它不是 Codex Mobile，不是一个完整的终端应用，也不是一个 AI 运行时。Armin 帮助用户用自己的语言描述、约束、推进、恢复、停止和确认工作，再由不同 Agent 执行，并保留审计跟踪。

执行核心保留在计算机端：

- Codex CLI
- Qoder CLI
- 后续通过相同 shell adapter 接入的终端 Agent

## 产品原则

1. 用户是在向 AI 编码代理分配工作，而不是操作终端。
2. 中间终端噪音默认隐藏。
3. 用户关心任务是否被理解、发送、等待继续、需要处理以及由自己确认结束。
4. 每个有意义的交互都会被存档以备后续调试。
5. 语音是降低异步交互成本的一种输入方式，Armin 必须同时支持语音和文字。
6. 敏感值应该被输入、脱敏并从普通历史中排除。
7. Armin 不实现复杂的代理执行、调度、合并或规划逻辑。
8. 未来的指标应有助于调试人与代理之间的委托质量。
9. 用户采纳和任务完成率比基础设施复杂度更重要。

## 当前 Phase 2 范围

Phase 2 必须跑通一个真实且可持续交互的循环：

```text
语音/文本输入
-> 任务草稿
-> 用户编辑和确认
-> 最终提示
-> SSH/tmux 交接给配置的桌面 Agent
-> 原生输出观察与 turn idle 检测
-> 用户语音/文本继续、停止或确认终态
-> 清洗后的结果显示/语音摘要
-> 完整的本地历史
```

第一阶段的 mock 服务仅用于测试与早期验证。应用现在默认使用 `DeviceVoiceService`、`SSHAgentSessionService` 和 `JsonTaskHistoryStore` 的真实链路。

## 非目标

- Codex Mobile 官方远程控制替代品
- 完整的终端模拟器
- 复杂的多代理调度器
- 真正的 fork/join 运行时
- 自动代码合并
- 复杂的规划器
- 以本地 SLM 替代桌面端 Agent 执行
- 云同步
- 团队协作
- SaaS 后端
- 自动 git commit 或 push

## 必需的 MVP 功能

### 语音优先输入

- 首页和任务草稿页的语音入口
- 按住开始、松开停止的设备 STT
- 可编辑的转录文本
- 历史中的原始 STT 文本
- 运行中追加指令支持文本和语音
- 用户按住开始新的语音输入时立即停止当前结果播报
- 设备无语音能力时保留手动输入

### 文本辅助编辑

任务草稿屏幕支持：

- 任务描述
- 补充上下文
- 错误日志
- 文件路径
- 命令输出
- 密钥输入
- 约束芯片

必需芯片：

- 只分析不修改
- 最小改动
- 允许修改
- 修改后运行测试
- 不要提交 Git
- 高风险操作先确认

### 敏感信息处理

密钥字段：

- `name`（名称）
- `value`（值）
- `usage`（用途）
- `scope: current_task_only`（范围：仅限当前任务）

历史仅存储名称、用途、范围和 `[REDACTED]`。提示预览仅显示占位符。Host SSH password 不写入普通 JSON 历史，通过 `flutter_secure_storage` 使用平台安全存储保存，并仅在运行时加载到内存。

脱敏器必须检测令牌、密码、私钥、cookie、API 密钥、访问密钥和秘密模式。

### 提示构建

发送到桌面 Agent 的提示使用 `armin-task-v1` 模板。`PromptTemplateBuilder` 先用本地规则 chunking 保留用户任务原话、约束、secret 占位符和高价值上下文，再通过 `PromptGovernor` 注入短的上下文治理规则；参见 [PROMPT_TEMPLATE.md](PROMPT_TEMPLATE.md)。提示不要求 Agent 返回结构化 marker。

### Shell 层

Armin 拥有 shell 级别的会话抽象，而不是代理运行时：

- `AgentSessionService`
- `MockAgentSessionService`
- `SSHAgentSessionService`

`MockAgentSessionService` 仅用于测试。真实 Phase 2 连接到 Host，按任务创建短 session（`armin-{taskId片段}`），并在用户选择的 project path 中启动 Agent。Codex CLI 使用 `codex -C {projectPath}`；Qoder CLI 使用 `qodercli -w {projectPath}`。`AgentOutputCleaner` 和 `NativeOutputObserver` 清洗并观察原生输出；安静输出进入 `turnIdle`，并不代表任务已经完成。

长期 Runtime 方向中，`tmux capture-pane` 只能作为观察输入，不能作为状态权威。短时间无新增输出或 pane 稳定只能表示 `outputQuieting` / `no visible update`；`turnIdle`、结果卡片和 TTS 播报应由 Runtime Event、SQLite 中的 durable state、明确等待用户输入、审批状态或 adapter 识别的强完成信号驱动。

Codex / Qoder 是 TUI 程序，因此文本解析不可避免。规范要求解析边界集中在 Runtime Watcher / Agent Adapter：Adapter 只解析当前观察基线之后的新增文本，产出 `ApprovalRequested`、`TurnWaitingUser`、`DeliverableUpdated`、`ProcessExited` 等候选事件；Runtime reducer 再基于新增事件和持久化状态归约任务状态。长期上，完整 pane capture 不应直接产生状态变更事件；Phase 2.6 过渡期内，它仍可作为自动 reconcile 输入，但必须先经过增量证据、marker count、fingerprint 或 event id 去重，再由统一状态归约路径更新 `TaskSession.status` / `WorkState`。

状态触发型事件必须具备“当前观察窗口的新证据”。旧 pane 中残留的 exit marker、approval prompt、terminal option prompt、thinking 文本、旧结果或 prompt echo 不能重新进入 reducer，不能触发 `needAttention`、`turnIdle`、结果卡片或自动 TTS。若需要从完整 capture 恢复状态，必须通过 offset、marker count、event id 或内容 fingerprint 做去重。

Bridge Runtime 当前运行在 Flutter 进程内，属于过渡实现。长期应将 Runtime 的持久化边界放在 SQLite，并逐步支持断线续传或迁移为远端 Runtime daemon，使任务状态不依赖 App 进程生命周期。

### 历史和审计跟踪

每个 `TaskSession` 必须保留：

- 原始语音录音元数据（如果可用）
- 原始 STT 文本
- 清理后的草稿
- 用户确认的任务文本
- 最终提示
- 脱敏的秘密记录
- 执行原始日志
- 批准请求
- 原生输出与清洗后的展示摘要
- 每轮用户输入和输出观察状态；运行中的语音追加或语音控制输入按脱敏文本保留
- 状态变更
- 指标事件

任务详情屏幕显示语音/STT、草稿、已确认任务、已发送提示、运行时事件、结果摘要、变更文件、验证、风险、折叠的原始日志、批准记录和指标时间线占位符。

### 轻量级持续交互

Phase 2 保留 shell 级别的控制：

- 跟进追加
- 断开/重连手机监听
- 停止
- 暂停/恢复
- 用户标记完成/失败

追加内容以用户写下或说出的指令直接发送到活动 tmux 会话，不添加要求 Agent 理解的私有结构化协议。断开监听只停止手机侧观察；用户确认完成、失败、停止或运行达到最长观察时限后，Armin 先 capture 最终日志，再清理对应 tmux session。

### Fork/join 组织

MVP 不实现真正的并行运行时。数据模型为父任务、子任务、子任务状态、工作器标签和加入摘要保留空间，用于手动或规则建议的任务组织。

## 数据模型

- `HostConfig`: id, name, host, port, username, authType, tmuxSessionName, tmuxCommand, pathPrepend, shellWrapper, machineType, agentCommand, password(runtime only), createdAt, updatedAt
- `ProjectPathConfig`: id, hostId, name, path, createdAt, updatedAt
- `TaskSession`: id, title, hostId/host, projectPath, status, createdAt, startedAt, completedAt, parentTaskId, workerLabel, summary
- `VoiceInput`: id, taskId, rawSttText, language, createdAt
- `TaskDraft`: id, taskId, cleanedText, userEditedText, contextText, constraints, createdAt, updatedAt
- `PromptRecord`: id, taskId, finalPrompt, templateVersion, createdAt
- `SecretRecord`: id, taskId, name, usage, redactedValue, scope, createdAt
- `ExecutionLog`: id, taskId, rawOutput, createdAt
- `NativeOutputTurn`: id, taskId, turnIndex, userInput, rawOutput, cleanedOutput, status, timestamps, userDecision
- Result summaries are derived from native turns/output and stored on task summary fields; the legacy `TaskResult` representation has been removed
- `NativeTerminalApproval`: id, taskId, question, options, state, createdAt, stateChangedAt, selectedOptionKey, failureReason
- `MetricEvent`: id, taskId, eventType, payloadJson, createdAt
- `Subtask`: id, parentTaskId, title, status, workerLabel, orderIndex, summary, createdAt, completedAt

## 端侧摘要方向

输出展示与 TTS 默认使用规则摘要。Phase 2 已提供端侧摘要增强实验开关、runner 接口、能力检测、规则 fallback 与摘要脱敏；传入可选 runner 或 fallback 的任务输出和 prompt 文本会先脱敏。当前生产包尚未捆绑实际模型 runner。未来 runner 仅对已经清洗、脱敏的输出提炼简短重点，不执行代码任务，也不替代 Codex/Qoder。

## 指标方向

MVP 记录指标事件但没有仪表板。目标字段涵盖任务持续时间、重试/跟进/编辑/批准/中断计数、验证状态、原始日志大小、意图保真度、执行质量和人为中断成本。目的不是模型基准测试；而是衡量人与代理之间的委托质量。

后续阶段应增加任务级交互效率评估。每个 task / turn 至少应能复盘：

- 用户输入和追加上下文的长度与次数
- Agent 输出和结果摘要的长度
- token 消耗与有效 deliverable 的比例
- 审批、暂停、恢复、重试和用户等待次数
- 用户是否接受结果、继续补充、拒绝/重做或标记完成
- 从创建任务到可验收结果的耗时

这些指标用于提升用户每次交互的效率：减少无效输出、减少 prompt echo / thinking / CLI chrome 污染、减少不必要的返工，并帮助下一轮任务提示更聚焦。它们不改变 Codex/Qoder 的执行逻辑，也不要求 Agent 返回私有结构化协议。

Armin 的 Loop Engineering 边界是单任务循环：Plan → Execute → Observe → Evaluate → Adjust → Verify。Runtime 负责观察和归约状态；评估层记录本轮循环的成本、结果质量和用户后续动作；UI 只暴露对用户有帮助的下一步。该循环不等同于多 Agent workflow、自动调度器或通用任务依赖图。

## Phase 2.6 迁移收口边界

结果来源和 Runtime 状态迁移必须保证原有功能不受影响。收口目标是减少错误来源，而不是把所有展示、朗读、诊断和状态刷新逻辑强行合并到一个尚未覆盖完整场景的入口。具体执行步骤统一以 [legacy-cleanup-checklist.md](runtime/legacy-cleanup-checklist.md) 为准。

稳定行为原则：

- UI 同步路径不得做大字符串切片、summary、TTS 清洗、raw log 扫描或 prompt echo 判断。
- 任务完成、等待用户、运行时中断等状态必须能自动刷新；不能要求用户手动刷新才能从 `running` / `Agent started` 进入可验收状态。
- RuntimeEventBus / WorkState 尚未覆盖完整前，parser / tmux capture 仍可作为自动 reconcile 输入，但必须遵守增量证据、marker count、fingerprint 或 event id 去重。
- WorkState 是 UI 语义增强，不得长期掩盖与 `TaskSession.status` 冲突的真实可操作状态。
- 没有当前 turn / event evidence 时，结果页不伪造 deliverable；`task.summary` / `shortSummary` 不能作为结果兜底。
- latest turn deliverable 不得来自 prompt echo、thinking、旧 turn、running snapshot、reconnect snapshot 或 legacy summary。
- `rawOutput` / `cleanedOutput` 只能作为 resolver evidence，最终展示和 TTS 应消费 resolved `displaySummary` / `speechSummary`。
- 手动朗读和自动 TTS 的迁移必须以真机验证为门槛，不能为了同源牺牲旧有可用性和性能。

当前实现状态：结果页规则摘要已经在后台 isolate 中执行，并具有页面级有界缓存、in-flight 去重和首帧后调度；高频输出事件也不触发持久化或全局重建。尚未完成的是结果卡片、手动朗读和自动 TTS 对同一个 `ResolvedDeliverable` resolver/cache 的复用，以及 deliverable 场景中 `summary` / `shortSummary` fallback 的移除。完整 resolved payload 的 SQLite 持久化与跨重启恢复不属于 Phase 2.6，延后到 Phase 3。

所有阶段中，任何 Runtime、状态、结果、TTS、observer、reconcile、持久化或 UI 核心变更都必须满足 [Armin 核心行为与性能基线](runtime/core-behavior-performance-baseline.md)。基线失败表示方案尚未达到功能等价或性能等价，不能以架构收口、技术升级或进入新阶段为理由接受回归，也不能通过降低基线完成迁移。

## 未来安全远端执行方向

近期 Codex 方向中出现的 authenticated remote executor、端到端加密 relay channel 和基于 Noise 的安全通信，是 Armin 未来可以参考的重要架构方向，但不属于 Phase 2.5 或 Phase 3 的近期优先级。

在实现 Secure Remote Executor Infrastructure 前，Armin 必须先验证：

1. 用户会稳定使用语音驱动的任务创建。
2. 用户会采用 Loop-based 工作流。
3. 用户会通过 Armin 运行长生命周期编码任务。
4. 用户确实需要从多个设备远程访问执行器。

只有这些假设成立后，安全远端执行器基础设施才应进入开发优先级。
