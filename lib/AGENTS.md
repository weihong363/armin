# Armin Flutter Module Guide

本目录是 Armin 的 Flutter 应用代码。后续变更先按模块收敛到 `features/*`、`core/*` 或 `shared/*`，不要为了一个页面问题同时改动多个 feature，除非根因明确跨越状态、模型或服务边界。

## 范围控制（Scope Control）

- 从与当前任务直接相关的 feature 开始分析。
- 优先在当前模块内定位问题，不要默认跨模块搜索。
- 除非有明确证据表明问题涉及多个模块，否则不要同时检查多个 feature。
- 避免进行全仓库范围的搜索、分析或审查。
- 仅当当前模块无法解释问题根因时，才逐步扩大分析范围。
- 优先查看用户明确提及的文件、页面、服务或组件。
- 对于 UI 问题，优先检查目标页面及其直接引用的 Widget。
- 对于业务逻辑问题，优先检查对应 Service、Model 和 State。
- 对于语音问题，优先检查 Voice 模块及其直接依赖。
- 完成当前需求后停止，不主动扩展为架构优化、重构或额外功能开发。
- 不要为了理解项目结构而主动阅读 README、SPEC、Roadmap、设计文档或历史记录；仅在当前任务明确需要时才查看。

## 基本规则

- 使用 Dart/Flutter 现有模式；不要按根 `AGENTS.md` 的 TypeScript/React 偏好改写 Flutter 代码。
- 优先修改已有 service、model、screen、widget，不新增抽象，除非能减少真实重复或隔离跨模块契约。
- UI 文案和交互保持语言优先；不要把 Armin 做成完整终端或通用聊天工具。
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
