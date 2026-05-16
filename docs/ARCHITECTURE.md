# 架构

Armin 是一个 Flutter 应用，采用本地优先的状态管理，并围绕语音、提示构建、历史记录和终端代理执行提供服务抽象层。

## 层级结构

- `core/models`: 共享状态和跨功能值类型
- `core/storage`: 历史存储抽象、内存实现和 JSON 文件持久化实现
- `features/voice`: STT/TTS 抽象、模拟语音服务和设备语音服务
- `features/tasks`: 草稿模型、提示构建器、秘密信息脱敏、约束提取、状态流转和任务 UI
- `features/agent`: 代理会话抽象、模拟代理执行、SSH/tmux 服务、结果解析器
- `features/hosts`: 主机配置模型和 UI
- `features/history`: 任务详情审计视图

## 本地存储

测试和 mock flow 使用 `InMemoryTaskHistoryStore`。应用运行时使用 `JsonTaskHistoryStore`，通过 `path_provider` 将 host 和 task history 写入应用文档目录下的 `armin_history.json`。

正常任务历史绝不能存储明文敏感值。Phase 2 只持久化 private key path，不持久化 password 或 private key value。后续可将可复用 secret 迁移到 Android Keystore 或 EncryptedSharedPreferences。

## 代理会话服务

`AgentSessionService` 提供一个操作：

```dart
Stream<AgentExecutionUpdate> execute(AgentExecutionRequest request);
```

`MockAgentSessionService` 模拟以下场景：

- 运行输出
- `NEED_APPROVAL`（需要批准）
- 完成的 `TASK_RESULT`
- 失败的 `TASK_RESULT`

`SSHAgentSessionService` 的 Phase 2 流程为：

1. 连接到主机
2. 附加或创建 tmux 会话，默认为 `armin-codex`
3. 进入项目路径
4. 启动代理命令，默认为 `codex`
5. 发送最终提示
6. 轮询 `tmux capture-pane` 并流式写入原始输出
7. 解析 `TASK_RESULT` 和 `NEED_APPROVAL` 块

Armin 不负责代理的推理、规划、代码合并或调度。它仅管理 shell 级别的通信和可审计性。

## 解析器层

纯 Dart 解析器确保终端输出处理的确定性：

- `TaskResultParser`
- `ApprovalParser`
- `SecretRedactor`
- `PromptTemplateBuilder`
- `SpeechDraftCleaner`
- `ConstraintExtractor`

解析器测试涵盖结构化结果标记、批准标记、敏感文本脱敏、不确定性保留、约束提取、提示生成和指标事件创建。

## 指标/事件层

`MetricEvent` 记录 shell 级别的事件，如任务创建、任务开始、接收到原始输出、请求批准和任务完成。第一阶段在任务详情时间线中显示这些事件。后续阶段可以聚合诸如持续时间、编辑次数、批准次数、中断次数、验证状态、变更文件数和原始日志大小等字段。

## UI 结构

主页是一个任务队列，而非终端：

- 正在运行的任务部分
- 最近的任务
- 主机快捷方式
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
- 运行时控制占位符
- 结果摘要
- 折叠的原始日志
- 指标时间线

## 运行时控制

运行时控制仅限于 shell 级别。跟进指令作为 `RUNTIME_UPDATE` 文本发送到活动 tmux 会话。批准/拒绝会作为 `APPROVAL_DECISION` 文本发送回当前会话。暂停发送 `C-z`，恢复发送 `fg`，停止发送 `C-c`。Armin 不解释或重写 agent 的执行逻辑。
