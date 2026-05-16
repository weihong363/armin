# Armin 规范

Armin 是一个移动优先和语音优先的 shell，用于将工作委托给已经在计算机上运行的编码代理。它不是 Codex Mobile，不是一个完整的终端应用，也不是一个 AI 运行时。Armin 帮助用户表达意图、确认任务、向基于终端的代理发送可靠的提示、收集结果并保持审计跟踪。

执行核心保留在计算机端：

- Codex CLI
- Claude Code
- Aider
- Gemini CLI
- 其他基于终端的编码代理

## 产品原则

1. 用户是在向 AI 编码代理分配工作，而不是操作终端。
2. 中间终端噪音默认隐藏。
3. 用户关心任务是否被理解、发送、在需要时获得批准以及完成。
4. 每个有意义的交互都会被存档以备后续调试。
5. 语音是主要输入方式，但手动编辑必须是首要功能。
6. 敏感值应该被输入、脱敏并从普通历史中排除。
7. Armin 不实现复杂的代理执行、调度、合并或规划逻辑。
8. 未来的指标应有助于调试人与代理之间的委托质量。

## MVP 范围

MVP 必须证明一个可靠的循环：

```text
语音/文本输入
-> 任务草稿
-> 用户编辑和确认
-> 最终提示
-> SSH/tmux 交接给桌面 Codex CLI
-> 结构化输出解析
-> 结果显示/语音摘要
-> 完整的本地历史
```

第一阶段使用模拟 STT、模拟 TTS、内存历史和 `MockAgentSessionService`。真实的 SSH/tmux 保留到第二阶段，通过相同的服务接口实现。

## 非目标

- Codex Mobile 官方远程控制替代品
- 完整的终端模拟器
- 复杂的多代理调度器
- 真正的 fork/join 运行时
- 自动代码合并
- 复杂的规划器
- 本地 SLM
- 云同步
- 团队协作
- SaaS 后端
- 自动 git commit 或 push

## 必需的 MVP 功能

### 语音优先输入

- 点击或按住说话的入口点
- STT 转文本
- 可编辑的转录文本
- 历史中的原始 STT 文本
- 现在使用模拟 STT，以后使用真实 STT

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

历史仅存储名称、用途、范围和 `[REDACTED]`。提示预览仅显示占位符。未来的 Android 存储必须使用 Android Keystore 或 EncryptedSharedPreferences。

脱敏器必须检测令牌、密码、私钥、cookie、API 密钥、访问密钥和秘密模式。

### 提示构建

发送到桌面代理的所有提示都使用固定模板。当前模板版本为 `armin-task-v1`；参见 [PROMPT_TEMPLATE.md](PROMPT_TEMPLATE.md)。

### Shell 层

Armin 拥有 shell 级别的会话抽象，而不是代理运行时：

- `AgentSessionService`
- `MockAgentSessionService`
- `SSHAgentSessionService`

第一阶段使用模拟执行来处理 UI、解析器、历史和状态流。第二阶段将连接到主机，附加或创建 tmux 会话 `armin-codex`，进入项目路径，启动代理命令 `codex`，发送提示，流式传输输出并解析标记。

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
- 结构化结果
- 状态变更
- 指标事件

任务详情屏幕显示语音/STT、草稿、已确认任务、已发送提示、运行时事件、结果摘要、变更文件、验证、风险、折叠的原始日志、批准记录和指标时间线占位符。

### 轻量级持续交互

MVP 保留 shell 级别的控制：

- 跟进追加
- 停止
- 暂停占位符
- 恢复占位符
- 中止指令占位符

运行时更新作为文本发送到活动的 tmux 会话，例如：

```text
RUNTIME_UPDATE:
用户更新了任务约束。

新指令：
- 暂时不要调查 API 请求链。
- 首先专注于前端事件绑定。

保留之前的发现。除非必要，否则不要重新启动整个任务。
```

### Fork/join 组织

MVP 不实现真正的并行运行时。数据模型为父任务、子任务、子任务状态、工作器标签和加入摘要保留空间，用于手动或规则建议的任务组织。

## 数据模型

- `HostConfig`: id, name, host, port, username, authType, projectPath, tmuxSessionName, agentCommand, createdAt, updatedAt
- `TaskSession`: id, title, hostId/host, projectPath, status, createdAt, startedAt, completedAt, parentTaskId, workerLabel, summary
- `VoiceInput`: id, taskId, rawSttText, language, createdAt
- `TaskDraft`: id, taskId, cleanedText, userEditedText, contextText, constraints, createdAt, updatedAt
- `PromptRecord`: id, taskId, finalPrompt, templateVersion, createdAt
- `SecretRecord`: id, taskId, name, usage, redactedValue, scope, createdAt
- `ExecutionLog`: id, taskId, rawOutput, createdAt
- `TaskResult`: id, taskId, status, summary, changedFiles, validation, risks, nextActions, createdAt
- `ApprovalRequest`: id, taskId, reason, command, risk, status, createdAt, resolvedAt
- `MetricEvent`: id, taskId, eventType, payloadJson, createdAt
- `Subtask`: id, parentTaskId, title, status, workerLabel, orderIndex, summary, createdAt, completedAt

## 指标方向

MVP 记录指标事件但没有仪表板。目标字段涵盖任务持续时间、重试/跟进/编辑/批准/中断计数、验证状态、原始日志大小、意图保真度、执行质量和人为中断成本。目的不是模型基准测试；而是衡量人与代理之间的委托质量。
