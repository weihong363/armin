# 架构

Armin 是一个 Flutter 应用，采用本地优先的状态管理，并围绕语音、提示构建、历史记录和终端代理执行提供服务抽象层。

长期 Runtime 方向见 [Bridge Runtime Long-Term Architecture](runtime/bridge-runtime-long-term-architecture.md)。当前 Flutter 内 Bridge Runtime 是过渡实现；最终任务生命周期、审批状态、事件流和 watcher offset 的持久化边界应在 SQLite，并逐步迁移到远端 Runtime daemon 或支持可靠断线续传。

## 层级结构

- `core/models`: 共享状态和跨功能值类型
- `core/storage`: 历史存储抽象、内存实现和 JSON 文件持久化实现
- `features/voice`: STT/TTS 抽象、模拟语音服务和设备语音服务
- `features/tasks`: 草稿模型、提示构建器、秘密信息脱敏、约束提取、状态流转和任务 UI
- `features/agent`: 代理会话抽象、测试 mock、SSH/tmux 服务、原生输出清洗/观察与 legacy 解析器
- `features/hosts`: 主机配置模型和 UI
- `features/history`: 任务详情审计视图

## 本地存储

测试可注入 `InMemoryTaskHistoryStore` 和 mock 服务。应用运行时通过 `ArminAppState.run()` 使用 `JsonTaskHistoryStore`、`DeviceVoiceService` 与 `SSHAgentSessionService`，并通过 `path_provider` 将 host、project path 和 task history 写入应用文档目录下的 `armin_history.json`。

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
5. 按 `RuntimePolicy` 轮询有限范围的 `tmux capture-pane`，将收到的 raw output 写入历史；终态另取更完整的 final capture。
6. 用 `AgentOutputCleaner` 生成展示/观察用输出，并由 `NativeOutputObserver` 判断 `outputQuieting`、`needAttention` 或 `runtimeLost`。
7. `turnIdle` 保留 session 等待用户继续；暂停会停止手机端 observer 而保留 session，恢复会重新监听同一 session；用户标记完成、失败、停止或达到最长运行时限时，先 capture 最终日志，再 cleanup session。

Armin 不负责代理的推理、规划、代码合并或调度。它仅管理 shell 级别的通信和可审计性。

`tmux capture-pane` 是观察输入，不是任务状态权威。输出稳定或无新增可见文本只能表示 `outputQuieting` / `no visible update`，不能单独触发 `turnIdle`、结果卡片或 TTS 播报。长期应由 Runtime Event + SQLite Store 派生 `WorkState`、`ApprovalState` 和结果可见性。

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

`TaskResultParser` 和 `ApprovalParser` 仍为 legacy 兼容代码。即便 adapter 提供 legacy `TaskResult`，它也只作为本轮可读摘要进入 `turnIdle` 或 `needAttention`，不再决定任务完成或触发 session cleanup。测试覆盖 ANSI/TUI 清洗、turn idle/runtime lost、敏感信息脱敏、上下文治理、语音草稿和规则摘要。

## 指标/事件层

`MetricEvent` 记录 shell 级别的事件，如任务创建、任务开始、接收到原始输出、请求批准和任务完成。第一阶段在任务详情时间线中显示这些事件。后续阶段可以聚合诸如持续时间、编辑次数、批准次数、中断次数、验证状态、变更文件数和原始日志大小等字段。

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

## 运行时控制

运行时控制仅限于 shell 和用户任务语义层：

- 跟进指令直接发送到当前 tmux/Agent 会话，不添加私有结构化 marker。
- 运行中的语音追加与语音控制会追加脱敏后的 `VoiceInput`，使历史可区分用户实际说过的推进或终止语义。
- 暂停/恢复与停止控制当前远端会话。
- 断开监听只移除手机侧 observer，远端 session 可继续运行；重新连接会 attach 到同一 session。
- SSH 传输中断或手机网络掉线会进入可恢复的监听断开状态，不会自动判定远端任务失败或清理可能仍在运行的 session。
- `turnIdle` 表示本轮在强信号下进入等待用户继续，用户可以继续追加或确认结束，不等于完成；它不应由短时间无输出或 pane 稳定直接产生。
- 用户标记完成/失败或停止时，Armin 保存 final capture 后清理 tmux session。
- 如果 cleanup 未能确认成功，任务会保留提示和日志，终态详情页可再次请求清理远端 session。
- `runtimeLost`（远端会话已不可用）属于终端状态：该任务不再被 reconcile 探测、不被 bridge 跟踪、不计入活跃任务上限，且可被删除。仅 `running` 和 `observerDetached` 会被周期性 reconcile 探测远端状态。
- `RuntimePolicy` 当前默认以 20 秒安静输出判断一轮暂停，以 20 分钟作为单次运行的最长观察时限；监控窗口较短，final capture 窗口较完整。
- 已结束、失败、停止或运行丢失的任务可重新执行，并预选原任务的 Host 和 project path；仍在交互中的任务不能通过重跑另起 session。

Armin 不解释或重写 Agent 的执行逻辑。`SelectableOutputSummaryProvider` 支持用户打开实验性的端侧摘要增强，并在 runner 不存在、设备不支持、超时或失败时回落至脱敏后的规则摘要。生产包仍待接入实际 Android 模型 runner；它只用于 TTS/展示摘要，不参与 Agent 执行。
