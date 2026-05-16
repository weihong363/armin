# 架构

Armin 是一个 Flutter 应用，采用本地优先的状态管理，并围绕语音、提示构建、历史记录和终端代理执行提供服务抽象层。

## 层级结构

- `core/models`: 共享状态和跨功能值类型
- `core/storage`: 历史存储抽象及第一阶段的内存实现
- `features/voice`: STT/TTS 抽象以及模拟语音服务
- `features/tasks`: 草稿模型、提示构建器、秘密信息脱敏、约束提取、状态流转和任务 UI
- `features/agent`: 代理会话抽象、模拟代理执行、未来的 SSH/tmux 服务、结果解析器
- `features/hosts`: 主机配置模型和 UI
- `features/history`: 任务详情审计视图

## 本地存储

第一阶段使用 `InMemoryTaskHistoryStore`。存储边界设计得较为紧凑，以便第二阶段可以添加 SQLite 或其他本地数据库而无需更改 UI 流程。

正常任务历史绝不能存储明文敏感值。未来的持久化密钥必须通过 Android Keystore 或 EncryptedSharedPreferences 进行处理。

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

`SSHAgentSessionService` 是第二阶段的占位符。其目标流程为：

1. 连接到主机
2. 附加或创建 tmux 会话，默认为 `armin-codex`
3. 进入项目路径
4. 启动代理命令，默认为 `codex`
5. 发送最终提示
6. 流式传输原始输出
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

- 模拟语音输入
- 任务描述编辑器
- 上下文编辑器
- 约束芯片
- 密钥输入
- 提示预览
- 模拟执行场景选择器

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

运行时控制仅限于 shell 级别。跟进和中止指令作为追加文本发送到活动的终端会话。暂停、恢复和停止功能需要在 SSH/tmux 实现后才能影响实际执行。
