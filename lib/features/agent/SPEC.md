# Agent Module Spec

`features/agent` 是 Armin 和桌面端终端 Agent 的 shell 边界。它负责启动、观察、清洗、解析和控制远端 CLI，但不负责决定结果如何展示成页面。

## 职责

- `services/agent_session_service.dart`：执行、追加、暂停、恢复、停止、cleanup、日志捕获等统一接口。
- `services/ssh_agent_session_service.dart`：真实 SSH/tmux 执行链路。
- `services/native_output_observer.dart`：从原生输出判断 running、idle、need attention、runtime lost。
- `services/agent_output_cleaner.dart`：清洗终端控制字符和 CLI 噪音。
- `parsers/*`：解析结构化结果、批准请求、终端选项请求。

## 边界

- 不在这里做结果卡片布局；展示逻辑属于 `history`。
- 不在这里做最终摘要策略；语义摘要属于 `tasks/services/output_summary_provider.dart`。
- 不吞掉原始输出；清洗后的输出用于展示，原始日志仍要可审计。
- 终端 approve/option 解析要保留 command、question、options，便于手动和语音交互。
- `tmux capture-pane` 是 transport/observation 输入，不是完成信号；pane 稳定或无可见输出不能直接产生 `turnIdle`、结果卡片或 TTS。
- CLI 个性化的 approval、waiting、completion、failure 和 thinking/running marker 应进入 adapter 配置，通用 watcher 只能作为 fallback。
- Display cleaner 可以过滤 thinking 或 TUI 噪音，但 runtime 状态判断不能只依赖 cleaned output。

## 修改提示

- 新增 CLI 适配时，先扩展 `AgentExecutionRequest` 或 shell command 构建逻辑，再补 parser/cleaner 测试。
- 改 terminal prompt 规则时，覆盖完整 command、多行 command、选项编号、中文/英文问题。
- 改 idle 或 need-attention 判断时，检查后续 `NativeOutputTurn.status` 和 UI 状态是否仍一致。
- 改 polling/capture-pane 逻辑时，确认 stable output 只进入 `outputQuieting` 或进度观察，不会被解释成 turn 完成。

## 推荐测试

- `flutter test test/agent/ssh_agent_session_service_test.dart`
- `flutter test test/agent/native_output_observer_test.dart`
- `flutter test test/agent/agent_output_cleaner_test.dart`
- `flutter test test/agent/terminal_prompt_parser_test.dart`
- `flutter test test/agent/approval_parser_test.dart`
