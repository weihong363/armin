# Tasks Module Spec

`features/tasks` 定义任务数据、任务草稿、提示词构建、secret 脱敏、turn 切片、结果摘要和语音任务命令。它是 Armin 语义质量的主要归属地。

## 职责

- `models/*`：任务、草稿、turn、日志、指标、secret、prompt、subtask 等持久化模型。
- `screens/task_home_screen.dart`：任务入口和新任务创建。
- `screens/task_draft_screen.dart`：语音/文本草稿编辑、约束选择、发送任务。
- `services/prompt_*`：构建发给 Agent 的最终提示。
- `services/output_summary_provider.dart`：从展示文本或 turn 输出生成清晰、脱噪的结果摘要。
- `services/turn_output_slicer.dart`：从原生输出切分各轮 turn。
- `services/voice_task_command_processor.dart`：把语音控制词映射成任务动作。

## 边界

- 不直接操作 SSH/tmux；执行控制走 `AgentSessionService` 和 `ArminAppState`。
- 不直接调用设备 TTS/STT；语音设备能力属于 `features/voice`。
- 结果摘要必须基于已清洗、已脱敏、当前 turn 的文本，不能复用 stale summary 或初始 prompt。
- 交互中的 approve/terminal prompt 不应污染最终结果摘要。

## 修改提示

- 改输出结果问题，优先看 `OutputSummaryProvider`、`TurnOutputSlicer`、`NativeOutputTurn` 数据来源。
- 改语音命令，优先看 `VoiceTaskCommandProcessor`，保持命令语义围绕任务控制。
- 改 prompt 模板，确认 secret 占位符、用户原话、约束芯片仍被保留。
- 新增模型字段时同步更新 `TaskSession.fromJson/toJson` 和历史 store 测试。

## 推荐测试

- `flutter test test/tasks/output_summary_provider_test.dart`
- `flutter test test/tasks/turn_output_slicer_test.dart`
- `flutter test test/tasks/voice_task_command_processor_test.dart`
- `flutter test test/tasks/prompt_template_builder_test.dart`
- `flutter test test/tasks/secret_redactor_test.dart`
- `flutter test test/tasks/task_draft_screen_send_test.dart`
