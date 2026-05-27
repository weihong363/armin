# Armin 规范

Armin 是一个移动优先和语音优先的 shell，用于将工作委托给计算机上的终端 Agent。它不是 Codex Mobile，不是一个完整的终端应用，也不是一个 AI 运行时。Armin 帮助用户用自己的语言描述、约束、推进、恢复、停止和确认工作，再由不同 Agent 执行，并保留审计跟踪。

执行核心保留在计算机端：

- Codex CLI
- Qoder CLI
- 后续通过相同 shell adapter 接入的终端 Agent

## 产品原则

1. 用户是在向 AI 编码代理分配工作，而不是操作终端。
2. 中间终端噪音默认隐藏。
3. 用户关心任务是否被理解、发送、等待继续、需要处理以及由自己确认结束。
4. 每个有意义的交互都会被存档以备后续调试。
5. 语音是主要输入方式，但手动编辑必须是首要功能。
6. 敏感值应该被输入、脱敏并从普通历史中排除。
7. Armin 不实现复杂的代理执行、调度、合并或规划逻辑。
8. 未来的指标应有助于调试人与代理之间的委托质量。

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

发送到桌面 Agent 的提示使用 `armin-task-v1` 模板，并通过 `PromptGovernor` 注入短的上下文治理规则；参见 [PROMPT_TEMPLATE.md](PROMPT_TEMPLATE.md)。提示不要求 Agent 返回结构化 marker。

### Shell 层

Armin 拥有 shell 级别的会话抽象，而不是代理运行时：

- `AgentSessionService`
- `MockAgentSessionService`
- `SSHAgentSessionService`

`MockAgentSessionService` 仅用于测试。真实 Phase 2 连接到 Host，按任务创建短 session（`armin-{taskId片段}`），并在用户选择的 project path 中启动 Agent。Codex CLI 使用 `codex -C {projectPath}`；Qoder CLI 使用 `qodercli -w {projectPath}`。`CodexOutputCleaner` 和 `NativeOutputObserver` 清洗并观察原生输出；安静输出进入 `turnIdle`，并不代表任务已经完成。

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
- `TaskResult`: legacy-compatible optional result representation; not required for native-output completion
- `ApprovalRequest`: id, taskId, reason, command, risk, status, createdAt, resolvedAt
- `MetricEvent`: id, taskId, eventType, payloadJson, createdAt
- `Subtask`: id, parentTaskId, title, status, workerLabel, orderIndex, summary, createdAt, completedAt

## 端侧摘要方向

输出展示与 TTS 默认使用规则摘要。Phase 2 已提供端侧摘要增强实验开关、runner 接口、能力检测、规则 fallback 与摘要脱敏；传入可选 runner 或 fallback 的任务输出和 prompt 文本会先脱敏。当前生产包尚未捆绑实际模型 runner。未来 runner 仅对已经清洗、脱敏的输出提炼简短重点，不执行代码任务，也不替代 Codex/Qoder。

## 指标方向

MVP 记录指标事件但没有仪表板。目标字段涵盖任务持续时间、重试/跟进/编辑/批准/中断计数、验证状态、原始日志大小、意图保真度、执行质量和人为中断成本。目的不是模型基准测试；而是衡量人与代理之间的委托质量。
