# Armin Test Guide

测试按运行时代码模块命名。新增或修改功能时，优先补 focused test，再视风险追加相邻模块测试。

## 测试映射

- `test/agent/*`：SSH/tmux、native output、terminal prompt、approval、CLI 输出清洗。
- `test/core/*`：`ArminAppState` 的任务控制和跨模块编排。
- `test/tasks/*`：prompt、secret、turn slicing、summary、语音命令、任务草稿。
- `test/history/*`：任务列表、详情页、approve/terminal prompt 交互、结果展示。
- `test/features/voice/*` 和 `test/voice/*`：设备语音、播报策略、语音设置。
- `test/hosts/*`：主机模型和主机页面。
- `test/settings/*`：设置入口和分组。
- `test/storage/*`：JSON store、安全存储替身和 schema 持久化。

## 运行建议

- 避免并行跑多个 Flutter 测试进程，native assets 容易互相影响。
- 小改动先跑对应单测，例如：
  - `flutter test test/tasks/output_summary_provider_test.dart`
  - `flutter test test/history/task_detail_screen_approval_test.dart`
  - `flutter test test/agent/terminal_prompt_parser_test.dart`
- 结束前至少跑相关 `flutter analyze <changed files>`；大范围文档变更可用 `git diff --check`。

## 断言原则

- 任务结果测试要断言没有 prompt echo、没有中途 approve/terminal 噪音、没有跨 turn 复用输出。
- 语音测试要分别覆盖展示文本、清洗后播报文本和设备失败降级。
- 存储测试要覆盖新增字段的向后兼容和 secret/password 脱敏。
