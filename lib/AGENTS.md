# Armin Flutter Module Guide

本目录是 Armin 的 Flutter 应用代码。后续变更先按模块收敛到 `features/*`、`core/*` 或 `shared/*`，不要为了一个页面问题同时改动多个 feature，除非根因明确跨越状态、模型或服务边界。

## 基本规则

- 使用 Dart/Flutter 现有模式；不要按根 `AGENTS.md` 的 TypeScript/React 偏好改写 Flutter 代码。
- 优先修改已有 service、model、screen、widget，不新增抽象，除非能减少真实重复或隔离跨模块契约。
- UI 文案和交互保持移动优先、语音优先；不要把 Armin 做成完整终端或通用聊天工具。
- 业务状态通过 `core/services/armin_app_state.dart` 协调；feature 内部不要私自持久化全局状态。
- 敏感信息必须脱敏后进入历史、日志、摘要、语音播报。

## 常用入口

- 应用装配：`app.dart`、`app_state_scope.dart`、`main.dart`
- 全局状态：`core/services/armin_app_state.dart`
- 本地持久化：`core/storage/*`
- 终端 Agent：`features/agent/*`
- 任务与摘要：`features/tasks/*`
- 历史详情：`features/history/*`
- 语音输入和播报：`features/voice/*`
- 主机和项目路径：`features/hosts/*`、`features/projects/*`

## 验证策略

- 狭窄改动优先运行对应 `test/<module>` 的 focused test。
- 涉及任务结果、语音、状态机或远端会话时，同时检查相邻模块测试。
- Flutter 工具链可能有 native assets 竞争问题；避免并行跑多个 `flutter test`。
