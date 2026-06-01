# History Module Spec

`features/history` 展示任务列表、任务详情、运行控制、时间线、结果卡片和审计信息。这里负责把 task state 翻译成用户可理解的界面。

## 职责

- `screens/task_history_screen.dart`：任务列表、标题和状态入口。
- `screens/task_detail_screen.dart`：任务详情、运行控制、turn 展示、结果、日志、指标和 approve/terminal prompt 入口。
- `widgets/audit_section.dart`：审计类展示组件。

## 边界

- 不在页面里重新实现终端解析；使用 `agent/parsers` 的结果。
- 不在页面里发明摘要算法；使用 `OutputSummaryProvider` 或 `ArminAppState.speakTaskSummary`。
- 不把 need-attention 的中途交互当最终结果卡片展示。
- 标题展示策略要和任务列表一致，编辑态和展示态明确分离。

## 修改提示

- 改详情页交互时，检查键盘弹起、小屏滚动、运行中状态、断开监听后恢复。
- 改结果页时，逐 turn 验证：每张卡片显示自己的输出，不显示初始 prompt 或其他 turn 内容。
- 改 approve/terminal prompt UI 时，保证手动选择和语音处理都有入口。
- 避免在 `build` 中创建 controller、animation controller 或会重复订阅的对象。

## 推荐测试

- `flutter test test/history/task_history_screen_test.dart`
- `flutter test test/history/task_detail_screen_approval_test.dart`
- `flutter test test/tasks/output_summary_provider_test.dart`
